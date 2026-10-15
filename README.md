# Passwords — an ewe plugin

`ewe.passwords` — first-party, shipped with ewe, removable.

`Super+P` in any window lists the logins that match the focused app and
types the one you pick — username, Tab, password — through a virtual
keyboard, since no password manager fills into native apps on Linux.
Ctrl+Enter types the password only, Ctrl+C / Ctrl+Shift+C copy, Ctrl+P pins
a login to the app. Providers: **ewe Safe** (`ewe-safe`, ewe's own password
manager — picked first once a safe is set up), 1Password (`op`, with the
app's CLI integration turned on), Bitwarden (`rbw`), `pass`.

With ewe Safe, Safe does the matching and a pin is an `app:<class>` tag on
the login, so it follows you to every machine. A locked safe shows "press
Enter to unlock": the picker steps aside for the login prompt (or the Safe
window — the master password is never typed into the shell) and comes back
on the same window. Ctrl+L locks the safe; copies are cleared by Safe.

    ewe-plugin remove ewe.passwords
    ewe-plugin add https://github.com/prj786/ewe-plugin-passwords.git --enable

No 1Password needed: when the provider can't answer at all (its CLI isn't
installed, or can't reach its app) and a safe is set up, the picker offers
**Use Safe** (or press Enter). It sets this plugin's own `provider` to `ewe`
through `ewe-plugin set ewe.passwords provider ewe` and lists your logins
from Safe. `auto` (the default) already picks Safe once a safe is set up.

Settings: `provider` (auto / ewe / 1password / bitwarden / pass), `press_enter`.
Needs `wtype` (an ewe dependency). `ewe-pass` in this folder is the tool the
panel runs; `./ewe-pass status` says what it will do and why not.
