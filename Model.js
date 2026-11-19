.pragma library

// Pure helpers for the RDP panel: profile shape, validation, ordering.
// Kept free of QML so they can be unit-tested with plain node.

var SCALES = ["auto", "100", "125", "150", "175", "200"]

var MAX_FIELD = 256
var MAX_CONNECTIONS = 200

function newId() {
  var chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  var id = "c"
  for (var i = 0; i < 12; i++) id += chars.charAt(Math.floor(Math.random() * chars.length))
  return id
}

function blank() {
  return {
    id: "",
    name: "",
    host: "",
    port: 3389,
    username: "",
    domain: "",
    savePassword: true,
    fullscreen: false,
    clipboard: true,
    sound: true,
    homeDrive: false,
    ignoreCert: false,
    unicodeKeyboard: true,
    scale: "auto"
  }
}

function clean(value) {
  // No line breaks or control characters: every field ends up as one line
  // of the FreeRDP argument list.
  return String(value === undefined || value === null ? "" : value)
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim()
    .slice(0, MAX_FIELD)
}

function validId(id) {
  return /^[A-Za-z0-9_-]{1,64}$/.test(String(id || ""))
}

function normalize(raw) {
  if (!raw || typeof raw !== "object") return null
  var c = blank()
  c.id = validId(raw.id) ? String(raw.id) : ""
  if (c.id === "") return null
  c.name = clean(raw.name)
  c.host = clean(raw.host)
  var port = parseInt(raw.port, 10)
  c.port = port > 0 && port < 65536 ? port : 3389
  c.username = clean(raw.username)
  c.domain = clean(raw.domain)
  c.savePassword = raw.savePassword !== false
  c.fullscreen = raw.fullscreen === true
  c.clipboard = raw.clipboard !== false
  c.sound = raw.sound !== false
  c.homeDrive = raw.homeDrive === true
  c.ignoreCert = raw.ignoreCert === true
  c.unicodeKeyboard = raw.unicodeKeyboard !== false
  c.scale = SCALES.indexOf(String(raw.scale)) >= 0 ? String(raw.scale) : "auto"
  c.lastUsed = typeof raw.lastUsed === "number" && isFinite(raw.lastUsed) ? raw.lastUsed : 0
  return c
}

function parse(text) {
  var list = []
  try {
    var data = JSON.parse(text || "[]")
    if (!Array.isArray(data)) return []
    for (var i = 0; i < data.length && list.length < MAX_CONNECTIONS; i++) {
      var c = normalize(data[i])
      if (c) list.push(c)
    }
  } catch (e) {
    return []
  }
  return list
}

// Most recently used first, then by name.
function sorted(list) {
  return list.slice().sort(function(a, b) {
    if ((b.lastUsed || 0) !== (a.lastUsed || 0)) return (b.lastUsed || 0) - (a.lastUsed || 0)
    return displayName(a).localeCompare(displayName(b))
  })
}

function displayName(c) {
  return c.name || c.host || "—"
}

function subtitle(c) {
  var user = c.username ? (c.domain ? c.domain + "\\" + c.username : c.username) : ""
  var host = c.host + (c.port && c.port !== 3389 ? ":" + c.port : "")
  return user ? user + " @ " + host : host
}

function upsert(list, c) {
  var out = []
  var replaced = false
  for (var i = 0; i < list.length; i++) {
    if (list[i].id === c.id) { out.push(c); replaced = true }
    else out.push(list[i])
  }
  if (!replaced) out.push(c)
  return out
}

function remove(list, id) {
  return list.filter(function(c) { return c.id !== id })
}

function touch(list, id, now) {
  return list.map(function(c) {
    if (c.id !== id) return c
    var copy = {}
    for (var k in c) copy[k] = c[k]
    copy.lastUsed = now
    return copy
  })
}

function nextScale(scale) {
  var i = SCALES.indexOf(String(scale))
  return SCALES[(i + 1) % SCALES.length]
}

function serialize(list) {
  return JSON.stringify(list, null, 2) + "\n"
}
