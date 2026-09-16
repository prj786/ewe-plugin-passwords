import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Hyprland
import qs

// ewe.passwords — "fill from my password manager" for ANY window (Super+P,
// a keybind this plugin's manifest declares; ewe generates the bind).
// Nothing on Linux fills into native apps: 1Password/Bitwarden only copy,
// KeePassXC/Proton Pass need a RemoteDesktop portal Hyprland lacks. So the
// shell does it: this picker asks bin/ewe-pass for the logins that match the
// focused window (URL host vs. app class/title, `app:<class>` tag, pins),
// then ewe-pass TYPES the chosen one through a virtual keyboard (wtype) into
// the window the picker was opened on — the picker closes first, focus goes
// back, and ewe-pass refuses to type if focus went anywhere else. Secrets
// never pass through QML: match returns titles/usernames only, fill/copy
// move the secret from the manager's CLI straight to wtype / wl-copy.
//   Enter  fill login (user ⇥ password)    Ctrl+Enter  password only
//   Ctrl+C copy username    Ctrl+Shift+C copy password    Ctrl+P pin to app
Scope {
    id: root
    property bool open: false
    // {provider: auto|1password|bitwarden|pass, press_enter: bool} — handed
    // to ewe-pass as environment, which beats ewe.conf [passwords]
    property var settings: ({})
    readonly property string tool: Qt.resolvedUrl("ewe-pass").toString().replace(/^file:\/\//, "")
    readonly property var env: [
        "EWE_PASS_PROVIDER=" + (root.settings.provider || "auto"),
        "EWE_PASS_ENTER=" + (root.settings.press_enter ? "1" : "0")
    ]

    property var target: ({ pid: 0, cls: "", title: "" })   // the window we opened on
    property var items: []             // [{id, title, username, host, score, reason}]
    property string providerLabel: ""
    property int matched: 0
    property bool busy: false
    property string error: ""
    property string hint: ""
    property string query: ""
    property int selected: 0
    property string toast: ""          // one-line status under the list ("Typed…", errors)

    readonly property var results: {
        var q = query.trim().toLowerCase()
        if (!q) return items
        var o = []
        for (var i = 0; i < items.length; i++) {
            var it = items[i]
            if ((it.title + " " + it.username + " " + it.host).toLowerCase().indexOf(q) >= 0) o.push(it)
        }
        return o
    }
    onResultsChanged: if (selected >= results.length) selected = Math.max(0, results.length - 1)

    function toggle() { root.open = !root.open }

    function openPicker() {
        // the window under the user's cursor NOW — before our layer takes focus
        var t = Hyprland.activeToplevel, o = t ? t.lastIpcObject : null
        target = { pid: o && o.pid ? o.pid : 0, cls: o && o.class ? o.class : "", title: o && o.title ? o.title : (t && t.title ? t.title : "") }
        items = []; error = ""; hint = ""; toast = ""; query = ""; selected = 0; matched = 0
        input.text = ""
        busy = true
        matchProc.command = [root.tool, "match", "--class", target.cls, "--title", target.title, "--limit", "60"]
        matchProc.running = true
    }

    function fill(what, enter) {
        var it = results[selected]
        if (!it) return
        var cmd = [root.tool, "fill", it.id, "--pid", String(target.pid), "--what", what]
        if (enter) cmd.push("--enter")
        root.open = false        // give the app its focus back first
        fillProc.command = cmd
        fillProc.running = true
    }
    function copy(what) {
        var it = results[selected]
        if (!it) return
        root.open = false
        copyProc.command = [root.tool, "copy", it.id, "--what", what]
        copyProc.running = true
    }
    function pin() {
        var it = results[selected]
        if (!it || !target.cls) return
        Quickshell.execDetached([root.tool, "remember", it.id, "--class", target.cls])
        toast = "Pinned " + it.title + " to " + target.cls
    }
    function notify(title, body) { Quickshell.execDetached(["notify-send", "-a", "ewe", "-i", "dialog-password", title, body || ""]) }

    onOpenChanged: if (root.open) root.openPicker()

    IpcHandler {
        target: "ewe.passwords"
        function toggle(): void { root.toggle() }
        function hide(): void { root.open = false }
    }

    Process {
        id: matchProc
        environment: root.env
        stdout: StdioCollector {
            onStreamFinished: {
                root.busy = false
                var d = null
                try { d = JSON.parse(this.text) } catch (e) { d = null }
                if (!d) { root.error = "ewe-pass gave no answer"; root.hint = "Is bin/ewe-pass on PATH?"; return }
                if (!d.ok) { root.error = d.error || "failed"; root.hint = d.hint || ""; return }
                root.providerLabel = d.label || d.provider || ""
                root.items = d.items || []
                root.matched = d.matched || 0
                root.selected = 0
            }
        }
    }
    Process {
        id: fillProc
        environment: root.env
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(this.text) } catch (e) { d = null }
                if (!d || !d.ok) root.notify("Couldn't fill", (d && d.error ? d.error : "no answer from ewe-pass") + (d && d.hint ? "\n" + d.hint : ""))
            }
        }
    }
    Process {
        id: copyProc
        environment: root.env
        stdout: StdioCollector {
            onStreamFinished: {
                var d = null
                try { d = JSON.parse(this.text) } catch (e) { d = null }
                if (!d || !d.ok) root.notify("Couldn't copy", (d && d.error ? d.error : "no answer from ewe-pass") + (d && d.hint ? "\n" + d.hint : ""))
                else root.notify("Copied " + d.copied, "It won't be kept in the clipboard history.")
            }
        }
    }

    PanelWindow {
        id: win
        visible: root.open || win.held
        screen: {
            var s = Quickshell.screens, fm = Hyprland.focusedMonitor
            if (fm) for (var i = 0; i < s.length; i++) if (s[i].name === fm.name) return s[i]
            return s.length > 0 ? s[0] : null
        }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "quickshell:ewe.passwords"
        WlrLayershell.layer: WlrLayer.Overlay
        // Exclusive while open so the search field types; None the instant we
        // close so focus returns to the app BEFORE ewe-pass starts typing.
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        anchors { top: true; bottom: true; left: true; right: true }

        property bool held: false
        Timer { id: closeTimer; interval: Math.max(1, Theme.durSlow + 60); onTriggered: win.held = false }
        Connections {
            target: root
            function onOpenChanged() {
                if (root.open) { closeTimer.stop(); win.held = true; input.forceActiveFocus() }
                else closeTimer.restart()
            }
        }

        MouseArea { anchors.fill: parent; onClicked: root.open = false }

        Rectangle {
            id: panel
            width: 500
            height: col.implicitHeight + 28
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.24)
            radius: Theme.radius
            color: Theme.panel
            opacity: root.open ? 1 : 0
            scale: root.open ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: Theme.durSlow; easing.type: Theme.ease } }
            Behavior on scale   { NumberAnimation { duration: Theme.durSlow; easing.type: Theme.ease } }
            layer.enabled: true
            layer.effect: Elevation {}
            MouseArea { anchors.fill: parent }   // swallow

            Column {
                id: col
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: 14
                spacing: 10

                // ── header: what we fill into, from where ──
                Item {
                    width: parent.width; height: 22
                    Text {
                        id: hdrIcon
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: Theme.icLock; font.family: Theme.fontIcons; font.pixelSize: 14; color: Theme.accent
                    }
                    Text {
                        anchors.left: hdrIcon.right; anchors.leftMargin: 8
                        anchors.right: prov.left; anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.target.title ? "Fill into " + root.target.title : "Fill into the focused window"
                        color: Theme.fg1; font.family: Theme.fontText; font.pixelSize: Theme.fsBody; font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Text {
                        id: prov
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        text: root.providerLabel
                        color: Theme.fg3; font.family: Theme.fontText; font.pixelSize: 11
                    }
                }

                // ── search ──
                Rectangle {
                    width: parent.width; height: 36; radius: Theme.radiusControl
                    color: Theme.bg3; border.color: input.activeFocus ? Theme.accent : Theme.stroke1; border.width: Theme.borderThin
                    Text { anchors.left: parent.left; anchors.leftMargin: 11; anchors.verticalCenter: parent.verticalCenter; text: Theme.icSearch; font.family: Theme.fontIcons; font.pixelSize: 12; color: Theme.fg3 }
                    TextInput {
                        id: input
                        anchors.fill: parent; anchors.leftMargin: 32; anchors.rightMargin: 10
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.fg1; font.family: Theme.fontText; font.pixelSize: Theme.fsSmall
                        selectionColor: Theme.accent; selectByMouse: true; clip: true
                        onTextChanged: { root.query = text; root.selected = 0 }
                        Text { visible: input.text.length === 0; anchors.verticalCenter: parent.verticalCenter; text: "Search logins…"; color: Theme.fg3; font: input.font }
                        Keys.onPressed: function (ev) {
                            var ctrl = ev.modifiers & Qt.ControlModifier, shift = ev.modifiers & Qt.ShiftModifier
                            if (ev.key === Qt.Key_Escape) { root.open = false; ev.accepted = true }
                            else if (ev.key === Qt.Key_Down) { root.selected = Math.min(root.selected + 1, root.results.length - 1); ev.accepted = true }
                            else if (ev.key === Qt.Key_Up)   { root.selected = Math.max(root.selected - 1, 0); ev.accepted = true }
                            else if (ev.key === Qt.Key_Return || ev.key === Qt.Key_Enter) { root.fill(ctrl ? "password" : "login", false); ev.accepted = true }
                            else if (ctrl && ev.key === Qt.Key_C) { root.copy(shift ? "password" : "username"); ev.accepted = true }
                            else if (ctrl && ev.key === Qt.Key_P) { root.pin(); ev.accepted = true }
                        }
                    }
                }

                // ── list ──
                ListView {
                    id: list
                    width: parent.width
                    height: root.results.length > 0 ? Math.min(root.results.length, 7) * 48 : 96
                    clip: true
                    spacing: 4
                    model: root.results
                    currentIndex: root.selected
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool sel: index === root.selected
                        width: list.width; height: 44
                        radius: Theme.radiusControl
                        color: sel ? Theme.card : (rowMa.containsMouse ? Theme.subtleHover : Theme.subtle)
                        border.width: sel ? 1 : 0; border.color: Theme.accent
                        Text {
                            id: glyph
                            anchors.left: parent.left; anchors.leftMargin: 12; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.reason === "pinned to this app" ? Theme.icPin : Theme.icUser
                            font.family: Theme.fontIcons; font.pixelSize: 13; color: row.sel ? Theme.accent : Theme.fg3
                        }
                        Column {
                            anchors.left: glyph.right; anchors.leftMargin: 12
                            anchors.right: cap.left; anchors.rightMargin: 8
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text { width: parent.width; text: modelData.title; color: Theme.fg1; font.family: Theme.fontText; font.pixelSize: Theme.fsSmall; font.weight: row.sel ? Font.DemiBold : Font.Normal; elide: Text.ElideRight }
                            Text { width: parent.width; visible: modelData.username !== ""; text: modelData.username; color: Theme.fg3; font.family: Theme.fontText; font.pixelSize: 11; elide: Text.ElideRight }
                        }
                        Text {
                            id: cap
                            anchors.right: parent.right; anchors.rightMargin: 12; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.score > 0 ? modelData.reason : modelData.host
                            color: modelData.score > 0 ? Theme.accent : Theme.fg3
                            font.family: Theme.fontText; font.pixelSize: 10
                        }
                        MouseArea {
                            id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: { root.selected = row.index; root.fill("login", false) }
                        }
                    }
                    // empty states — one Item, three messages
                    Item {
                        anchors.fill: parent
                        visible: list.count === 0
                        Spinner { anchors.centerIn: parent; visible: root.busy; font.pixelSize: 16 }
                        Column {
                            anchors.centerIn: parent; width: parent.width - 24; spacing: 4
                            visible: !root.busy
                            Text {
                                width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                                text: root.error ? root.error
                                    : (root.items.length === 0 ? "No logins in " + (root.providerLabel || "your password manager") + "."
                                                               : "Nothing matches “" + root.query + "”.")
                                color: root.error ? Theme.danger : Theme.fg3; font.family: Theme.fontText; font.pixelSize: Theme.fsSmall
                                maximumLineCount: 2; elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                                visible: root.hint !== ""
                                text: root.hint
                                color: Theme.fg3; font.family: Theme.fontText; font.pixelSize: 11
                                maximumLineCount: 3; elide: Text.ElideRight
                            }
                        }
                    }
                }

                // ── footer: the chords ──
                Text {
                    width: parent.width
                    text: root.toast !== "" ? root.toast
                        : (root.matched > 0 ? root.matched + " for this app · " : "") + "Enter fill · Ctrl+Enter password · Ctrl+C user · Ctrl+Shift+C password · Ctrl+P pin"
                    color: Theme.fg3; font.family: Theme.fontText; font.pixelSize: 10
                    elide: Text.ElideRight
                }
            }
        }
    }
}
