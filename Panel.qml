import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Notes.js" as Notes

// Napkin — quick notes from the bar.
//
// The whole point is the gap between having a thought and losing it, so the
// panel opens with the cursor already in the input and Enter files the note.
// There is no save button and no confirmation step anywhere: writes are
// debounced to disk on every mutation, and a delete is undoable for a few
// seconds rather than guarded by a dialog.
//
// Notes live in one JSON file under XDG_DATA_HOME — not the state dir the
// clipboard history uses, because these are documents the user wrote and
// expects to survive a cache wipe, not derived state the shell can rebuild.
//
// Note the `napkin/` namespace rather than `omarchy/napkin/`: on an installed
// Omarchy system `~/.local/share/omarchy` is a symlink to the root-owned
// package tree at /usr/share/omarchy, so the obvious-looking path is not
// writable and, worse, would be aimed at files the package manager overwrites.
Panel {
  id: root

  moduleName: "omarchy-napkin"
  ipcTarget: "omarchy-napkin"

  // ------------------------------------------------------------- settings
  readonly property string dataHome:
    Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")
  readonly property string defaultStorePath: dataHome + "/napkin/notes.json"
  readonly property string storePath: {
    var configured = String(setting("storePath", "")).replace(/^\s+|\s+$/g, "")
    if (configured.length === 0) return defaultStorePath
    return configured.charAt(0) === "~"
      ? Quickshell.env("HOME") + configured.substring(1)
      : configured
  }
  readonly property string storeDir: storePath.replace(/\/[^\/]*$/, "")

  readonly property int composeMaxLines: Math.max(1, Math.min(20, Number(setting("composeMaxLines", 8)) || 8))
  readonly property int previewLines: Math.max(1, Math.min(12, Number(setting("previewLines", 3)) || 3))
  readonly property bool showCount: setting("showCount", true) !== false
  readonly property bool newestFirst: setting("newestFirst", true) !== false

  // ---------------------------------------------------------------- state
  property var notes: []
  property bool storeReady: false

  // Set when the store directory cannot be created. A notes app that silently
  // fails to save is worse than one that refuses to open, so this is surfaced
  // in the header rather than logged and forgotten.
  property string storeError: ""

  // The note whose action menu is open, and the note being edited. Only one of
  // the two is ever set — opening the editor closes the menu that launched it.
  property string menuNoteId: ""
  property string editingNoteId: ""
  property int menuIndex: 0
  property real menuX: 0
  property real menuRowTop: 0
  property real menuRowHeight: 0

  // -1 means "no list cursor" — the input has the keyboard and the list is
  // mouse-driven, which is the state the panel spends most of its life in.
  property int cursorIndex: -1

  // Deletion is immediate and reversible rather than confirmed up front: a
  // dialog on every delete is a tax on the common case to protect the rare one.
  property var pendingUndo: null

  readonly property var visibleNotes: Notes.ordered(notes, newestFirst)
  readonly property int noteCount: notes.length
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string face: bar ? bar.fontFamily : Style.font.family

  function dim(alpha) {
    return Qt.rgba(fg.r, fg.g, fg.b, alpha)
  }

  // ------------------------------------------------------------ persistence
  //
  // Debounced rather than written on every keystroke: filing a note is one
  // write, but editing one in place would otherwise be a write per character.
  function scheduleSave() {
    saveTimer.restart()
  }

  function flushSave() {
    if (!saveTimer.running) return
    saveTimer.stop()
    writeStore()
  }

  function writeStore() {
    if (!storeReady) return
    storeFile.setText(Notes.serializeStore(notes))
  }

  function applyStore(raw) {
    var parsed = Notes.parseStore(raw)

    // Our own write comes back through the file watcher. Re-assigning `notes`
    // on that echo would drop an edit made in the window between the write and
    // the notification, so identical content is a no-op.
    if (Notes.serializeStore(parsed) === Notes.serializeStore(notes)) return

    // An external edit invalidates whatever the panel was pointing at.
    notes = parsed
    if (Notes.indexOfId(notes, editingNoteId) === -1) editingNoteId = ""
    if (Notes.indexOfId(notes, menuNoteId) === -1) closeMenu()
    cursorIndex = Math.min(cursorIndex, notes.length - 1)
  }

  function mutate(next) {
    if (next === notes) return
    notes = next
    scheduleSave()
  }

  // ---------------------------------------------------------------- actions
  function fileNote(text) {
    if (Notes.isBlank(text)) return false
    mutate(Notes.addNote(notes, text))
    cursorIndex = -1
    return true
  }

  function commitEdit(id, text) {
    mutate(Notes.updateNote(notes, id, text))
    editingNoteId = ""
    focusCompose()
  }

  function deleteNote(id) {
    var note = Notes.findById(notes, id)
    if (!note) return

    // Position is part of what undo restores — dropping a note back on top of
    // the list would silently reorder it.
    pendingUndo = { note: note, index: Notes.indexOfId(notes, id) }
    undoTimer.restart()

    mutate(Notes.removeNote(notes, id))
    if (editingNoteId === id) editingNoteId = ""
    closeMenu()
    cursorIndex = Math.min(cursorIndex, notes.length - 1)
  }

  function undoDelete() {
    if (!pendingUndo) return
    var restored = notes.slice()
    restored.splice(Math.min(pendingUndo.index, restored.length), 0, pendingUndo.note)
    pendingUndo = null
    undoTimer.stop()
    mutate(restored)
  }

  function copyNote(id) {
    var note = Notes.findById(notes, id)
    if (!note) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(note.text) + " | wl-copy"])
    closeMenu()
  }

  function beginEdit(id) {
    menuNoteId = ""
    editingNoteId = id
  }

  // ------------------------------------------------------------------ menu
  function openMenu(id, x, top, rowWidth, rowHeight) {
    if (editingNoteId !== "") return
    menuNoteId = id
    menuIndex = 0
    menuX = x
    menuRowTop = top
    menuRowHeight = rowHeight
    // Take the keyboard back off the input so the same j/k that walks the list
    // also walks the menu.
    keys.forceActiveFocus()
  }

  function closeMenu() {
    if (menuNoteId === "") return
    menuNoteId = ""
    focusCompose()
  }

  // --------------------------------------------------------------- keyboard
  function focusCompose() {
    if (compose.item) compose.item.forceEditFocus()
  }

  function moveCursor(delta) {
    if (visibleNotes.length === 0) return
    if (cursorIndex === -1) {
      cursorIndex = delta > 0 ? 0 : visibleNotes.length - 1
    } else {
      cursorIndex = Math.max(0, Math.min(visibleNotes.length - 1, cursorIndex + delta))
    }
    keys.forceActiveFocus()
  }

  function cursorNoteId() {
    if (cursorIndex < 0 || cursorIndex >= visibleNotes.length) return ""
    return visibleNotes[cursorIndex].id
  }

  function handleMove(delta) {
    if (menuNoteId !== "") {
      menuIndex = (menuIndex + delta + actionMenu.count) % actionMenu.count
      return
    }
    moveCursor(delta)
  }

  function handleActivate() {
    if (menuNoteId !== "") {
      actionMenu.activate(menuIndex)
      return
    }
    var id = cursorNoteId()
    if (id === "") return

    var row = rowFor(id)
    if (!row) return
    var corner = row.mapToItem(keys, 0, 0)
    openMenu(id, corner.x, corner.y, row.width, row.height)
  }

  function handleClose() {
    if (menuNoteId !== "") { closeMenu(); return }
    if (cursorIndex !== -1) { cursorIndex = -1; focusCompose(); return }
    root.close()
  }

  function handleDelete() {
    if (menuNoteId !== "") { deleteNote(menuNoteId); return }
    var id = cursorNoteId()
    if (id !== "") deleteNote(id)
  }

  function rowFor(id) {
    for (var i = 0; i < rows.count; i++) {
      var item = rows.itemAt(i)
      if (item && item.noteId === id) return item
    }
    return null
  }

  // ------------------------------------------------------------- lifecycle
  onOpenedChanged: {
    if (opened) {
      cursorIndex = -1
      menuNoteId = ""
      editingNoteId = ""
      Qt.callLater(focusCompose)
    } else {
      flushSave()
      if (compose.item) compose.item.clear()
      pendingUndo = null
      undoTimer.stop()
    }
  }

  // Quickshell evaluates `running` alongside `command` rather than after it,
  // so the mkdir is armed here instead of inline — the same shape the
  // first-party notification service uses for its state directories.
  Component.onCompleted: ensureDir.running = true

  Component.onDestruction: flushSave()

  Timer {
    id: saveTimer
    interval: 400
    onTriggered: root.writeStore()
  }

  Timer {
    id: undoTimer
    interval: 8000
    onTriggered: root.pendingUndo = null
  }

  // FileView cannot watch a file whose directory does not exist yet, so the
  // store path is only handed over once mkdir has returned.
  Process {
    id: ensureDir
    command: ["mkdir", "-p", root.storeDir]
    running: false
    onExited: function(code) {
      if (code === 0) {
        root.storeError = ""
        root.storeReady = true
      } else {
        root.storeError = "can't write to " + root.storeDir
        console.warn("napkin: mkdir failed (" + code + ") for " + root.storeDir)
      }
    }
  }

  FileView {
    id: storeFile

    path: root.storeReady ? root.storePath : ""
    watchChanges: true
    atomicWrites: true
    printErrors: false

    onLoaded: root.applyStore(text())
    onLoadFailed: root.applyStore("")
    onFileChanged: reload()
  }

  // ------------------------------------------------------------- bar button
  readonly property string barGlyph: "\u{F021A}"
  readonly property string barLabel:
    showCount && noteCount > 0 ? barGlyph + " " + noteCount : barGlyph

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button

    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    fontSize: Style.bar.iconFont
    tooltipText: Notes.tooltip(root.visibleNotes)
    active: root.opened
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }
  }

  // ------------------------------------------------------------------ panel
  KeyboardPanel {
    id: panel

    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keys

      anchors.fill: parent

      // While a text box has the keyboard, every key belongs to it — including
      // the j/k that would otherwise be list navigation.
      blocked: root.editingNoteId !== ""
        || (root.menuNoteId === "" && !!compose.item && compose.item.editing === true)

      onMoveRequested: function(dx, dy) { if (dy !== 0) root.handleMove(dy) }
      onActivateRequested: root.handleActivate()
      onCloseRequested: root.handleClose()
      onDeleteRequested: root.handleDelete()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "u") root.undoDelete()
        else if (t === "y" && root.menuNoteId === "") {
          var id = root.cursorNoteId()
          if (id !== "") root.copyNote(id)
        }
      }

      Column {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.spacing.xl

        // ------------------------------------------------------------ header
        Item {
          width: parent.width
          implicitHeight: Math.max(title.implicitHeight, trailing.implicitHeight)

          Text {
            id: title
            textFormat: Text.PlainText
            text: "Napkin"
            color: root.fg
            font.family: root.face
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          // The undo affordance takes over the header's right side while it is
          // live, rather than adding a row that shifts the list down and back.
          Item {
            id: trailing

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: root.storeError !== ""
              ? errorLabel.implicitWidth
              : (root.pendingUndo ? undoRow.implicitWidth : countLabel.implicitWidth)
            implicitHeight: Math.max(errorLabel.implicitHeight,
              Math.max(undoRow.implicitHeight, countLabel.implicitHeight))

            Text {
              id: errorLabel
              visible: root.storeError !== ""
              textFormat: Text.PlainText
              text: root.storeError
              color: root.urgentColor
              font.family: root.face
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }

            Text {
              id: countLabel
              visible: !root.pendingUndo && root.storeError === ""
              textFormat: Text.PlainText
              text: root.noteCount === 0
                ? ""
                : root.noteCount + (root.noteCount === 1 ? " note" : " notes")
              color: root.dim(0.45)
              font.family: root.face
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
            }

            Row {
              id: undoRow
              visible: !!root.pendingUndo && root.storeError === ""
              spacing: Style.spacing.sm
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              Text {
                textFormat: Text.PlainText
                text: "deleted"
                color: root.dim(0.45)
                font.family: root.face
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: undoLink
                textFormat: Text.PlainText
                text: "undo"
                color: undoHover.hovered ? root.accentColor : root.dim(0.75)
                font.family: root.face
                font.pixelSize: Style.font.caption
                font.underline: undoHover.hovered
                anchors.verticalCenter: parent.verticalCenter

                HoverHandler {
                  id: undoHover
                  cursorShape: Qt.PointingHandCursor
                }

                MouseArea {
                  anchors.fill: parent
                  onClicked: root.undoDelete()
                }
              }
            }
          }
        }

        // ----------------------------------------------------------- compose
        Loader {
          id: compose

          width: parent.width
          active: true

          sourceComponent: GrowingInput {
            foreground: root.fg
            accent: root.accentColor
            fontFamily: root.face
            minLines: 1
            maxLines: root.composeMaxLines
            placeholderText: "write it down…"

            onSubmitted: {
              if (root.fileNote(text)) clear()
            }

            onCancelled: {
              // Escape clears a draft first and only closes the panel on the
              // second press — losing half a typed thought to a stray Escape
              // is exactly the failure this app exists to prevent.
              if (!empty) clear()
              else root.close()
            }

            onNavigationRequested: function(delta) { root.moveCursor(delta) }
          }
        }

        // -------------------------------------------------------------- list
        Item {
          width: parent.width
          implicitHeight: root.visibleNotes.length === 0
            ? emptyState.implicitHeight
            : Math.min(notesColumn.implicitHeight, Style.space(300))

          Text {
            id: emptyState
            visible: root.visibleNotes.length === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "Nothing here yet.\nType above and press Enter."
            color: root.dim(0.4)
            font.family: root.face
            font.pixelSize: Style.font.bodySmall
            horizontalAlignment: Text.AlignHCenter
            lineHeight: 1.35
            topPadding: Style.space(10)
            bottomPadding: Style.space(10)
          }

          Flickable {
            id: listFlick

            anchors.fill: parent
            visible: root.visibleNotes.length > 0
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            contentWidth: width
            contentHeight: notesColumn.implicitHeight
            interactive: contentHeight > height

            Column {
              id: notesColumn
              width: listFlick.width
              spacing: Style.spacing.xxs

              Repeater {
                id: rows
                model: root.visibleNotes

                delegate: NoteRow {
                  required property int index
                  required property var modelData

                  width: notesColumn.width
                  reporter: keys

                  noteId: modelData.id
                  noteText: modelData.text
                  timeLabel: Notes.relativeTime(modelData.updated, clock.now)
                  previewLines: root.previewLines
                  editorMaxLines: Math.max(root.composeMaxLines, 4)

                  foreground: root.fg
                  accent: root.accentColor
                  fontFamily: root.face

                  editing: root.editingNoteId === modelData.id
                  menuOpen: root.menuNoteId === modelData.id
                  hasCursor: root.cursorIndex === index

                  onMenuRequested: function(x, top, rowWidth, rowHeight) {
                    root.cursorIndex = index
                    root.openMenu(modelData.id, x, top, rowWidth, rowHeight)
                  }
                  onEditCommitted: function(text) { root.commitEdit(modelData.id, text) }
                  onEditCancelled: {
                    root.editingNoteId = ""
                    root.focusCompose()
                  }
                }
              }
            }

            ScrollBar.vertical: ScrollBar {
              policy: listFlick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
              width: Style.space(4)
            }
          }
        }
      }

      // ------------------------------------------------------- action menu
      //
      // Sibling of the content rather than a child of the row, so the card is
      // not clipped by the list's Flickable and can overhang it.
      Item {
        anchors.fill: parent
        visible: root.menuNoteId !== ""
        z: 50

        MouseArea {
          anchors.fill: parent
          onClicked: root.closeMenu()
        }

        ActionMenu {
          id: actionMenu

          foreground: root.fg
          accent: root.accentColor
          urgent: root.urgentColor
          fontFamily: root.face
          selectedIndex: root.menuIndex

          // Anchored under the row, flipped above it when there is not enough
          // room below, and always kept inside the card.
          readonly property real belowY: root.menuRowTop + root.menuRowHeight + Style.space(2)
          readonly property real aboveY: root.menuRowTop - implicitHeight - Style.space(2)

          x: Math.max(0, Math.min(root.menuX + Style.space(12), parent.width - implicitWidth))
          y: belowY + implicitHeight <= parent.height
            ? belowY
            : Math.max(0, aboveY)

          onCopyRequested: root.copyNote(root.menuNoteId)
          onEditRequested: root.beginEdit(root.menuNoteId)
          onDeleteRequested: root.deleteNote(root.menuNoteId)
        }
      }
    }
  }

  // Relative timestamps go stale on their own; one shared tick redraws every
  // row's label instead of each row owning a timer.
  Timer {
    id: clock
    property double now: Date.now()
    interval: 30000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: now = Date.now()
  }
}
