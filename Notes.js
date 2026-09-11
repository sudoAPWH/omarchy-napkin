.pragma library

// Store shaping and formatting for the napkin panel. Pure functions, kept out
// of the QML so the view stays declarative and the persistence rules — id
// minting, ordering, the on-disk shape — live in one readable place.

var STORE_VERSION = 1

// Bounds on what the panel will take from disk. The store is a plain file the
// user can edit, sync, or point somewhere unexpected, so none of these are
// trusted to be sane. They are deliberately far above any hand-written store:
// hitting one means the file is machine-generated, corrupt, or not ours, and
// the panel refuses to write rather than quietly truncating someone's notes.
var MAX_STORE_BYTES = 4 * 1024 * 1024
var MAX_NOTES = 5000
var MAX_NOTE_CHARS = 16384

// Monotonic within a session and prefixed with the mint time, so ids stay
// unique across two notes filed in the same millisecond without pulling in a
// uuid dependency for what is a local-only key.
var _seq = 0

function mintId() {
  _seq += 1
  return Date.now().toString(36) + "-" + _seq.toString(36)
}

function nowIso() {
  return new Date().toISOString()
}

// Notes are trimmed of surrounding whitespace but keep their interior
// newlines — a jotted list is still one note.
function normalizeText(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/^\s+|\s+$/g, "")
}

function isBlank(value) {
  return normalizeText(value).length === 0
}

function normalizeNote(entry) {
  if (!entry || typeof entry !== "object") return null
  var text = normalizeText(entry.text)
  if (text.length === 0) return null
  if (text.length > MAX_NOTE_CHARS) text = text.substring(0, MAX_NOTE_CHARS)
  var created = typeof entry.created === "string" && entry.created ? entry.created : nowIso()
  return {
    id: typeof entry.id === "string" && entry.id ? entry.id : mintId(),
    text: text,
    created: created,
    updated: typeof entry.updated === "string" && entry.updated ? entry.updated : created
  }
}

// Tolerates every shape this file has ever had, plus the shapes a hand-edit
// might leave behind: a bare array of notes, a bare array of strings, or the
// versioned object. Anything unparseable reads as empty rather than throwing —
// a corrupt store should cost you your notes' display, not the whole shell.
function readStore(raw) {
  var text = String(raw || "")

  // Checked before JSON.parse rather than after: the point is to not hand a
  // multi-megabyte string to the parser in the shell's own event loop.
  if (text.length > MAX_STORE_BYTES) {
    return { notes: [], oversize: true, truncated: false }
  }

  var parsed
  try {
    parsed = JSON.parse(text.replace(/^\s+|\s+$/g, "") || "{}")
  } catch (e) {
    return { notes: [], oversize: false, truncated: false }
  }

  var list = null
  if (Array.isArray(parsed)) list = parsed
  else if (parsed && Array.isArray(parsed.notes)) list = parsed.notes
  if (!list) return { notes: [], oversize: false, truncated: false }

  var out = []
  var truncated = false
  for (var i = 0; i < list.length; i++) {
    if (out.length >= MAX_NOTES) { truncated = true; break }
    var raw_entry = list[i]
    var note = normalizeNote(typeof raw_entry === "string" ? { text: raw_entry } : raw_entry)
    if (note) out.push(note)
  }
  return { notes: out, oversize: false, truncated: truncated }
}

function parseStore(raw) {
  return readStore(raw).notes
}

function serializeStore(notes) {
  return JSON.stringify({ version: STORE_VERSION, notes: notes || [] }, null, 2) + "\n"
}

function indexOfId(notes, id) {
  for (var i = 0; i < (notes || []).length; i++) {
    if (notes[i].id === id) return i
  }
  return -1
}

function findById(notes, id) {
  var i = indexOfId(notes, id)
  return i === -1 ? null : notes[i]
}

// Every mutation returns a new array. QML only re-evaluates a `var` property
// binding when the reference changes, so in-place splicing would leave the
// list view showing stale rows.
function addNote(notes, text) {
  var note = normalizeNote({ text: text })
  if (!note) return notes
  return [note].concat(notes || [])
}

function updateNote(notes, id, text) {
  var i = indexOfId(notes, id)
  if (i === -1) return notes
  var next = normalizeText(text)
  if (next.length === 0) return removeNote(notes, id)
  if (next === notes[i].text) return notes

  var copy = (notes || []).slice()
  copy[i] = {
    id: notes[i].id,
    text: next,
    created: notes[i].created,
    updated: nowIso()
  }
  return copy
}

function removeNote(notes, id) {
  var i = indexOfId(notes, id)
  if (i === -1) return notes
  var copy = (notes || []).slice()
  copy.splice(i, 1)
  return copy
}

// Notes are stored newest-first; oldest-first is a display flip, not a
// different store, so the file stays stable when the setting changes.
function ordered(notes, newestFirst) {
  var list = (notes || []).slice()
  return newestFirst === false ? list.reverse() : list
}

// --------------------------------------------------------------- formatting

// Deliberately coarse. The exact minute a thought was filed is noise; "2m",
// "yesterday" and "Mar 4" are the three resolutions that actually tell you
// whether a note is still live.
function relativeTime(iso, now) {
  var then = Date.parse(iso)
  if (!isFinite(then)) return ""

  var reference = now === undefined ? Date.now() : now
  var seconds = Math.floor((reference - then) / 1000)

  if (seconds < 45) return "just now"
  if (seconds < 90) return "1m ago"

  var minutes = Math.round(seconds / 60)
  if (minutes < 60) return minutes + "m ago"

  var hours = Math.round(minutes / 60)
  if (hours < 24) return hours + "h ago"

  var startOfToday = new Date(reference)
  startOfToday.setHours(0, 0, 0, 0)
  var days = Math.floor((startOfToday.getTime() - then) / 86400000) + 1

  if (days <= 1) return "yesterday"
  if (days < 7) return days + " days ago"

  var date = new Date(then)
  var month = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
               "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][date.getMonth()]
  var stamp = month + " " + date.getDate()
  return date.getFullYear() === new Date(reference).getFullYear()
    ? stamp
    : stamp + ", " + date.getFullYear()
}

// One line for the bar tooltip and for the collapsed row: interior newlines
// become a separator so a multi-line note still reads as a single entry.
function oneLine(text) {
  return normalizeText(text).replace(/\s*\n+\s*/g, " · ")
}

function truncate(text, limit) {
  var s = oneLine(text)
  var max = limit || 60
  return s.length <= max ? s : s.substring(0, max - 1) + "…"
}

function tooltip(notes, limit) {
  var list = notes || []
  if (list.length === 0) return "Napkin — nothing jotted"

  var max = limit || 5
  var lines = [list.length === 1 ? "1 note" : list.length + " notes"]
  for (var i = 0; i < Math.min(max, list.length); i++) {
    lines.push("· " + truncate(list[i].text, 44))
  }
  if (list.length > max) lines.push("… and " + (list.length - max) + " more")
  return lines.join("\n")
}
