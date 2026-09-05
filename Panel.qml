import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Speaker Mode: this machine takes the Bluetooth A2DP *sink* role so a paired
// phone can play through its speakers.
//
// The bar icon is the whole point of the widget — it answers "is my phone
// going to come out of these speakers right now" without opening anything.
// The panel behind it carries the switch, what the phone is, and transport
// controls for whatever it is playing.
Panel {
  id: root
  moduleName: "io.github.corrreia.speaker"
  ipcTarget: "io.github.corrreia.speaker"
  manageIpc: false

  // The helper ships inside the plugin, so the widget keeps working from a
  // clone or a checkout in a different directory.
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "")
  readonly property string helper: pluginDir + "bin/omarchy-speaker-mode"

  property string focusSection: "power"
  property bool cursorActive: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Three states worth distinguishing at a glance, and no more: blocked,
  // armed, and actually playing.
  readonly property string barIcon: !speaker.enabled ? "󰓄" : (speaker.streaming ? "󰜟" : "󰦢")
  // Accent rather than urgent for the playing state. `bar.urgent` is what the
  // first-party widgets use for packet loss, failed connections and destructive
  // actions, so borrowing it for healthy playback reads as a warning. The glyph
  // already changes between states; colour only has to say "this one is live".
  readonly property color barIconColor: speaker.streaming
    ? Color.accent
    : (speaker.enabled ? barForeground : Qt.darker(barForeground, 1.6))
  readonly property string barTooltip: speaker.statusText

  readonly property var player: Model.pickBluetoothPlayer(
    Mpris.players ? Mpris.players.values : [], speaker.mac, speaker.device)
  readonly property string trackLine: Model.trackLine(player)

  // "System default" first, so the picker works before the user has an
  // opinion and keeps following the desktop's own default if they never do.
  readonly property var outputOptions: {
    var list = [{ value: "default", label: "System default" }]
    var items = speaker.sinks || []
    for (var i = 0; i < items.length; i++) {
      var name = String(items[i].name || "")
      if (name === "") continue
      list.push({ value: name, label: String(items[i].description || name) })
    }
    return list
  }

  readonly property var micOptions: {
    var list = [{ value: "default", label: "System default" }]
    var items = speaker.sources || []
    for (var i = 0; i < items.length; i++) {
      var name = String(items[i].name || "")
      if (name === "") continue
      list.push({ value: name, label: String(items[i].description || name) })
    }
    return list
  }
  readonly property string trackTitle: player ? String(player.trackTitle || "") : ""
  readonly property string trackArtist: player ? Model.cleanArtist(player.trackArtist) : ""
  readonly property string trackAlbum: player ? String(player.trackAlbum || "") : ""

  // Cover art, fetched from the phone over Bluetooth — AVRCP hands us an image
  // handle, the helper pulls the image itself over an OBEX imaging session.
  // Keyed on the track so a change re-runs it; the helper caches per album, so
  // most of those runs cost a stat and nothing on the air.
  readonly property string artKey: trackTitle + "|" + trackArtist + "|" + trackAlbum
  property string artPath: ""
  property bool settingsOpen: false
  property bool artExpanded: false
  property string artFullPath: ""
  property string artSavedTo: ""

  // The row only ever holds the 200x200 thumbnail. The full image costs a
  // second transfer, so it is fetched the first time the cover is opened
  // rather than for every track that scrolls past.
  function fetchArtFull() {
    if (artFullProc.running || speaker.mac === "") return
    artFullProc.command = [root.helper, "artwork-full", speaker.mac]
    artFullProc.running = true
  }

  readonly property bool hasArt: artPath !== "" || artFullPath !== ""

  // One source of truth for both presentations: our own full-size copy if we
  // have it, otherwise our thumbnail.
  //
  // BlueZ downloads cover art itself as well and publishes it as the MPRIS
  // artUrl, but that is deliberately not used: it is written under /tmp while
  // being read, so QML catches it half-written, fails to decode it and caches
  // the failure. Our own copy is complete before its path is published, keyed
  // by album, and comes from the largest variant the phone offers rather than
  // the smaller native one.
  readonly property string coverSource: artFullPath !== "" ? "file://" + artFullPath
    : (artPath !== "" ? "file://" + artPath : "")

  function toggleArtExpanded() {
    if (!hasArt) return
    artExpanded = !artExpanded
    if (artExpanded && artFullPath === "") fetchArtFull()
  }

  function saveArt() {
    if (artSaveProc.running || speaker.mac === "") return
    artSavedTo = ""
    artSaveProc.command = [root.helper, "artwork-save", speaker.mac]
    artSaveProc.running = true
  }

  function fetchArt() {
    if (artProc.running || speaker.mac === "") return
    artProc.command = [root.helper, "artwork", speaker.mac]
    artProc.running = true
  }

  onArtKeyChanged: {
    artPath = ""
    artFullPath = ""
    if (artKey === "||") return   // all three fields empty: no track
    fetchArt()
    // The card deliberately survives a track change. Collapsing on every skip
    // made the expanded view unusable — you would open it, skip, and be back
    // at the thumbnail. Pull the full image straight away so an already-open
    // card fills in instead of sitting on the placeholder.
    if (artExpanded) fetchArtFull()
  }

  readonly property bool hasMedia: player !== null && trackLine !== ""

  // Cursor targets, in visual order. "media" only exists while a track is up.
  readonly property var sections: {
    var list = ["power"]
    if (speaker.enabled && speaker.connected) list.push("mic")
    if (hasMedia) list.push("media")
    return list
  }


  // A bar surface exists per monitor, so a click or an IPC call reaches one
  // instance only. Push the fresh state to the peers, or the icon on the other
  // screen keeps showing the old state until its own poll comes round.
  function refreshState() { speaker.refresh() }

  function refreshPeers() {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && typeof items[i].refreshState === "function")
        items[i].refreshState()
    }
  }
  function ensureCursor() {
    if (sections.indexOf(focusSection) === -1) focusSection = "power"
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    ensureCursor()
    if (dy === 0) return
    var index = sections.indexOf(focusSection)
    focusSection = sections[Math.max(0, Math.min(sections.length - 1, index + dy))]
  }

  function activateCursor() {
    ensureCursor()
    if (focusSection === "power") speaker.toggle()
    else if (focusSection === "mic") micPicker.toggle()
    else if (focusSection === "media" && player && player.canTogglePlaying) player.togglePlaying()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    cursorActive = false
    focusSection = "power"
    speaker.refresh()
    speaker.refreshSources()
    speaker.refreshSinks()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Unloading the plugin — disabled, removed, or the shell restarting — should
  // not leave background services running against it. `omarchy plugin remove`
  // deletes the directory and runs nothing, so this is the only hook there is.
  // It stops the daemons only: speaker mode's own state is left alone, so a
  // shell restart brings them straight back on the next sync.
  Component.onDestruction: {
    if (root.helper === "") return
    teardownProc.command = [root.helper, "stop-daemons"]
    teardownProc.running = true
  }

  HelperProcess { id: teardownProc }

  Service {
    id: speaker
    settings: root.settings
    helper: root.helper
    active: root.opened
  }


  // The helper prints one path, on its own line, once the file is complete and
  // has passed its checks. Anything else is not a path.
  function artPathFrom(text) {
    var path = String(text || "").trim()
    return path.indexOf("/") === 0 && path.indexOf("\n") === -1 ? path : ""
  }

  // A fetch is a session to the phone plus up to ten seconds waiting on the
  // transfer, so the art processes get a little longer than the default.
  //
  // A failed fetch is usually the phone not having opened its imaging
  // responder yet rather than a permanent no, so give it one more go before
  // settling on the placeholder.
  HelperProcess {
    id: artProc
    deadlineMs: 30000
    onCollected: function(text) {
      var path = root.artPathFrom(text)
      if (path !== "") root.artPath = path
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && root.artPath === "" && root.artKey !== "||") artRetry.restart()
    }
  }

  HelperProcess {
    id: artFullProc
    deadlineMs: 30000
    onCollected: function(text) {
      var path = root.artPathFrom(text)
      if (path !== "") root.artFullPath = path
    }
  }

  // Saving is a deliberate, one-off action, so it says so out loud rather than
  // leaving the user to guess where the file went.
  HelperProcess {
    id: artSaveProc
    deadlineMs: 30000
    onCollected: function(text) {
      var path = root.artPathFrom(text)
      if (path !== "") root.artSavedTo = path
    }
    onExited: function(exitCode) {
      if (notifyProc.running) return
      if (exitCode === 0 && root.artSavedTo !== "") {
        notifyProc.command = ["notify-send", "-i", root.artSavedTo, "--",
                              "Cover saved", root.artSavedTo]
      } else {
        notifyProc.command = ["notify-send", "-u", "critical", "--",
                              "Speaker Mode", "Could not save the cover"]
      }
      notifyProc.running = true
    }
  }

  HelperProcess { id: notifyProc; deadlineMs: 10000 }
  Timer {
    id: artRetry
    interval: 2500
    repeat: false
    onTriggered: if (root.artPath === "") root.fetchArt()
  }
  Connections {
    target: speaker
    function onSettled() { root.refreshPeers() }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function on(): string { speaker.run("on"); return "ok" }
    function off(): string { speaker.run("off"); return "ok" }
    function toggleSpeaker(): string { speaker.toggle(); return "ok" }
    function settings(): string { root.settingsOpen = !root.settingsOpen; return root.settingsOpen ? "open" : "closed" }
    function cover(): string { root.toggleArtExpanded(); return root.artExpanded ? "open" : "closed" }
    function status(): string { return speaker.statusText }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barIcon
    foreground: root.barIconColor
    useActiveColor: false
    tooltipText: root.barTooltip
    onPressed: function(buttonCode) {
      // Right click is the fast path: flip speaker mode without the panel.
      if (buttonCode === Qt.RightButton) speaker.toggle()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    // No cap of our own: fittedContentHeight already clamps to the space the
    // screen has. Capping it here as well meant the panel stopped growing once
    // both the settings block and the cover were open, and quietly clipped
    // Now Playing.
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (micPicker.popupOpen) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: if (!micPicker.popupOpen && root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var key = String(t).toLowerCase()
        if (key === "s") speaker.toggle()
        else if (key === "r") speaker.refresh()
        else if (key === "n" && root.player && root.player.canGoNext) root.player.next()
        else if (key === "p" && root.player && root.player.canGoPrevious) root.player.previous()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          Item {
            id: header
            width: parent.width
            implicitHeight: hero.implicitHeight
            // The hero's own `root` is PanelHero, so its children reach panel
            // state through `header` rather than through `root`.
            readonly property bool ringVisible: root.cursorActive && root.focusSection === "power"
            function focusHero() {
              root.cursorActive = true
              root.focusSection = "power"
            }

            PanelHero {
              id: hero
              width: parent.width
              title: "Speaker Mode"
              meta: speaker.statusText
              detail: Model.batteryLabel(speaker.battery)
              foreground: root.foreground
              fontFamily: root.fontFamily
              iconOpacity: speaker.enabled ? 1.0 : 0.5
              iconComponent: Component {
                Text {
                  textFormat: Text.PlainText
                  text: root.barIcon
                  color: speaker.streaming ? root.accent : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.display
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: speaker.enabled
                  busy: speaker.busy
                  hasCursor: header.ringVisible
                  foreground: hero.foreground
                  onHovered: function(on) { if (on) header.focusHero() }
                  onToggled: speaker.toggle()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: speaker.enabled ? "Stop accepting phone audio" : "Accept phone audio"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            text: speaker.lastError !== "" ? speaker.lastError : speaker.detailText
            color: speaker.lastError !== "" ? root.urgent : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator {
            visible: speaker.enabled
            foreground: root.foreground
          }

          Column {
            visible: speaker.enabled
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "PHONE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              textFormat: Text.PlainText
              visible: !speaker.connected
              width: parent.width
              text: "No phone connected. Pick this machine in your phone's Bluetooth output list."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            Column {
              visible: speaker.connected
              width: parent.width
              spacing: Style.spacing.labelGap

              InfoPair { label: "Device"; value: speaker.device || "Unknown" }
              InfoPair { label: "Output"; value: Model.sinkLabel(speaker.sink, speaker.sinkDescription) }
              InfoPair { label: "Link"; value: speaker.streaming ? "Streaming" : "Idle" }
            }
          }

          PanelSeparator {
            visible: speaker.enabled && speaker.connected
            foreground: root.foreground
          }

          // Everything that is a preference rather than a status lives behind
          // one collapsed header, so the panel opens on what is happening now
          // and not on a wall of controls.
          Column {
            visible: speaker.enabled && speaker.connected
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              implicitHeight: settingsLabel.implicitHeight

              PanelSectionHeader {
                id: settingsLabel
                text: "SETTINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Text {
                textFormat: Text.PlainText
                anchors.right: parent.right
                anchors.verticalCenter: settingsLabel.verticalCenter
                text: root.settingsOpen ? "󰅃" : "󰅀"
                color: Qt.darker(root.foreground, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.settingsOpen = !root.settingsOpen
              }
            }

            Item {
              width: parent.width
              height: root.settingsOpen ? settingsBody.implicitHeight : 0
              visible: height > 0
              clip: true

              Behavior on height {
                NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
              }

              Column {
                id: settingsBody
                width: parent.width
                spacing: Style.space(10)

                SettingLabel { text: "Output" }

                // The phone's audio is an ordinary playback stream, so sending
                // it elsewhere is just moving that stream. "System default"
                // leaves it following the desktop's own output.
                Dropdown {
                  id: outputPicker
                  width: parent.width
                  showLabel: false
                  fontFamily: root.fontFamily
                  value: speaker.outputSink === "" ? "default" : speaker.outputSink
                  options: root.outputOptions
                  onChanged: function(v) { speaker.setOutput(v) }
                }

                SettingLabel { text: "Microphone for calls" }

                // Calls ride HFP, not A2DP, and the phone has no say in which
                // microphone this machine sends.
                Dropdown {
                  id: micPicker
                  width: parent.width
                  showLabel: false
                  fontFamily: root.fontFamily
                  value: speaker.micSource === "" ? "default" : speaker.micSource
                  options: root.micOptions
                  onChanged: function(v) { speaker.setMic(v) }
                  onHovered: function(on) {
                    if (on) {
                      root.cursorActive = true
                      root.focusSection = "mic"
                    }
                  }
                  hasCursor: root.cursorActive && root.focusSection === "mic"
                }

                Toggle {
                  width: parent.width
                  label: "Message notifications"
                  description: speaker.micActive
                    ? "On a call" : "Texts from the phone appear on the desktop"
                  checked: speaker.notificationsEnabled
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: speaker.setNotifications(!speaker.notificationsEnabled)
                }
              }
            }
          }

          PanelSeparator {
            visible: root.hasMedia
            foreground: root.foreground
          }

          Column {
            visible: root.hasMedia
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              text: "NOW PLAYING"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Two presentations of one track, swapped by clicking the cover: a
            // compact row, and a card built around the artwork. Only ever one
            // on screen — a thumbnail sitting next to a large copy of itself
            // was the wrong idea. The stack owns the height so the panel grows
            // into the card rather than snapping to it.
            Item {
              id: mediaStack
              width: parent.width
              height: root.artExpanded ? expandedCard.implicitHeight
                                       : compactRow.implicitHeight
              clip: true

              Behavior on height {
                NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
              }

              // ---------------------------------------------------- compact
              CursorSurface {
                id: compactRow
                width: parent.width
                opacity: root.artExpanded ? 0 : 1
                visible: opacity > 0
                hasCursor: root.cursorActive && root.focusSection === "media"
                foreground: root.foreground
                implicitHeight: compactContent.implicitHeight + Style.spacing.rowPaddingX

                Behavior on opacity { NumberAnimation { duration: 140 } }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: {
                    root.cursorActive = true
                    root.focusSection = "media"
                  }
                  onClicked: if (root.player && root.player.canTogglePlaying) root.player.togglePlaying()
                }

                Row {
                  id: compactContent
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.spacing.rowPaddingX
                  anchors.rightMargin: Style.spacing.rowPaddingX
                  spacing: Style.space(10)

                  BorderSurface {
                    id: artFrame
                    width: Style.space(52)
                    height: Style.space(52)
                    anchors.verticalCenter: parent.verticalCenter
                    radius: Style.spacing.labelGap
                    color: Style.normalFillFor(root.foreground, root.accent)
                    borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
                    clip: true

                    Image {
                      id: artImage
                      anchors.fill: parent
                      anchors.margins: Style.space(2)
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      // The decode is bounded here as well as by the helper's
                      // checks: whatever the file claims, no more than this
                      // many pixels are ever allocated for it.
                      sourceSize: Qt.size(512, 512)
                      source: root.coverSource
                      visible: source !== "" && status === Image.Ready
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.centerIn: parent
                      visible: !artImage.visible
                      text: "󰝚"
                      color: Qt.darker(root.foreground, 1.6)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.title
                    }

                    // The art owns its own click so opening the cover does not
                    // also pause the music the row behind it controls.
                    MouseArea {
                      id: artClick
                      anchors.fill: parent
                      hoverEnabled: true
                      enabled: root.hasArt
                      cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                      onClicked: root.toggleArtExpanded()
                    }

                    PanelToolTip {
                      visible: artClick.containsMouse && artClick.enabled
                      text: "Show cover"
                      fontFamily: root.fontFamily
                    }
                  }

                  Column {
                    width: parent.width - artFrame.width - compactTransport.implicitWidth - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      textFormat: Text.PlainText
                      width: parent.width
                      text: root.trackTitle
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: root.trackArtist !== ""
                      width: parent.width
                      text: root.trackArtist
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      elide: Text.ElideRight
                    }

                    Text {
                      textFormat: Text.PlainText
                      visible: root.trackAlbum !== ""
                      width: parent.width
                      text: root.trackAlbum
                      color: root.dim
                      opacity: 0.7
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Row {
                    id: compactTransport
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    PanelActionButton {
                      iconText: "󰒮"
                      tooltipText: "Previous"
                      enabled: root.player !== null && root.player.canGoPrevious
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.player) root.player.previous()
                    }

                    PanelActionButton {
                      iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"
                      tooltipText: root.player && root.player.isPlaying ? "Pause" : "Play"
                      enabled: root.player !== null && root.player.canTogglePlaying
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.player) root.player.togglePlaying()
                    }

                    PanelActionButton {
                      iconText: "󰒭"
                      tooltipText: "Next"
                      enabled: root.player !== null && root.player.canGoNext
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      onClicked: if (root.player) root.player.next()
                    }
                  }
                }
              }

              // ------------------------------------------------------- card
              Column {
                id: expandedCard
                width: parent.width
                opacity: root.artExpanded ? 1 : 0
                visible: opacity > 0
                spacing: Style.space(12)

                Behavior on opacity { NumberAnimation { duration: 140 } }

                BorderSurface {
                  id: bigFrame
                  width: parent.width
                  height: width
                  radius: Style.cornerRadius
                  color: Style.normalFillFor(root.foreground, root.accent)
                  borderSpec: Border.controlSpec("normal", root.foreground, root.accent)
                  clip: true

                  Image {
                    id: bigArt
                    anchors.fill: parent
                    anchors.margins: Style.space(3)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    // AVRCP artwork is small — this phone's native image is
                    // 200x200 — so it is scaled up to fill the card. smooth
                    // and mipmap keep that from looking like a mosaic.
                    smooth: true
                    mipmap: true
                    sourceSize: Qt.size(1024, 1024)
                    source: root.coverSource
                    visible: source !== "" && status === Image.Ready
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.centerIn: parent
                    visible: !bigArt.visible
                    text: "Loading cover…"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                  }

                  MouseArea {
                    id: bigArtClick
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.toggleArtExpanded()
                  }

                  // Hover-only, so the artwork is unobstructed at rest.
                  PanelActionButton {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: Style.space(8)
                    visible: bigArtClick.containsMouse && bigArt.visible
                    iconText: "󰇚"
                    tooltipText: "Save cover to Pictures"
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.saveArt()
                  }
                }

                Text {
                  textFormat: Text.PlainText
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.trackTitle
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.subtitle
                  font.bold: true
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.trackArtist !== ""
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.trackArtist
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  textFormat: Text.PlainText
                  visible: root.trackAlbum !== ""
                  width: parent.width
                  horizontalAlignment: Text.AlignHCenter
                  text: root.trackAlbum
                  color: root.dim
                  opacity: 0.7
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }

                Row {
                  anchors.horizontalCenter: parent.horizontalCenter
                  spacing: Style.space(10)

                  PanelActionButton {
                    iconText: "󰒮"
                    tooltipText: "Previous"
                    enabled: root.player !== null && root.player.canGoPrevious
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: if (root.player) root.player.previous()
                  }

                  PanelActionButton {
                    iconText: root.player && root.player.isPlaying ? "󰏤" : "󰐊"
                    tooltipText: root.player && root.player.isPlaying ? "Pause" : "Play"
                    enabled: root.player !== null && root.player.canTogglePlaying
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: if (root.player) root.player.togglePlaying()
                  }

                  PanelActionButton {
                    iconText: "󰒭"
                    tooltipText: "Next"
                    enabled: root.player !== null && root.player.canGoNext
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: if (root.player) root.player.next()
                  }
                }
              }
            }
          }
        }
      }
    }
  }

  component SettingLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}
