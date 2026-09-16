#!/usr/bin/env bash
# ewe-pass plumbing tests — no vault, no compositor. A fake `op` on PATH
# answers `account list` / `item list` / `item get` with canned JSON, and a
# fake `wtype` records what it would have typed, so the test covers: provider
# selection, the item cache, URL/class/title/tag/pin matching, secret lookup,
# the typing sequence, and that secrets never appear on a command line.
set -euo pipefail
cd "$(dirname "$0")"

SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT
export XDG_CONFIG_HOME="$SB/cfg" XDG_RUNTIME_DIR="$SB/run" HOME="$SB/home"
mkdir -p "$SB/cfg/ewe" "$SB/run" "$SB/home" "$SB/bin"

# fake 1Password CLI ------------------------------------------------------
cat > "$SB/bin/op" <<'OP'
#!/usr/bin/env bash
echo "op $*" >> "$OP_LOG"
case "$1 $2" in
  "account list") echo '[{"email":"me@example.com","url":"my.1password.com"}]' ;;
  "item list") cat <<'J'
[{"id":"aaa","title":"Discord","category":"LOGIN","additional_information":"me@example.com","urls":[{"primary":true,"href":"https://discord.com/login"}],"tags":[]},
 {"id":"bbb","title":"GitHub","category":"LOGIN","additional_information":"scubba","urls":[{"href":"https://github.com"}],"tags":["app:kitty"]},
 {"id":"ccc","title":"Router admin","category":"LOGIN","additional_information":"admin","urls":[{"href":"http://192.168.1.1"}],"tags":[]},
 {"id":"ddd","title":"Mastodon","category":"LOGIN","additional_information":"","urls":[{"href":"https://mastodon.social"}],"tags":[]}]
J
  ;;
  "item get") case "$3" in
      aaa) echo '{"id":"aaa","fields":[{"id":"username","purpose":"USERNAME","value":"me@example.com"},{"id":"password","purpose":"PASSWORD","value":"S3cr3t!Pässwörd"}]}' ;;
      ddd) echo '{"id":"ddd","fields":[{"id":"username","purpose":"USERNAME","value":""},{"id":"password","purpose":"PASSWORD","value":"only-a-password"}]}' ;;
      *) echo "[ERROR] item not found" >&2; exit 1 ;;
    esac ;;
  *) echo "[ERROR] unexpected: $*" >&2; exit 1 ;;
esac
OP
# fake wtype: records args and stdin -----------------------------------------
cat > "$SB/bin/wtype" <<'WT'
#!/usr/bin/env bash
if [ "${!#}" = "-" ]; then printf 'wtype %s <%s>\n' "$*" "$(cat)" >> "$WTYPE_LOG"; else printf 'wtype %s\n' "$*" >> "$WTYPE_LOG"; fi
WT
# fake hyprctl: the "active window" is whatever the test says ----------------
cat > "$SB/bin/hyprctl" <<'HC'
#!/usr/bin/env bash
printf '{"class":"%s","title":"%s","pid":%s}\n' "${FAKE_CLASS:-kitty}" "${FAKE_TITLE:-shell}" "${FAKE_PID:-4242}"
HC
# fake ewe-conf: unset keys ---------------------------------------------------
printf '#!/usr/bin/env bash\necho "{\\"error\\": \\"no-key\\"}"\n' > "$SB/bin/ewe-conf"
chmod +x "$SB/bin/"*
export PATH="$SB/bin:$PATH" OP_LOG="$SB/op.log" WTYPE_LOG="$SB/wtype.log"
: > "$OP_LOG"; : > "$WTYPE_LOG"

pass=0; failn=0
check() { if eval "$2"; then pass=$((pass+1)); else failn=$((failn+1)); echo "FAIL: $1"; fi; }

# 1. provider + status --------------------------------------------------------
st="$(./ewe-pass status)"
check "status picks 1password and is ready" "echo '$st' | grep -q '\"provider\": \"1password\"' && echo '$st' | grep -q '\"ready\": true'"

# 2. matching: url host vs class, tag vs class, title vs title, pins ----------
m="$(./ewe-pass match --class discord --title 'Discord' --limit 3)"
check "discord.com matches class discord first" "echo '$m' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"items\"][0][\"id\"]==\"aaa\" and d[\"items\"][0][\"score\"]>=30, d'"
m="$(./ewe-pass match --class kitty --title 'shell')"
check "tag app:kitty ranks GitHub first for kitty" "echo '$m' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"items\"][0][\"id\"]==\"bbb\", d'"
m="$(./ewe-pass match --class zen --title 'Sign in to GitHub — Zen')"
check "title word github matches the window title" "echo '$m' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"items\"][0][\"id\"]==\"bbb\" and d[\"items\"][0][\"score\"]==20, d'"
m="$(./ewe-pass match --class nothing --title 'nothing')"
check "no match → every item, alphabetical, score 0" "echo '$m' | python3 -c 'import json,sys; d=json.load(sys.stdin); ids=[i[\"id\"] for i in d[\"items\"]]; assert ids==[\"aaa\",\"bbb\",\"ddd\",\"ccc\"] and d[\"matched\"]==0, ids'"
m="$(./ewe-pass match --class nothing --title x --query rout)"
check "--query filters on title" "echo '$m' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert [i[\"id\"] for i in d[\"items\"]]==[\"ccc\"], d'"
./ewe-pass remember ccc --class Nothing >/dev/null
m="$(./ewe-pass match --class nothing --title x)"
check "remember pins an item to the class (case-insensitive)" "echo '$m' | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d[\"items\"][0][\"id\"]==\"ccc\" and d[\"items\"][0][\"reason\"]==\"pinned to this app\", d'"
./ewe-pass forget ccc --class nothing >/dev/null
check "forget removes the pin file entry" "! grep -q ccc '$SB/cfg/ewe/passwords-apps.json' 2>/dev/null"

# 3. the item list is cached (one `op item list` for all those matches) ------
check "item list cached across calls" "[ \"\$(grep -c 'item list' \"\$OP_LOG\")\" = 1 ]"
./ewe-pass match --refresh --class x --title y >/dev/null
check "--refresh re-reads" "[ \"\$(grep -c 'item list' \"\$OP_LOG\")\" = 2 ]"
check "cache file is private" "[ \"\$(stat -c %a \"\$SB/run/ewe-pass/1password.json\")\" = 600 ]"

# 4. fill: focus check, sequence, no secret on any command line --------------
r="$(FAKE_PID=4242 ./ewe-pass fill aaa --pid 4242)"
check "fill reports ok" "echo '$r' | grep -q '\"ok\": true'"
check "fill types user, Tab, password, no Enter" "[ \"\$(cat \"\$WTYPE_LOG\")\" = \$'wtype -d 8 - <me@example.com>\nwtype -k Tab\nwtype -d 8 - <S3cr3t!Pässwörd>' ]"
check "secret never on a command line" "! grep -q 'S3cr3t' \"\$OP_LOG\" && ! grep -qE 'wtype .*S3cr3t.*<' \"\$WTYPE_LOG\""
: > "$WTYPE_LOG"
r="$(FAKE_PID=4242 ./ewe-pass fill aaa --pid 4242 --what password --enter)"
check "--what password --enter" "[ \"\$(cat \"\$WTYPE_LOG\")\" = \$'wtype -d 8 - <S3cr3t!Pässwörd>\nwtype -k Return' ]"
: > "$WTYPE_LOG"
r="$(FAKE_PID=4242 ./ewe-pass fill ddd --pid 4242)"
check "login with an empty username types only the password" "[ \"\$(cat \"\$WTYPE_LOG\")\" = \$'wtype -d 8 - <only-a-password>' ]"
: > "$WTYPE_LOG"
r="$(FAKE_PID=1 ./ewe-pass fill aaa --pid 4242 || true)"
check "focus moved → nothing typed, error says so" "echo '$r' | grep -q 'focus moved' && [ ! -s \"\$WTYPE_LOG\" ]"
r="$(./ewe-pass fill zzz --pid 0 || true)"
check "unknown item → error, no traceback" "echo '$r' | grep -q '\"ok\": false' && ! echo '$r' | grep -qi traceback"

# 5. copy: marker for clip-store + wl-copy on stdin --------------------------
printf '#!/usr/bin/env bash\ncat > "$WTYPE_LOG.copy"\n' > "$SB/bin/wl-copy"; chmod +x "$SB/bin/wl-copy"
r="$(./ewe-pass copy aaa --what username)"
check "copy writes the clip-skip marker and the value" "[ -f \"\$SB/run/ewe-clip-skip\" ] && [ \"\$(cat \"\$WTYPE_LOG.copy\")\" = me@example.com ]"

# 6. not connected: op with no accounts → a hint, not a crash ----------------
printf '#!/usr/bin/env bash\ncase "$1 $2" in "account list") echo "[]";; *) echo "[ERROR] 2026/09/15 no accounts configured for use with 1Password CLI" >&2; exit 1;; esac\n' > "$SB/bin/op"; chmod +x "$SB/bin/op"
st="$(./ewe-pass status)"
check "status: not connected → hint about Developer settings" "echo '$st' | grep -q '\"ready\": false' && echo '$st' | grep -q 'Integrate with 1Password CLI'"
rm -rf "$SB/run/ewe-pass"
m="$(./ewe-pass match --class a --title b || true)"
check "match: op error → ok:false with hint" "echo '$m' | grep -q '\"ok\": false' && echo '$m' | grep -q 'hint'"

echo "ewe-pass: $pass passed, $failn failed"
[ "$failn" = 0 ]
