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
// A minted id is about 12 characters and an ISO timestamp 24.
var MAX_STORE_BYTES = 4 * 1024 * 1024
var MAX_NOTES = 5000
var MAX_NOTE_CHARS = 16384
var MAX_ID_CHARS = 128
var MAX_TIMESTAMP_CHARS = 64

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

// Checked on input rather than truncated, so a long paste stays in the box
// instead of being silently cut to fit.
function isTooLong(value) {
  return normalizeText(value).length > MAX_NOTE_CHARS
}

// Reads one stored note. A field over its cap is clipped or replaced so the
// note can still be shown, and `report.clipped` is raised so the caller knows
// the list it holds is not what is on disk and must not be written back.
function normalizeNote(entry, report) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) return null
  var text = normalizeText(entry.text)
  if (text.length === 0) return null
  if (text.length > MAX_NOTE_CHARS) {
    text = text.substring(0, MAX_NOTE_CHARS)
    flag(report)
  }
  var created = field(entry.created, MAX_TIMESTAMP_CHARS, report) || nowIso()
  return {
    id: field(entry.id, MAX_ID_CHARS, report) || mintId(),
    text: text,
    created: created,
    updated: field(entry.updated, MAX_TIMESTAMP_CHARS, report) || created
  }
}

function field(value, max, report) {
  if (typeof value !== "string" || value.length === 0) return ""
  if (value.length > max) {
    flag(report)
    return ""
  }
  return value
}

function flag(report) {
  if (report) report.clipped = true
}

// Reads the store without trusting it. Tolerates every shape this file has
// ever had: a bare array of notes, a bare array of strings, or the versioned
// object. `problem` is empty when the result is a faithful copy of the file,
// and otherwise says why it must not be written back over it:
//
//   oversize  bigger than MAX_STORE_BYTES, so never handed to the parser
//   corrupt   not valid JSON: a hand-edit typo, or a file caught half-written
//   foreign   valid JSON, but not a napkin store, e.g. a mistyped storePath
//   newer     written by a newer napkin whose format this one can't round-trip
//   clipped   read, but something was over a limit and was cut to fit
//
// None of these read as an empty store. Treating an unreadable file as "no
// notes" is how a single typo turns into the next save replacing everything.
// A genuinely empty file (or `{}`) is empty, though: napkin never writes one,
// so it can only mean someone cleared it on purpose.
function readStore(raw) {
  var text = String(raw || "")

  // Checked before JSON.parse rather than after: the point is to not hand a
  // multi-megabyte string to the parser in the shell's own event loop.
  if (text.length > MAX_STORE_BYTES) return result([], "oversize")

  var trimmed = text.replace(/^\s+|\s+$/g, "")
  if (trimmed.length === 0) return result([], "")

  var parsed
  try {
    parsed = JSON.parse(trimmed)
  } catch (e) {
    return result([], "corrupt")
  }

  var list = null
  if (Array.isArray(parsed)) {
    list = parsed
  } else if (parsed && typeof parsed === "object") {
    if (Array.isArray(parsed.notes)) {
      if (typeof parsed.version === "number" && parsed.version > STORE_VERSION)
        return result([], "newer")
      list = parsed.notes
    } else if (Object.keys(parsed).length === 0) {
      return result([], "")
    }
  }
  if (!list) return result([], "foreign")

  var report = { clipped: false }
  var out = []
  // Null-prototype, so an id like "__proto__" is just a key.
  var seen = Object.create(null)
  for (var i = 0; i < list.length; i++) {
    if (out.length >= MAX_NOTES) {
      report.clipped = true
      break
    }
    var entry = list[i]
    var note = null
    if (typeof entry === "string") {
      note = normalizeNote({ text: entry }, report)
    } else if (entry && typeof entry === "object" && !Array.isArray(entry)) {
      note = normalizeNote(entry, report)
    } else if (entry !== null && entry !== undefined) {
      // A number or a nested array is content we don't understand. Dropping
      // it on the next save would delete it, so it counts as clipped.
      report.clipped = true
    }
    if (!note) continue

    // A store merged from two copies (a dotfiles sync, say) can hold one id
    // twice. Rows are addressed by id, so the pair would open, edit, and
    // delete as one; the later copy gets a fresh id instead.
    while (note.id in seen) note.id = mintId()
    seen[note.id] = true
    out.push(note)
  }
  return result(out, report.clipped ? "clipped" : "")
}

function result(notes, problem) {
  return { notes: notes, problem: problem }
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
  if (isTooLong(text)) return notes
  var note = normalizeNote({ text: text }, null)
  if (!note) return notes
  // Ids minted this session never collide with each other, but a store read
  // from disk may already hold anything.
  while (indexOfId(notes, note.id) !== -1) note.id = mintId()
  return [note].concat(notes || [])
}

function updateNote(notes, id, text) {
  var i = indexOfId(notes, id)
  if (i === -1) return notes
  if (isTooLong(text)) return notes
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

// Puts a deleted note back where it was. If a note with the same id has come
// back in the meantime (an outside edit restored it), there is nothing to undo,
// and inserting it again would leave two rows sharing one id.
function restoreNote(notes, note, index) {
  if (!note || indexOfId(notes, note.id) !== -1) return notes
  var copy = (notes || []).slice()
  copy.splice(Math.max(0, Math.min(index, copy.length)), 0, note)
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

  // Filed in the first half hour of today and read in the last one: the hours
  // round up to 24, but it is still today, not "yesterday".
  if (then >= startOfToday.getTime()) return hours + "h ago"
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

// Counts code points, not UTF-16 units, so a cut that lands on an emoji drops
// the whole emoji instead of leaving half a surrogate pair on screen.
function truncate(text, limit) {
  var chars = Array.from(oneLine(text))
  var max = limit || 60
  return chars.length <= max ? chars.join("") : chars.slice(0, max - 1).join("") + "…"
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
