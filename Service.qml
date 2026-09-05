import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Polls `omarchy-speaker-mode status` and exposes the result as properties.
// All privileged-ish work (bluetoothctl, pactl, systemd-run) lives in the
// helper script; this object only decides *when* to run it.
Item {
  id: root

  property var settings: ({})
  property string helper: ""
  property bool active: true          // panel open — poll faster
  readonly property int refreshIntervalSec: {
    var value = settings ? settings.refreshIntervalSec : undefined
    return value === undefined || value === null ? 5 : Math.max(2, value)
  }

  property bool enabled: false
  property bool connected: false
  property bool streaming: false
  property bool discoverable: false
  property bool mprisProxy: false
  property int battery: -1
  property string device: ""
  property string mac: ""
  property string card: ""
  property string profile: ""
  property string sink: ""
  property string sinkDescription: ""
  property bool micActive: false
  property string micSource: ""
  property var sources: []
  property var sinks: []
  property bool notificationsEnabled: true
  property string outputSink: ""

  // Set the instant the switch is clicked so the knob throws without waiting
  // for a poll; the next status read overwrites it with the truth.
  property bool busy: false
  property string lastError: ""
  property bool everLoaded: false

  // Raised once an on/off/sync has finished and fresh state has been read.
  // The panel uses it to push the new state to the bar copies on other
  // monitors, which would otherwise sit on stale state until their next poll.
  signal settled()

  readonly property var state: ({
    enabled: enabled, connected: connected, streaming: streaming,
    discoverable: discoverable, mprisProxy: mprisProxy, battery: battery,
    device: device, mac: mac, card: card, profile: profile, sink: sink,
    sinkDescription: sinkDescription,
    micActive: micActive, micSource: micSource,
    notificationsEnabled: notificationsEnabled, outputSink: outputSink
  })

  readonly property string statusText: Model.statusText(state)
  readonly property string detailText: Model.detailText(state)

  function refresh() {
    if (statusProc.running || helper === "") return
    statusProc.running = true
  }

  function run(action) {
    if (helper === "") return
    if (actionProc.running) return
    busy = true
    lastError = ""
    // Optimistic flip: the helper takes a moment to talk to BlueZ and
    // PipeWire, and a switch that lags behind the click feels broken.
    if (action === "on") enabled = true
    else if (action === "off") enabled = false
    else if (action === "toggle") enabled = !enabled
    actionProc.command = [helper, action]
    actionProc.running = true
  }

  function toggle() { run("toggle") }

  function applyStatus(raw) {
    var next = Model.parseStatus(raw)
    enabled = next.enabled
    connected = next.connected
    streaming = next.streaming
    discoverable = next.discoverable
    mprisProxy = next.mprisProxy
    battery = next.battery
    device = next.device
    mac = next.mac
    card = next.card
    profile = next.profile
    sink = next.sink
    sinkDescription = next.sinkDescription
    micActive = next.micActive
    micSource = next.micSource
    notificationsEnabled = next.notificationsEnabled
    outputSink = next.outputSink
    everLoaded = true

    // A phone that connects long after the switch was flipped, or
    // discoverability that lapsed, is reconciled here rather than by a
    // background daemon. `sync` is idempotent and cheap.
    if (!busy && Model.needsSync(next)) run("sync")
  }


  function refreshSinks() {
    if (sinksProc.running || helper === "") return
    sinksProc.running = true
  }

  function setOutput(name) {
    if (helper === "" || outputProc.running) return
    outputSink = name === "default" ? "" : name
    outputProc.command = [helper, "output", "set", name]
    outputProc.running = true
  }

  function setNotifications(on) {
    if (helper === "" || notifyProc.running) return
    notificationsEnabled = on
    notifyProc.command = [helper, "notifications", "set", on ? "on" : "off"]
    notifyProc.running = true
  }

  HelperProcess {
    id: sinksProc
    command: [root.helper, "sinks"]
    onCollected: function(text) {
      try { root.sinks = JSON.parse(text || "[]") || [] }
      catch (e) { root.sinks = [] }
    }
  }

  // One in flight at a time for each: a second click while the first is still
  // talking to PipeWire is dropped, and the refresh that follows shows what
  // actually landed.
  HelperProcess { id: outputProc; onExited: Qt.callLater(root.refresh) }
  HelperProcess { id: notifyProc; onExited: Qt.callLater(root.refresh) }

  HelperProcess {
    id: statusProc
    command: [root.helper, "status"]
    onCollected: function(text) { root.applyStatus(text) }
    onErrorTextChanged: if (errorText !== "") root.lastError = errorText
  }

  // on/off/sync touch BlueZ, PipeWire and three units in turn, each under the
  // helper's own per-command deadline, so this one is generous.
  HelperProcess {
    id: actionProc
    deadlineMs: 60000
    onErrorTextChanged: if (errorText !== "") root.lastError = errorText
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && root.lastError === "")
        root.lastError = "Speaker mode command failed"
      // Read the real state back rather than trusting the optimistic flip.
      Qt.callLater(function() { root.refresh(); root.settled() })
    }
  }


  // The capture-device list only changes when hardware comes and goes, so it
  // is read when the panel opens rather than on every poll.
  function refreshSources() {
    if (sourcesProc.running || helper === "") return
    sourcesProc.running = true
  }

  function setMic(name) {
    if (helper === "" || micProc.running) return
    micSource = name === "default" ? "" : name
    micProc.command = [helper, "mic", "set", name]
    micProc.running = true
  }

  HelperProcess {
    id: sourcesProc
    command: [root.helper, "sources"]
    onCollected: function(text) {
      try { root.sources = JSON.parse(text || "[]") || [] }
      catch (e) { root.sources = [] }
    }
  }

  HelperProcess {
    id: micProc
    onExited: Qt.callLater(root.refresh)
  }
  Timer {
    interval: (root.active ? root.refreshIntervalSec : root.refreshIntervalSec * 2) * 1000
    running: root.helper !== ""
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
}
