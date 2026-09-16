# Passwords — an ewe plugin

`ewe.passwords` — first-party, shipped with ewe, removable.

`Super+P` in any window lists the logins that match the focused app and
types the one you pick — username, Tab, password — through a virtual
keyboard, since no password manager fills into native apps on Linux.
Ctrl+Enter types the password only, Ctrl+C / Ctrl+Shift+C copy, Ctrl+P pins
a login to the app. Providers: 1Password (`op`, with the app's CLI
integration turned on), Bitwarden (`rbw`), `pass`.

    ewe-plugin remove ewe.passwords
    ewe-plugin add https://github.com/prj786/ewe-plugin-passwords.git --enable

Settings: `provider` (auto / 1password / bitwarden / pass), `press_enter`.
Needs `wtype` (an ewe dependency). `ewe-pass` in this folder is the tool the
panel runs; `./ewe-pass status` says what it will do and why not.
