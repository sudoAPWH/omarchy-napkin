import QtQuick
import Quickshell
import Quickshell.Io
import "Notes.js" as Notes

// Napkin's persistence: the notes file, the checks in front of it, and the read
// limits, behind a small surface the panel talks to: `notes`, `commit()`,
// `canWrite`, `error`.
//
// Free of the shell's UI imports on purpose, so it can be loaded on its own with
// `qs -p` and exercised without a bar.
//
// Nothing here opens the store. Both directions go through store-helper.py,
// which walks the folders with O_NOFOLLOW, checks each open descriptor, and
// reads and replaces the file through those descriptors. QML only ever holds
// the pathname as text to hand over, so a folder or file swapped after the
// checks cannot redirect a write: the helper is already holding what it
// verified.
//
// Writes are not debounced. Every change here is a whole action (a note filed,
// an edit committed, a delete, an undo), not a keystroke, so each one is written
// as it happens and there is no window where a change exists only in memory.
//
// Outside edits are noticed by an inotifywait on the containing folder, the same
// way the shell watches its own plugin folder. It only reports that the name
// changed; the file is still read through the helper, so nothing here opens the
// store to find out what happened.
Item {
  id: store

  // Absolute and already expanded, or "" with `pathProblem` saying why.
  property string path: ""
  property string pathProblem: ""

  // Replaced wholesale, never mutated in place, so bindings on it re-evaluate.
  readonly property var notes: _notes

  // True once the file has been read, or found not to exist yet. Nothing is
  // written before then: a write that beat the first read would replace a file
  // nobody has looked at.
  readonly property bool loaded: _loaded

  // Whether notes may change at all. The panel checks this before filing a
  // note and keeps the draft when it is false, rather than showing a note that
  // will never reach disk.
  readonly property bool canWrite: path !== "" && pathProblem === "" && _pathError === ""
    && _readError === "" && _loaded

  readonly property string error: pathProblem || _pathError || _readError || _saveError

  // `notes` was replaced from disk rather than by commit(): an outside edit, or
  // a different file after `path` changed.
  signal externalChange()

  function commit(next) {
    if (!canWrite) return false
    if (next === _notes) return true
    _notes = next
    _dirty = true
    _write()
    return true
  }

  // The panel closed. Nothing is normally pending, since writes are immediate;
  // this retries one that failed.
  function flush() {
    if (_dirty) _write()
  }

  // Re-read on open, so an outside edit shows up and a problem that has been
  // fixed clears. Unsaved work goes out first: reading would replace it with
  // what is still on disk.
  function recheck() {
    if (path === "" || pathProblem !== "") return
    // Unsaved work goes out first, since reading would replace it with what is
    // still on disk. If the path itself is the problem, re-read to find out
    // whether it has been fixed.
    if (_dirty && _pathError === "" && _readError === "") _write()
    else _read()
  }

  // The shell is going away. A write started here may not outlive it, so this
  // is best effort and says so when it can't be sure.
  function flushOnExit() {
    if (!_dirty) return
    _write()
    console.warn("napkin: the last change was still being written as the shell exited")
  }

  // ------------------------------------------------------------------ state
  property var _notes: []
  property bool _ready: false
  property bool _loaded: false
  property bool _dirty: false
  property bool _pending: false
  property bool _rereadPending: false
  property string _pathError: ""
  property string _readError: ""
  property string _saveError: ""
  property string _payload: ""

  readonly property string _folder: path.indexOf("/") === -1 ? "" : path.substring(0, path.lastIndexOf("/"))
  readonly property string _name: path.substring(path.lastIndexOf("/") + 1)
  readonly property bool _watchable: path !== "" && pathProblem === "" && _folder !== ""

  readonly property string _helper:
    decodeURIComponent(String(Qt.resolvedUrl("store-helper.py")).replace(/^file:\/\//, ""))

  Component.onCompleted: {
    _ready = true
    _reset()
  }
  Component.onDestruction: flushOnExit()
  onPathChanged: if (_ready) _reset()
  onPathProblemChanged: if (_ready) _reset()

  function _reset() {
    _loaded = false
    _dirty = false
    _pending = false
    _rereadPending = false
    _pathError = ""
    _readError = ""
    _saveError = ""
    if (_notes.length > 0) _replace([])
    _read()
  }

  function _replace(list) {
    _notes = list
    externalChange()
  }

  // ------------------------------------------------------------------- read
  function _read() {
    if (path === "" || pathProblem !== "") return
    if (reader.running) {
      _rereadPending = true
      return
    }
    reader.command = ["/usr/bin/python3", "-I", "-S", _helper, "read", path]
    reader.running = true
  }

  function _readDone(code, text) {
    _loaded = true
    if (code === 0 || code === 15) {
      // 15 is no file or no folder yet: an empty store, not a problem.
      _pathError = ""
      // A change held back by an earlier failure is written rather than
      // dropped for what is on disk.
      if (_dirty) _write()
      else _apply(code === 0 ? text : "")
    } else {
      _pathError = _helperMessage(code)
      console.warn("napkin: not using " + path + ": " + _pathError + " (" + code + ")")
    }

    if (_rereadPending) {
      _rereadPending = false
      _read()
    }
  }

  function _apply(raw) {
    var result = Notes.readStore(raw)
    if (result.problem !== "") {
      _readError = _readMessage(result.problem)
      // A clipped read is still the file's own content, so it is shown. For
      // anything unreadable the list keeps what it last showed, rather than
      // going blank over a typo.
      if (result.problem === "clipped") _replace(result.notes)
      return
    }

    _readError = ""
    _dirty = false
    if (Notes.serializeStore(result.notes) !== Notes.serializeStore(_notes))
      _replace(result.notes)
  }

  // ------------------------------------------------------------------ write
  function _write() {
    if (!canWrite) return
    if (writer.running) {
      _pending = true
      return
    }
    _payload = Notes.serializeStore(_notes)
    writer.command = ["/usr/bin/python3", "-I", "-S", _helper, "write", path]
    writer.running = true
  }

  function _writeDone(code) {
    if (code === 0) {
      _saveError = ""
      _dirty = _pending
    } else if (code === 14 || code === 2) {
      // Couldn't write it this time: worth retrying on the next change.
      _saveError = "couldn't save notes"
      console.warn("napkin: saving " + path + " failed (" + code + ")")
    } else {
      // The path itself is wrong, so editing stops until it is fixed rather
      // than piling up changes that will fail the same way.
      _pathError = _helperMessage(code)
      console.warn("napkin: not using " + path + ": " + _pathError + " (" + code + ")")
    }

    if (_pending) {
      _pending = false
      _write()
    }
  }

  function _helperMessage(code) {
    switch (code) {
    case 2: return "can't create the notes folder"
    case 3: return "a folder in the notes path is a symlink"
    case 4: return "a folder in the notes path isn't a folder"
    case 5: return "the notes folder belongs to another user"
    case 6: return "a folder in the notes path is writable by other users"
    case 7: return "the notes file is a symlink"
    case 8: return "the notes path isn't a regular file"
    case 9: return "the notes file belongs to another user"
    case 10: return "the notes path must be absolute"
    case 11: return "the notes file is writable by other users"
    case 12: return "the notes file is too large to open"
    case 13: return "a folder in the notes path belongs to another user"
    case 14: return "can't read or write the notes file"
    case 15: return "the notes file is missing"
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

  // Reports that something happened to the name, never what is in it. A write
  // of our own comes back through here too; the re-read then matches what is
  // already in memory and changes nothing.
  Process {
    id: watcher
    running: store._watchable
    command: [
      "/usr/bin/inotifywait", "-m", "-q",
      "-e", "close_write,moved_to,move_self,delete,delete_self,create",
      "--format", "%f",
      store._folder
    ]
    stdout: SplitParser {
      onRead: function(line) {
        if (String(line).trim() === store._name) settle.restart()
      }
    }
    // The folder may not exist yet, in which case inotifywait exits at once.
    onExited: if (store._watchable) watcherRestart.restart()
  }

  Timer {
    id: watcherRestart
    interval: 2000
    onTriggered: if (store._watchable && !watcher.running) watcher.running = true
  }

  // Coalesces a burst of events, and lets a replace finish before reading.
  Timer {
    id: settle
    interval: 150
    onTriggered: store._read()
  }

  Process {
    id: reader
    running: false
    stdout: StdioCollector {
      id: readerOut
      waitForEnd: true
    }
    onExited: function(code) { store._readDone(code, readerOut.text) }
  }

  Process {
    id: writer
    running: false
    stdinEnabled: true
    onStarted: {
      write(store._payload)
      stdinEnabled = false
    }
    onExited: function(code) {
      stdinEnabled = true
      store._writeDone(code)
    }
  }
}
