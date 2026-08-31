.pragma library

// Pure helpers for the Speaker Mode widget. Kept out of the QML so the state
// machine that decides what the panel says is testable by reading it.

// The single sentence under the "Speaker Mode" title. It has to answer the
// only question the panel exists to answer: is sound going to come out?
function statusText(state) {
  if (!state.enabled) return "Off"
  if (state.streaming) return "Playing from " + (state.device || "phone")
  if (state.connected) return (state.device || "Phone") + " connected"
  return "Waiting for a phone"
}

// Longer line under the status, only when it adds something the status did
// not already say.
function detailText(state) {
  if (!state.enabled) return "Phone audio is blocked"
  if (state.streaming || state.connected) return "Output: " + sinkLabel(state.sink, state.sinkDescription)
  if (state.discoverable) return "Discoverable as this machine's name"
  return ""
}

// PipeWire sink names are long and mechanical. PulseAudio already carries a
// human description for every sink; fall back to tidying the name only when
// that is missing.
function sinkLabel(sink, description) {
  if (description) return String(description)
  if (!sink) return "default output"
  var name = String(sink)
  name = name.replace(/^alsa_output\./, "").replace(/^bluez_output\./, "")
  name = name.replace(/^pci-[0-9a-f_]+\./i, "").replace(/^usb-/, "")
  name = name.replace(/[._-]+/g, " ").trim()
  return name || String(sink)
}

function batteryText(percent) {
  return percent >= 0 ? percent + "%" : ""
}

// The phone's charge, which BlueZ reports over the Battery Service. In the
// header it sits on its own with nothing naming it, so it carries a battery
// glyph filled to match — a bare "100%" in a panel about audio reads as
// anything but a battery.
var BATTERY_GLYPHS = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]

function batteryGlyph(percent) {
  if (percent < 0) return ""
  var step = Math.round(percent / 10)
  return BATTERY_GLYPHS[Math.max(0, Math.min(BATTERY_GLYPHS.length - 1, step))]
}

function batteryLabel(percent) {
  if (percent < 0) return ""
  return batteryGlyph(percent) + " " + percent + "%"
}

// Collapse a name to comparable letters. mpris-proxy builds its bus name from
// the device alias with every non-ASCII character replaced by underscores, so
// "Tomás's iPhone" arrives as "Tom__s___s_iPhone" — only the letters survive
// intact, and those are what we match on.
function normalizeName(value) {
  return String(value || "").toLowerCase().replace(/[^a-z0-9]+/g, "")
}

// mpris-proxy publishes one player per connected Bluetooth device. Identify it
// by MAC when the bus name carries one, and otherwise by the device alias,
// which is what BlueZ actually names it after.
function isBluetoothPlayer(player, mac, device) {
  if (!player) return false
  var dbusName = String(player.dbusName || "").toLowerCase()
  if (dbusName.indexOf("playerctld") !== -1) return false
  if (mac && dbusName.indexOf(String(mac).toLowerCase().replace(/:/g, "_")) !== -1) return true
  if (dbusName.indexOf("bluez") !== -1 || dbusName.indexOf("mpris_proxy") !== -1) return true
  var alias = normalizeName(device)
  if (alias.length >= 3) {
    if (normalizeName(dbusName).indexOf(alias) !== -1) return true
    if (normalizeName(player.identity).indexOf(alias) !== -1) return true
  }
  return false
}

function pickBluetoothPlayer(players, mac, device) {
  if (!players) return null
  for (var i = 0; i < players.length; i++) {
    if (isBluetoothPlayer(players[i], mac, device)) return players[i]
  }
  return null
}


// Spotify on iOS appends a context annotation to the artist it sends over
// AVRCP: "Florence + The Machine • Video Available". That is presentation, not
// the artist's name, and it is only noise in the panel — the same suffix is
// already stripped when naming saved covers and keying the art cache.
function cleanArtist(value) {
  var name = String(value || "")
  var cut = name.indexOf("•")
  if (cut !== -1) name = name.slice(0, cut)
  return name.replace(/\s+$/, "")
}
function trackLine(player) {
  if (!player) return ""
  var title = String(player.trackTitle || "")
  var artist = String(player.trackArtist || "")
  if (title && artist) return title + " — " + artist
  return title || artist
}

// Parse the helper's status JSON into a plain object, with every field
// defaulted. A partial or failed read must never leave the panel showing a
// half-updated state.
function parseStatus(raw) {
  var data = {}
  try { data = JSON.parse(String(raw || "{}")) || {} } catch (e) { data = {} }
  return {
    enabled: data.enabled === true,
    connected: data.connected === true,
    streaming: data.streaming === true,
    discoverable: data.discoverable === true,
    mprisProxy: data.mprisProxy === true,
    battery: typeof data.battery === "number" ? data.battery : -1,
    device: String(data.device || ""),
    mac: String(data.mac || ""),
    card: String(data.card || ""),
    profile: String(data.profile || ""),
    sink: String(data.sink || ""),
    sinkDescription: String(data.sinkDescription || ""),
    micActive: data.micActive === true,
    micSource: String(data.micSource || ""),
    notificationsEnabled: data.notificationsEnabled === true,
    outputSink: String(data.outputSink || "")
  }
}

// True when the world has drifted from what the switch says it should look
// like — a phone that connected after the switch was flipped, or
// discoverability that lapsed. The service reacts by running the helper's
// `sync`.
//
// "Off" needs watching as much as "on" does: the phone can re-establish its
// audio profile at any time and BlueZ will accept it, so a card that has come
// back to life while the switch is off is drift too.
function needsSync(state) {
  if (!state.enabled) return state.card !== "" && state.profile !== "off"
  if (!state.discoverable) return true
  if (!state.mprisProxy) return true
  if (state.card !== "" && state.profile !== "audio-gateway") return true
  return false
}
