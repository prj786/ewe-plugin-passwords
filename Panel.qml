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
            // a solid panel (Launcher panel card): surfaceRaised, a
            // borderSubtle outline, radiusRounded; wider with Text size
            width: Theme.grow(Theme.panelLg)
            height: col.implicitHeight + 2 * (Theme.spaceS + Theme.spaceXs)
            anchors.horizontalCenter: parent.horizontalCenter
            y: Math.round(parent.height * 0.24)
            radius: Theme.radiusRounded
            color: Theme.surfaceRaised
            border.color: Theme.borderSubtle; border.width: Theme.borderWidth1
            // fade plus a slideOffset lift, in at durBase and out at durFast
            opacity: root.open ? 1 : 0
            Behavior on opacity { NumberAnimation { duration: root.open ? Theme.durBase : Theme.durFast; easing.type: Theme.ease } }
            transform: Translate {
                y: (root.open || Theme.reduceMotion) ? 0 : Theme.slideOffset
                Behavior on y { NumberAnimation { duration: Theme.durBase; easing.type: Theme.ease } }
            }
            layer.enabled: true
            layer.effect: Elevation {}
            MouseArea { anchors.fill: parent }   // swallow

            Column {
                id: col
                anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                anchors.margins: Theme.spaceS + Theme.spaceXs
                spacing: Theme.spaceS

                // ── header: what we fill into, from where ──
                Item {
                    width: parent.width; height: Math.max(Theme.iconMd, Theme.type.bodyStrong.lineHeight)
                    Text {
                        id: hdrIcon
                        anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter
                        text: Theme.icLock; font.family: Theme.fontIcons; font.pixelSize: Theme.iconMd; color: Theme.accentText
                    }
                    Text {
                        anchors.left: hdrIcon.right; anchors.leftMargin: Theme.spaceS
                        anchors.right: prov.left; anchors.rightMargin: Theme.spaceS
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.target.title ? "Fill into " + root.target.title : "Fill into the focused window"
                        color: Theme.textPrimary
                        font.family: Theme.type.bodyStrong.family; font.pixelSize: Theme.type.bodyStrong.size; font.weight: Theme.type.bodyStrong.weight
                        elide: Text.ElideRight
                    }
                    Text {
                        id: prov
                        anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter
                        text: root.providerLabel
                        color: Theme.textMuted; font.family: Theme.type.caption.family; font.pixelSize: Theme.type.caption.size
                    }
                }

                // ── search: the xl Search field (the launcher's) ──
                Rectangle {
                    width: parent.width; height: Theme.controlXl; radius: Theme.radiusPrimary
                    color: Theme.surfaceSunken
                    border.color: input.activeFocus ? Theme.focusRing : Theme.borderStrong
                    border.width: Theme.fieldBorderWidth
                    Text { id: searchIcon; anchors.left: parent.left; anchors.leftMargin: Theme.spaceS + Theme.spaceXs; anchors.verticalCenter: parent.verticalCenter; text: Theme.icSearch; font.family: Theme.fontIcons; font.pixelSize: Theme.iconLg; color: Theme.textMuted }
                    TextInput {
                        id: input
                        anchors.fill: parent; anchors.leftMargin: Theme.spaceS + Theme.spaceXs + Theme.iconLg + Theme.spaceS; anchors.rightMargin: Theme.spaceS + Theme.spaceXs
                        verticalAlignment: TextInput.AlignVCenter
                        color: Theme.textPrimary; font.family: Theme.type.bodyLg.family; font.pixelSize: Theme.type.bodyLg.size
                        selectionColor: Theme.accent; selectedTextColor: Theme.onAccent; selectByMouse: true; clip: true
                        onTextChanged: { root.query = text; root.selected = 0 }
                        Text { visible: input.text.length === 0; anchors.verticalCenter: parent.verticalCenter; text: "Search logins"; color: Theme.textMuted; font: input.font }
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

                // ── list: List rows, two lines each ──
                ListView {
                    id: list
                    // a row holds a body title over a caption username
                    readonly property int rowH: Math.max(Theme.controlXl, Theme.type.body.lineHeight + Theme.type.caption.lineHeight + 2 * Theme.spaceXs)
                    width: parent.width
                    height: root.results.length > 0 ? Math.min(root.results.length, 7) * (rowH + spacing) - spacing : 2 * Theme.control2xl
                    clip: true
                    spacing: Theme.spaceXxs
                    model: root.results
                    currentIndex: root.selected
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Rectangle {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool sel: index === root.selected
                        width: list.width; height: list.rowH
                        radius: Theme.radiusSecondary
                        color: sel ? Theme.accentSubtle : rowMa.pressed ? Theme.surfacePressed : rowMa.containsMouse ? Theme.surfaceHover : "transparent"
                        Text {
                            id: glyph
                            anchors.left: parent.left; anchors.leftMargin: Theme.spaceS; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.reason === "pinned to this app" ? Theme.icPin : Theme.icUser
                            font.family: Theme.fontIcons; font.pixelSize: Theme.iconMd; color: row.sel ? Theme.accentText : Theme.textSecondary
                        }
                        Column {
                            anchors.left: glyph.right; anchors.leftMargin: Theme.spaceS + Theme.spaceXs
                            anchors.right: cap.left; anchors.rightMargin: Theme.spaceS
                            anchors.verticalCenter: parent.verticalCenter
                            Text { width: parent.width; text: modelData.title; color: Theme.textPrimary
                                   font.family: Theme.type.body.family; font.pixelSize: Theme.type.body.size
                                   font.weight: row.sel ? Theme.fontWeightMedium : Theme.fontWeightRegular; elide: Text.ElideRight }
                            Text { width: parent.width; visible: modelData.username !== ""; text: modelData.username; color: Theme.textMuted
                                   font.family: Theme.type.caption.family; font.pixelSize: Theme.type.caption.size; elide: Text.ElideRight }
                        }
                        Text {
                            id: cap
                            anchors.right: parent.right; anchors.rightMargin: Theme.spaceS; anchors.verticalCenter: parent.verticalCenter
                            text: modelData.score > 0 ? modelData.reason : modelData.host
                            color: modelData.score > 0 ? Theme.accentText : Theme.textMuted
                            font.family: Theme.type.caption.family; font.pixelSize: Theme.type.caption.size
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
                        Spinner { anchors.centerIn: parent; visible: root.busy; size: Theme.iconMd }
                        Column {
                            anchors.centerIn: parent; width: parent.width - 2 * Theme.spaceMd; spacing: Theme.spaceXs
                            visible: !root.busy
                            Text {
                                width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                                text: root.error ? root.error
                                    : (root.items.length === 0 ? "No logins in " + (root.providerLabel || "your password manager") + "."
                                                               : "Nothing matches “" + root.query + "”.")
                                color: root.error ? Theme.danger : Theme.textSecondary
                                font.family: Theme.type.body.family; font.pixelSize: Theme.type.body.size
                                maximumLineCount: 2; elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.Wrap
                                visible: root.hint !== ""
                                text: root.hint
                                color: Theme.textMuted; font.family: Theme.type.caption.family; font.pixelSize: Theme.type.caption.size
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
                    color: Theme.textMuted; font.family: Theme.type.caption.family; font.pixelSize: Theme.type.caption.size
                    elide: Text.ElideRight
                }
            }
        }
    }
}
