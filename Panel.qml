import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

// RDP Launcher panel: a list of saved RDP connections and a form to add or
// edit one. Profiles are stored in ~/.config/rdp-launcher/connections.json,
// passwords in the system keyring via bin/rdp-launcher. The panel never puts
// a password on a command line: it goes to the helper over stdin.
Panel {
  id: root
  moduleName: "rdp-launcher"
  ipcTarget: "rdp-launcher"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("bin/rdp-launcher")).replace(/^file:\/\//, ""))
  readonly property string configPath: Quickshell.env("HOME") + "/.config/rdp-launcher/connections.json"

  // ---- State
  property var connections: []
  readonly property var items: Model.sorted(connections)
  property var savedIds: ({})
  property int cursor: 0
  property string mode: "list"          // "list" | "edit"
  property var draft: Model.blank()
  property bool draftIsNew: true
  property string promptId: ""          // connection waiting for a typed password
  property string armedDeleteId: ""
  property string status: ""
  property bool statusIsError: false

  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Lifecycle
  function open() {
    root.mode = "list"
    root.promptId = ""
    root.armedDeleteId = ""
    root.status = ""
    connectionsFile.reload()
    refreshSaved()
    root.cursor = Math.min(root.cursor, Math.max(0, root.items.length - 1))
    root.controller.show()
  }

  function close() {
    root.promptId = ""
    root.armedDeleteId = ""
    root.controller.hide()
  }

  function toggle() { root.opened ? root.close() : root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function focusList() {
    Qt.callLater(function() { if (panel.loadedContent) panel.loadedContent.forceActiveFocus() })
  }

  // ---- Storage
  FileView {
    id: connectionsFile
    path: root.configPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.connections = Model.parse(text())
    onLoadFailed: root.connections = []
  }

  function persist(list) {
    root.connections = list
    connectionsFile.setText(Model.serialize(list))
  }

  function refreshSaved() {
    if (!savedProc.running) savedProc.running = true
  }

  Process {
    id: savedProc
    command: [root.helper, "saved"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = {}
        String(text || "").split("\n").forEach(function(line) {
          line = line.trim()
          if (Model.validId(line)) map[line] = true
        })
        root.savedIds = map
      }
    }
  }

  // ---- Secrets: one process per job, password written on start.
  Component {
    id: secretJob
    Process {
      property string secret: ""
      property bool reportErrors: false
      property string label: ""
      stdinEnabled: true
      onStarted: {
        write(secret + "\n")
        secret = ""
      }
      stderr: StdioCollector {
        waitForEnd: true
        onStreamFinished: {
          var msg = String(text || "").trim()
          if (msg !== "") {
            root.status = strings.t("errorStart").arg(msg.slice(0, 200))
            root.statusIsError = true
          }
        }
      }
      onExited: function(code) {
        root.refreshSaved()
        destroy()
      }
    }
  }

  function runSecret(args, secret) {
    var proc = secretJob.createObject(root, { command: [root.helper].concat(args), secret: secret || "" })
    proc.running = true
  }

  // ---- Actions
  function connectionById(id) {
    for (var i = 0; i < connections.length; i++) if (connections[i].id === id) return connections[i]
    return null
  }

  function connect(c) {
    if (!c) return
    root.armedDeleteId = ""
    if (c.savePassword && root.savedIds[c.id]) {
      launch(c, null)
    } else {
      // The row's own password field takes focus as it appears.
      root.promptId = c.id
    }
  }

  // password === null → helper reads it from the keyring.
  function launch(c, password) {
    var args = ["connect", c.id]
    if (password !== null) args.push("--password-stdin")
    root.status = strings.t("connecting").arg(Model.displayName(c))
    root.statusIsError = false
    root.promptId = ""
    root.persist(Model.touch(root.connections, c.id, Date.now()))
    runSecret(args, password === null ? "" : password)
    closeAfterLaunch.restart()
  }

  Timer {
    id: closeAfterLaunch
    interval: 700
    onTriggered: if (!root.statusIsError) root.close()
  }

  function submitPrompt(password) {
    var c = connectionById(root.promptId)
    if (!c) { root.promptId = ""; return }
    if (c.savePassword && password !== "") runSecret(["store", c.id, Model.displayName(c)], password)
    launch(c, password)
  }

  function startNew() {
    root.draft = Model.blank()
    root.draftIsNew = true
    root.mode = "edit"
    root.promptId = ""
    root.armedDeleteId = ""
    root.status = ""
  }

  function startEdit(c) {
    if (!c) return
    var copy = {}
    for (var k in c) copy[k] = c[k]
    root.draft = copy
    root.draftIsNew = false
    root.mode = "edit"
    root.promptId = ""
    root.armedDeleteId = ""
    root.status = ""
  }

  function cancelEdit() {
    root.mode = "list"
    root.status = ""
    focusList()
  }

  // values: plain object gathered by the form.
  function saveDraft(values, password, andConnect) {
    var c = Model.normalize({
      id: root.draftIsNew ? Model.newId() : root.draft.id,
      name: values.name, host: values.host, port: values.port,
      username: values.username, domain: values.domain,
      savePassword: values.savePassword, fullscreen: values.fullscreen,
      clipboard: values.clipboard, sound: values.sound,
      homeDrive: values.homeDrive, ignoreCert: values.ignoreCert,
      unicodeKeyboard: values.unicodeKeyboard,
      scale: values.scale, lastUsed: root.draft.lastUsed || 0
    })
    if (!c || c.host === "") {
      root.status = strings.t("errorHost")
      root.statusIsError = true
      return
    }
    persist(Model.upsert(root.connections, c))

    if (!c.savePassword) runSecret(["forget", c.id], "")
    else if (password !== "") runSecret(["store", c.id, Model.displayName(c)], password)

    root.mode = "list"
    root.status = ""
    for (var i = 0; i < root.items.length; i++) if (root.items[i].id === c.id) root.cursor = i
    focusList()

    if (andConnect) {
      if (password !== "") launch(c, password)
      else if (c.savePassword && root.savedIds[c.id]) launch(c, null)
      else connect(c)
    }
  }

  function requestDelete(c) {
    if (!c) return
    if (root.armedDeleteId !== c.id) {
      root.armedDeleteId = c.id
      disarm.restart()
      return
    }
    root.armedDeleteId = ""
    persist(Model.remove(root.connections, c.id))
    runSecret(["forget", c.id], "")
    root.cursor = Math.max(0, Math.min(root.cursor, root.items.length - 1))
  }

  Timer { id: disarm; interval: 3000; onTriggered: root.armedDeleteId = "" }

  function moveCursor(dy) {
    if (root.items.length === 0) return
    root.cursor = Math.max(0, Math.min(root.items.length - 1, root.cursor + dy))
    root.armedDeleteId = ""
  }

  // ---- UI
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(500))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      id: catcher
      implicitHeight: body.implicitHeight
      anchors.fill: parent
      blocked: root.mode !== "list" || root.promptId !== ""

      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: function(mods) { root.connect(root.items[root.cursor]) }
      onDeleteRequested: root.requestDelete(root.items[root.cursor])
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t, mods) {
        if (t === "n" || t === "N" || t === "+") root.startNew()
        else if (t === "e" || t === "E") root.startEdit(root.items[root.cursor])
      }

      Flickable {
        id: scroller
        anchors.fill: parent
        contentWidth: width
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        ColumnLayout {
          id: body
          width: scroller.width
          spacing: Style.space(10)

          // ---- Header
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: "󰢹"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.iconLarge
            }

            Text {
              Layout.fillWidth: true
              textFormat: Text.PlainText
              text: root.mode === "edit"
                ? (root.draftIsNew ? strings.t("newTitle") : strings.t("editTitle"))
                : strings.t("title")
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
              font.bold: true
              elide: Text.ElideRight
            }

            PanelActionButton {
              visible: root.mode === "list"
              iconText: "󰐕"
              tooltipText: strings.t("add")
              foreground: root.fg
              onClicked: root.startNew()
            }

            PanelActionButton {
              visible: root.mode === "edit"
              iconText: "󰅖"
              tooltipText: strings.t("cancel")
              foreground: root.fg
              onClicked: root.cancelEdit()
            }
          }

          PanelSeparator { Layout.fillWidth: true }

          // ---- List view
          ColumnLayout {
            visible: root.mode === "list"
            Layout.fillWidth: true
            spacing: Style.space(4)

            Text {
              visible: root.items.length === 0
              Layout.fillWidth: true
              Layout.topMargin: Style.space(12)
              Layout.bottomMargin: Style.space(4)
              textFormat: Text.PlainText
              text: strings.t("empty")
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
            }

            Button {
              visible: root.items.length === 0
              Layout.alignment: Qt.AlignHCenter
              Layout.bottomMargin: Style.space(8)
              bordered: true
              iconText: "󰐕"
              text: strings.t("add")
              foreground: root.fg
              onClicked: root.startNew()
            }

            Repeater {
              model: root.items

              ColumnLayout {
                id: rowWrap
                required property var modelData
                required property int index
                readonly property bool prompting: root.promptId === modelData.id
                Layout.fillWidth: true
                spacing: Style.space(4)

                CursorSurface {
                  id: row
                  Layout.fillWidth: true
                  implicitHeight: Style.space(50)
                  hasCursor: root.cursor === rowWrap.index && root.mode === "list"
                  foreground: root.fg

                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onEntered: root.cursor = rowWrap.index
                    onClicked: root.connect(rowWrap.modelData)
                  }

                  RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(10)

                    Text {
                      textFormat: Text.PlainText
                      text: "󰍹"
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.iconLarge
                    }

                    ColumnLayout {
                      Layout.fillWidth: true
                      spacing: Style.space(2)

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: Model.displayName(rowWrap.modelData)
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.subtitle
                        font.bold: true
                        elide: Text.ElideRight
                      }

                      Text {
                        Layout.fillWidth: true
                        textFormat: Text.PlainText
                        text: root.armedDeleteId === rowWrap.modelData.id
                          ? strings.t("deleteConfirm")
                          : Model.subtitle(rowWrap.modelData)
                            + (rowWrap.modelData.savePassword && root.savedIds[rowWrap.modelData.id] ? "  ·  󰌾" : "")
                        color: root.armedDeleteId === rowWrap.modelData.id ? Commons.Color.urgent : Qt.darker(root.fg, 1.4)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        elide: Text.ElideRight
                      }
                    }

                    PanelActionButton {
                      iconText: "󰢹"
                      tooltipText: strings.t("connect")
                      foreground: root.fg
                      onClicked: root.connect(rowWrap.modelData)
                    }
                    PanelActionButton {
                      iconText: "󰏫"
                      tooltipText: strings.t("edit")
                      foreground: root.fg
                      onClicked: root.startEdit(rowWrap.modelData)
                    }
                    PanelActionButton {
                      iconText: "󰆴"
                      tooltipText: root.armedDeleteId === rowWrap.modelData.id ? strings.t("deleteConfirm") : strings.t("delete")
                      foreground: root.armedDeleteId === rowWrap.modelData.id ? Commons.Color.urgent : root.fg
                      hoverColor: Commons.Color.urgent
                      onClicked: root.requestDelete(rowWrap.modelData)
                    }
                  }
                }

                // Inline password prompt for profiles without a saved password.
                RowLayout {
                  visible: rowWrap.prompting
                  Layout.fillWidth: true
                  Layout.leftMargin: Style.space(10)
                  Layout.rightMargin: Style.space(6)
                  spacing: Style.space(6)

                  TextField {
                    id: rowPrompt
                    Layout.fillWidth: true
                    password: true
                    revealed: promptReveal.revealed
                    placeholderText: strings.t("passwordFor").arg(rowWrap.modelData.username || Model.displayName(rowWrap.modelData))
                    foreground: root.fg
                    onVisibleChanged: if (visible) { text = ""; Qt.callLater(forceActiveFocus) }
                    Keys.onEscapePressed: { root.promptId = ""; root.focusList() }
                    onAccepted: { var p = text; text = ""; root.submitPrompt(p) }
                  }
                  PanelActionButton {
                    id: promptReveal
                    property bool revealed: false
                    iconText: revealed ? "󰈉" : "󰈈"
                    foreground: root.fg
                    onClicked: revealed = !revealed
                  }
                  Button {
                    bordered: true
                    text: strings.t("connect")
                    foreground: root.fg
                    onClicked: { var p = rowPrompt.text; rowPrompt.text = ""; root.submitPrompt(p) }
                  }
                }
              }
            }

            Text {
              visible: root.items.length > 0
              Layout.fillWidth: true
              Layout.topMargin: Style.space(4)
              textFormat: Text.PlainText
              text: strings.t("hint")
              color: Qt.darker(root.fg, 1.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
            }
          }

          // ---- Edit form (rebuilt each time the form opens)
          Loader {
            id: formLoader
            Layout.fillWidth: true
            active: root.mode === "edit"
            visible: active
            sourceComponent: formComponent
          }

          // ---- Status line
          Text {
            visible: root.status !== ""
            Layout.fillWidth: true
            textFormat: Text.PlainText
            text: root.status
            color: root.statusIsError ? Commons.Color.urgent : Qt.darker(root.fg, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            horizontalAlignment: Text.AlignHCenter
          }
        }
      }
    }
  }

  Component {
    id: formComponent

    ColumnLayout {
      id: form
      spacing: Style.space(8)

      readonly property bool hasSavedPassword: !root.draftIsNew && root.savedIds[root.draft.id] === true

      property bool fSavePassword: root.draft.savePassword
      property bool fFullscreen: root.draft.fullscreen
      property bool fClipboard: root.draft.clipboard
      property bool fSound: root.draft.sound
      property bool fHomeDrive: root.draft.homeDrive
      property bool fIgnoreCert: root.draft.ignoreCert
      property bool fUnicodeKeyboard: root.draft.unicodeKeyboard !== false
      property string fScale: root.draft.scale
      property bool revealed: false

      function values() {
        return {
          name: nameField.text, host: hostField.text, port: portField.text,
          username: userField.text, domain: domainField.text,
          savePassword: fSavePassword, fullscreen: fFullscreen,
          clipboard: fClipboard, sound: fSound, homeDrive: fHomeDrive,
          ignoreCert: fIgnoreCert, unicodeKeyboard: fUnicodeKeyboard, scale: fScale
        }
      }
      function save(andConnect) { root.saveDraft(values(), passwordField.text, andConnect) }

      // Focus waits a beat: the N / E key that opened the form is still being
      // delivered, and would otherwise land in the first field.
      Timer {
        running: true
        interval: 120
        onTriggered: {
          hostField.text = root.draft.host
          nameField.text = root.draft.name
          ;(root.draftIsNew ? hostField : nameField).forceActiveFocus()
        }
      }

      GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Style.space(10)
        rowSpacing: Style.space(4)

        Text { text: strings.t("field.name"); Layout.columnSpan: 2; textFormat: Text.PlainText; color: Qt.darker(root.fg, 1.3); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        TextField {
          Layout.fillWidth: true
          foreground: root.fg
          Keys.onEscapePressed: root.cancelEdit()
          onAccepted: form.save(false)
          id: nameField
          Layout.columnSpan: 2
          text: root.draft.name
          placeholderText: strings.t("placeholder.name")
        }

        Text { text: strings.t("field.host"); textFormat: Text.PlainText; color: Qt.darker(root.fg, 1.3); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        Text { text: strings.t("field.port"); textFormat: Text.PlainText; color: Qt.darker(root.fg, 1.3); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        TextField {
          Layout.fillWidth: true
          foreground: root.fg
          Keys.onEscapePressed: root.cancelEdit()
          onAccepted: form.save(false)
          id: hostField
          text: root.draft.host
          placeholderText: strings.t("placeholder.host")
        }
        TextField {
          id: portField
          Layout.fillWidth: false
          foreground: root.fg
          Keys.onEscapePressed: root.cancelEdit()
          onAccepted: form.save(false)
          Layout.preferredWidth: Style.space(80)
          text: String(root.draft.port || 3389)
          validator: IntValidator { bottom: 1; top: 65535 }
          inputMethodHints: Qt.ImhDigitsOnly
        }

        Text { text: strings.t("field.username"); textFormat: Text.PlainText; color: Qt.darker(root.fg, 1.3); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        Text { text: strings.t("field.domain"); textFormat: Text.PlainText; color: Qt.darker(root.fg, 1.3); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        TextField {
          Layout.fillWidth: true
          foreground: root.fg
          Keys.onEscapePressed: root.cancelEdit()
          onAccepted: form.save(false)
          id: userField
          text: root.draft.username
          placeholderText: strings.t("placeholder.username")
        }
        TextField {
          id: domainField
          Layout.fillWidth: false
          foreground: root.fg
          Keys.onEscapePressed: root.cancelEdit()
          onAccepted: form.save(false)
          Layout.preferredWidth: Style.space(140)
          text: root.draft.domain
          placeholderText: strings.t("placeholder.domain")
        }

        Text { text: strings.t("field.password"); Layout.columnSpan: 2; textFormat: Text.PlainText; color: Qt.darker(root.fg, 1.3); font.family: root.fontFamily; font.pixelSize: Style.font.caption; font.bold: true }
        RowLayout {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          spacing: Style.space(6)
          TextField {
          Layout.fillWidth: true
          foreground: root.fg
          Keys.onEscapePressed: root.cancelEdit()
          onAccepted: form.save(false)
            id: passwordField
            password: true
            revealed: form.revealed
            placeholderText: form.hasSavedPassword ? strings.t("placeholder.passwordKeep") : strings.t("placeholder.password")
          }
          PanelActionButton {
            iconText: form.revealed ? "󰈉" : "󰈈"
            foreground: root.fg
            onClicked: form.revealed = !form.revealed
          }
        }
      }

      Toggle {
        Layout.fillWidth: true
        label: strings.t("rememberPassword")
        description: strings.t("rememberPasswordDesc")
        checked: form.fSavePassword
        foreground: root.fg
        onClicked: form.fSavePassword = !form.fSavePassword
      }

      GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Style.space(6)
        rowSpacing: Style.space(6)

        Toggle {
          Layout.fillWidth: true; Layout.preferredWidth: 1; titleSize: Style.font.body
          label: strings.t("fullscreen"); checked: form.fFullscreen; foreground: root.fg
          onClicked: form.fFullscreen = !form.fFullscreen
        }
        Toggle {
          Layout.fillWidth: true; Layout.preferredWidth: 1; titleSize: Style.font.body
          label: strings.t("clipboard"); checked: form.fClipboard; foreground: root.fg
          onClicked: form.fClipboard = !form.fClipboard
        }
        Toggle {
          Layout.fillWidth: true; Layout.preferredWidth: 1; titleSize: Style.font.body
          label: strings.t("sound"); checked: form.fSound; foreground: root.fg
          onClicked: form.fSound = !form.fSound
        }
        Toggle {
          Layout.fillWidth: true; Layout.preferredWidth: 1; titleSize: Style.font.body
          label: strings.t("homeDrive"); checked: form.fHomeDrive; foreground: root.fg
          onClicked: form.fHomeDrive = !form.fHomeDrive
        }
        Toggle {
          Layout.fillWidth: true; Layout.preferredWidth: 1; titleSize: Style.font.body
          label: strings.t("ignoreCert"); checked: form.fIgnoreCert; foreground: root.fg
          onClicked: form.fIgnoreCert = !form.fIgnoreCert
        }
        Toggle {
          Layout.fillWidth: true; Layout.preferredWidth: 1; titleSize: Style.font.body
          label: strings.t("unicodeKeyboard"); checked: form.fUnicodeKeyboard; foreground: root.fg
          onClicked: form.fUnicodeKeyboard = !form.fUnicodeKeyboard
        }
        Button {
          Layout.fillWidth: true; Layout.preferredWidth: 1
          Layout.fillHeight: true
          bordered: true
          focusable: true
          iconText: "󰍹"
          text: strings.t("scale").arg(form.fScale === "auto" ? strings.t("scaleAuto") : form.fScale + "%")
          foreground: root.fg
          onClicked: form.fScale = Model.nextScale(form.fScale)
        }
      }

      RowLayout {
        Layout.fillWidth: true
        Layout.topMargin: Style.space(4)
        spacing: Style.space(8)

        Item { Layout.fillWidth: true }
        Button {
          bordered: true; focusable: true
          text: strings.t("cancel"); foreground: root.fg
          onClicked: root.cancelEdit()
        }
        Button {
          bordered: true; focusable: true
          iconText: "󰆓"
          text: strings.t("save"); foreground: root.fg
          onClicked: form.save(false)
        }
        Button {
          bordered: true; focusable: true; active: true
          iconText: "󰢹"
          text: strings.t("connect"); foreground: root.fg
          tooltipText: strings.t("saveConnect")
          onClicked: form.save(true)
        }
      }
    }
  }
}
