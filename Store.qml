import QtQuick
import Quickshell
import Quickshell.Io
import "Notes.js" as Notes

// Napkin's persistence: the notes file, the path checks in front of it, and the
// read limits, behind a small surface the panel talks to: `notes`, `commit()`,
// `canWrite`, `error`.
//
// Free of the shell's UI imports on purpose, so it can be loaded on its own with
// `qs -p` and exercised without a bar.
//
// A write goes: commit() -> 400ms debounce -> store-guard.sh re-checks the path
// -> FileView writes. The path is checked before every write, not once at
// startup, and FileView is handed the resolved folder the first check printed,
// which every later check is pinned to. When the watched file changes on disk,
// trust is dropped and nothing is re-read until the path has been checked again.
//
// What this does not do is close the gap between a check and the write after
// it. A process running as the same user can still swap something in during the
// milliseconds between store-guard.sh exiting and FileView opening the file.
// Closing that needs file descriptors, which QML does not have; this keeps the
// window to milliseconds rather than the whole session, and the next check
// catches the swap if it loses the race.
Item {
  id: store

  // Absolute and already expanded, or "" with `pathProblem` saying why.
  property string path: ""
  property string pathProblem: ""

  // Replaced wholesale, never mutated in place, so bindings on it re-evaluate.
  readonly property var notes: _notes

  // True once the file has been read, or found not to exist yet. Nothing is
  // written before then: a write that beats the first read would replace a
  // file nobody has looked at.
  readonly property bool loaded: _loaded

  // Whether notes may change at all. The panel checks this before filing a
  // note and keeps the draft when it is false, rather than showing a note that
  // will never reach disk.
  readonly property bool canWrite: path !== "" && pathProblem === "" && _pathError === ""
    && _readError === "" && _acceptedPath !== "" && _loaded

  readonly property string error: pathProblem || _pathError || _readError || _saveError

  // `notes` was replaced from disk rather than by commit(): an outside edit, or
  // a different file after `path` changed.
  signal externalChange()

  function commit(next) {
    if (!canWrite) return false
    if (next === _notes) return true
    _notes = next
    saveTimer.restart()
    return true
  }

  // The panel closed: skip the rest of the debounce. Also retries a save that
  // failed earlier.
  function flush() {
    if (!saveTimer.running && !_writeQueued) return
    saveTimer.stop()
    _requestWrite()
  }

  // Check the path again and re-read the file, so a problem that appeared since
  // the last write shows when the panel opens instead of when the next note
  // won't save. This is also how a fixed problem clears, how a failed save gets
  // retried, and how the list catches up after a swap detached the watcher
  // (a replaced file isn't always reported). Re-reading an unchanged file costs
  // one string compare.
  function recheck() {
    if (path === "" || pathProblem !== "") return
    _reloadQueued = true
    _validate()
  }

  // The shell is going away and there is no waiting on store-guard.sh, so the
  // pending change is written only if the last check passed and nothing has
  // changed on disk since.
  function flushOnExit() {
    if (!_writePendingNow())
      console.warn("napkin: skipped the last save on exit, the notes path had not been re-checked")
  }

  // ------------------------------------------------------------------ state
  property var _notes: []
  property bool _ready: false
  property bool _loaded: false
  property bool _hadFile: false
  property string _pathError: ""
  property string _readError: ""
  property string _saveError: ""
  property string _acceptedPath: ""
  property string _pinned: ""
  property bool _trusted: false
  property bool _writeQueued: false
  property bool _reloadQueued: false
  property bool _rerun: false
  property string _checking: ""

  // The exact bytes of our last write, so the watcher's echo of it can be told
  // apart from an outside edit without re-parsing, and a change committed while
  // that echo was on its way isn't mistaken for one and dropped.
  property string _lastWritten: ""

  readonly property string _guardPath:
    decodeURIComponent(String(Qt.resolvedUrl("store-guard.sh")).replace(/^file:\/\//, ""))

  Component.onCompleted: {
    _ready = true
    _reset()
  }
  Component.onDestruction: flushOnExit()
  onPathChanged: if (_ready) _reset()
  onPathProblemChanged: if (_ready) _reset()

  function _reset() {
    // An unsaved edit belongs to the file it was made against, so it goes there
    // before the path moves, if that is still safe.
    _writePendingNow()

    _pinned = ""
    _acceptedPath = ""
    _loaded = false
    _hadFile = false
    _trusted = false
    _pathError = ""
    _readError = ""
    _saveError = ""
    _writeQueued = false
    _reloadQueued = false
    _lastWritten = ""
    if (_notes.length > 0) _replace([])
    _validate()
  }

  function _validate() {
    if (path === "" || pathProblem !== "") return
    if (guard.running) {
      _rerun = true
      return
    }
    _checking = path
    guard.command = ["/usr/bin/bash", _guardPath, path, _pinned]
    guard.running = true
  }

  function _checked(code, out) {
    // Something changed while that check ran, or the path moved on: its answer
    // is about a state that no longer exists.
    if (_rerun || _checking !== path) {
      _rerun = false
      _validate()
      return
    }

    if (code !== 0) {
      _trusted = false
      _pathError = _guardMessage(code)
      console.warn("napkin: not using " + path + ": " + _pathError + " (" + code + ")")
      return
    }

    _pathError = ""
    if (_pinned === "") _pinned = out
    var file = (out === "/" ? "" : out) + "/" + path.substring(path.lastIndexOf("/") + 1)
    _trusted = true

    if (_acceptedPath !== file) {
      // First check for this path. Handing FileView the path starts the read.
      _acceptedPath = file
      return
    }
    if (_reloadQueued) {
      _reloadQueued = false
      storeFile.reload()
      return
    }
    if (_writeQueued && _loaded && _readError === "") _performWrite()
  }

  function _requestWrite() {
    if (!canWrite) return
    _writeQueued = true
    _validate()
  }

  function _performWrite() {
    _writeQueued = false
    var text = Notes.serializeStore(_notes)
    _lastWritten = text
    storeFile.setText(text)
  }

  function _writePendingNow() {
    if (!saveTimer.running && !_writeQueued) return true
    saveTimer.stop()
    if (!_trusted || !_loaded || _acceptedPath === "" || _readError !== "") return false
    _performWrite()
    storeFile.waitForJob()
    return true
  }

  function _replace(list) {
    _notes = list
    externalChange()
  }

  function _read(raw) {
    if (_acceptedPath === "") return
    _loaded = true
    _hadFile = true

    if (raw === _lastWritten && _readError === "") {
      if (_writeQueued && _trusted) _performWrite()
      return
    }

    var result = Notes.readStore(raw)
    if (result.problem !== "") {
      _readError = _readMessage(result.problem)
      _writeQueued = false
      saveTimer.stop()
      // A clipped read is still the file's own content, so it is shown. For
      // anything unreadable the list keeps what it last showed, rather than
      // going blank over a typo.
      if (result.problem === "clipped") _replace(result.notes)
      return
    }

    _readError = ""
    if (Notes.serializeStore(result.notes) !== Notes.serializeStore(_notes)) {
      // An outside edit beats an unsaved one, as it always has: the window is
      // the 400ms debounce, and a per-note merge isn't worth guessing at.
      _writeQueued = false
      saveTimer.stop()
      _replace(result.notes)
    } else if (_writeQueued && _trusted) {
      _performWrite()
    }
  }

  function _readFailed(error) {
    if (_acceptedPath === "") return
    _loaded = true
    if (error === FileViewError.FileNotFound) {
      // First run, or deleted from outside. Deleting the file is a way to clear
      // your notes, so that is what it does.
      _readError = ""
      if (_hadFile) {
        _hadFile = false
        _writeQueued = false
        saveTimer.stop()
        _lastWritten = ""
        if (_notes.length > 0) _replace([])
      }
      return
    }
    _readError = "can't read the notes file"
    _writeQueued = false
    saveTimer.stop()
  }

  function _changedOnDisk() {
    if (_acceptedPath === "") return
    _trusted = false
    _reloadQueued = true
    _validate()
  }

  function _guardMessage(code) {
    switch (code) {
    case 2: return "can't create the notes folder"
    case 4: return "the notes path changed while being checked"
    case 5: return "the notes folder belongs to another user"
    case 6: return "a folder in the notes path is writable by other users"
    case 7: return "the notes file is a symlink"
    case 8: return "the notes path isn't a regular file"
    case 9: return "the notes file belongs to another user"
    case 10: return "the notes path must be absolute"
    case 11: return "the notes folder moved since napkin started"
    case 12: return "the notes file is writable by other users"
    case 13: return "a folder in the notes path belongs to another user"
    case 14: return "can't inspect the notes path"
    default: return "can't use the notes path"
    }
  }

  function _readMessage(problem) {
    switch (problem) {
    case "oversize": return "the notes file is too large to open"
    case "corrupt": return "the notes file isn't valid JSON"
    case "foreign": return "the notes path isn't a napkin notes file"
    case "newer": return "the notes file is from a newer napkin"
    case "clipped": return "the notes file is over napkin's limits"
    default: return "can't read the notes file"
    }
  }

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: store._requestWrite()
  }

  Process {
    id: guard
    running: false
    stdout: StdioCollector {
      id: guardOut
      waitForEnd: true
    }
    onExited: function(code) { store._checked(code, guardOut.text) }
  }

  FileView {
    id: storeFile

    path: store._acceptedPath
    watchChanges: true
    atomicWrites: true
    printErrors: false

    onLoaded: store._read(text())
    onLoadFailed: function(error) { store._readFailed(error) }
    onFileChanged: store._changedOnDisk()
    onSaved: store._saveError = ""
    onSaveFailed: function(error) {
      store._saveError = "couldn't save notes"
      store._lastWritten = ""
      store._writeQueued = true
      console.warn("napkin: saving " + store._acceptedPath + " failed (" + error + ")")
    }
  }
}
