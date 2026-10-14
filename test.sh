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

# 7. ewe Safe (provider ewe): a fake `ewe-safe` speaking docs/PROTOCOL.md --
mkdir -p "$SB/safebin"
cat > "$SB/safebin/ewe-safe" <<'ES'
#!/usr/bin/env python3
import json, os, sys
a = sys.argv[1:]
with open(os.environ["SAFE_LOG"], "a") as f:
    f.write("ewe-safe " + " ".join(a) + "\n")
st = open(os.environ["SAFE_STATE"]).read().strip()      # absent | locked | unlocked
def out(o): print(json.dumps(o)); sys.exit(0)
LOCKED = {"ok": False, "error": "locked", "message": "Safe is locked.", "hint": "ewe-safe unlock"}
v = a[0] if a else ""
if v == "status":
    out({"ok": True, "set_up": st != "absent", "locked": st != "unlocked", "items": None if st != "unlocked" else 2})
if v == "unlock":
    open(os.environ["SAFE_STATE"], "w").write("unlocked"); out({"ok": True, "items": 2})
if v == "lock":
    open(os.environ["SAFE_STATE"], "w").write("locked"); out({"ok": True, "locked": True})
if st != "unlocked":
    out(LOCKED)
ITEMS = [
  {"id": "11111111-aaaa-4aaa-8aaa-111111111111", "kind": "login", "title": "Discord", "username": "sam",
   "urls": ["https://www.discord.com/login"], "apps": [], "tags": [], "score": 30, "reason": "site matches the app"},
  {"id": "22222222-bbbb-4bbb-8bbb-222222222222", "kind": "login", "title": "Router", "username": "admin",
   "urls": [], "apps": [], "tags": [], "score": 0, "reason": ""},
]
SECRETS = {"11111111-aaaa-4aaa-8aaa-111111111111": {"username": "sam", "password": "Safe!Pässwörd-1"}}
if v == "match":
    out({"ok": True, "items": ITEMS})
if v == "list":
    out({"ok": True, "items": ITEMS})
if v == "reveal":
    sec = SECRETS.get(a[1], {})
    if a[2] != "--field" or "--json" not in a or a[3] not in sec:
        out({"ok": False, "error": "not-found", "message": "no item " + a[1]})
    out({"ok": True, "value": sec[a[3]]})
if v == "copy":
    out({"ok": True, "cleared_after": 30})
if v == "edit":
    out({"ok": True, "sync": {"state": "in-sync"}})
out({"ok": False, "error": "bad-request", "message": "unknown verb " + v})
ES
chmod +x "$SB/safebin/ewe-safe"
export SAFE_LOG="$SB/safe.log" SAFE_STATE="$SB/safe.state"
: > "$SAFE_LOG"; : > "$WTYPE_LOG"
OLDPATH="$PATH"; export PATH="$SB/safebin:$PATH"
j() { python3 -c "import json,sys; d=json.load(sys.stdin); $1" ; }

echo absent > "$SAFE_STATE"
st="$(./ewe-pass status)"
check "Safe installed but not set up → auto keeps 1Password" "echo '$st' | j 'assert d[\"provider\"]==\"1password\", d'"
echo unlocked > "$SAFE_STATE"
st="$(./ewe-pass status)"
check "a set-up, unlocked safe → auto picks ewe, ready" "echo '$st' | j 'assert d[\"provider\"]==\"ewe\" and d[\"ready\"] is True and d[\"label\"]==\"ewe Safe\", d'"
m="$(./ewe-pass match --class discord --title 'Discord' --limit 5)"
check "match: Safe's items and scores, host from the first url" "echo '$m' | j 'i=d[\"items\"][0]; assert d[\"provider\"]==\"ewe\" and i[\"id\"].startswith(\"1111\") and i[\"host\"]==\"discord.com\" and i[\"score\"]==30 and d[\"matched\"]==1, d'"
check "match: the window and limit go to ewe-safe" "grep -q -- 'ewe-safe match --class discord --title Discord --limit 5' '$SAFE_LOG'"
check "match: no item cache for Safe" "[ ! -e '$SB/run/ewe-pass/ewe.json' ]"
r="$(FAKE_PID=4242 ./ewe-pass fill 11111111-aaaa-4aaa-8aaa-111111111111 --pid 4242)"
check "fill from Safe types user, Tab, password" "[ \"\$(cat \"\$WTYPE_LOG\")\" = \$'wtype -d 8 - <sam>\nwtype -k Tab\nwtype -d 8 - <Safe!Pässwörd-1>' ]"
check "fill asks reveal --json, never a secret on a command line" "grep -q 'reveal 11111111-aaaa-4aaa-8aaa-111111111111 --field password --json' '$SAFE_LOG' && ! grep -q 'Pässwörd' '$SAFE_LOG' && ! grep -qE 'wtype .*Pässwörd.*<' '$WTYPE_LOG'"
rm -f "$SB/run/ewe-clip-skip"
r="$(./ewe-pass copy 11111111-aaaa-4aaa-8aaa-111111111111 --what password)"
check "copy is Safe's (it clears later), marker written" "echo '$r' | j 'assert d[\"ok\"] and d[\"cleared_after\"]==30, d' && grep -q 'ewe-safe copy 11111111-aaaa-4aaa-8aaa-111111111111 --field password' '$SAFE_LOG' && [ -f '$SB/run/ewe-clip-skip' ]"
rm -f "$SB/cfg/ewe/passwords-apps.json"
./ewe-pass remember 11111111-aaaa-4aaa-8aaa-111111111111 --class Discord >/dev/null
./ewe-pass forget 11111111-aaaa-4aaa-8aaa-111111111111 --class Discord >/dev/null
check "pins live in the safe: edit --app / --remove-app, lowercased" "grep -q 'edit 11111111-aaaa-4aaa-8aaa-111111111111 --app discord' '$SAFE_LOG' && grep -q 'edit 11111111-aaaa-4aaa-8aaa-111111111111 --remove-app discord' '$SAFE_LOG' && [ ! -e '$SB/cfg/ewe/passwords-apps.json' ]"
r="$(./ewe-pass lock)"
check "lock → ewe-safe lock" "echo '$r' | j 'assert d[\"ok\"] and d[\"locked\"], d' && [ \"\$(cat \"\$SAFE_STATE\")\" = locked ]"
st="$(./ewe-pass status)"
check "locked: status says so (not ready, locked)" "echo '$st' | j 'assert d[\"provider\"]==\"ewe\" and d[\"ready\"] is False and d[\"locked\"] is True, d'"
m="$(./ewe-pass match --class discord --title x || true)"
check "locked: match → error locked, the sentence in message, provider named" "echo '$m' | j 'assert d[\"ok\"] is False and d[\"error\"]==\"locked\" and d[\"message\"]==\"Safe is locked\" and d[\"provider\"]==\"ewe\" and d[\"hint\"], d'"
: > "$WTYPE_LOG"
r="$(FAKE_PID=4242 ./ewe-pass fill 11111111-aaaa-4aaa-8aaa-111111111111 --pid 4242 || true)"
check "locked: fill types nothing, says locked" "echo '$r' | j 'assert d[\"error\"]==\"locked\", d' && [ ! -s \"\$WTYPE_LOG\" ]"
r="$(./ewe-pass unlock)"
check "unlock → ewe-safe unlock --ask" "echo '$r' | j 'assert d[\"ok\"] and d[\"items\"]==2, d' && grep -q 'ewe-safe unlock --ask' '$SAFE_LOG' && [ \"\$(cat \"\$SAFE_STATE\")\" = unlocked ]"
r="$(EWE_PASS_PROVIDER=1password ./ewe-pass unlock || true)"
check "unlock with another provider → a clear error" "echo '$r' | j 'assert d[\"ok\"] is False and \"ewe Safe\" in d[\"error\"], d'"
export PATH="$OLDPATH"
EWE_PASS_PROVIDER=ewe ./ewe-pass status > "$SB/st.json"     # (the message has an apostrophe)
check "provider ewe without ewe-safe → install hint" "j 'assert d[\"ready\"] is False and \"ewe-safe\" in d[\"hint\"], d' < '$SB/st.json'"

echo "ewe-pass: $pass passed, $failn failed"
[ "$failn" = 0 ]
