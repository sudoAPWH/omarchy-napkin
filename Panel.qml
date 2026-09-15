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
// There is no save button and no confirmation step anywhere: every change is
// written as it happens, and a delete is undoable for a few seconds rather
// than guarded by a dialog.
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
  // A relative XDG_DATA_HOME is invalid by the spec and has to be ignored.
  readonly property string dataHome: {
    var xdg = Quickshell.env("XDG_DATA_HOME")
    return xdg && xdg.charAt(0) === "/" ? xdg : Quickshell.env("HOME") + "/.local/share"
  }
  readonly property string defaultStorePath: dataHome + "/napkin/notes.json"

  // The configured path, expanded, or the reason it can't be used. Only a bare
  // `~/` expands: `~bob/notes.json` means another user's home, and pasting HOME
  // in front of "bob/..." would quietly point somewhere else entirely.
  readonly property var storeTarget: {
    var configured = String(setting("storePath", "")).replace(/^\s+|\s+$/g, "")
    if (configured.length === 0) return { path: defaultStorePath, problem: "" }
    if (configured === "~") return { path: "", problem: "storePath must name a file, not a folder" }

    var p = configured
    if (p.indexOf("~/") === 0) p = Quickshell.env("HOME") + p.substring(1)
    else if (p.charAt(0) === "~") return { path: "", problem: "storePath can't use ~user paths" }

    if (p.charAt(0) !== "/") return { path: "", problem: "storePath must be an absolute path" }
    if (p.indexOf("\u0000") !== -1) return { path: "", problem: "storePath contains a null character" }
    var name = p.substring(p.lastIndexOf("/") + 1)
    if (name === "" || name === "." || name === "..")
      return { path: "", problem: "storePath must name a file, not a folder" }
    return { path: p, problem: "" }
  }

  readonly property int composeMaxLines: Math.max(1, Math.min(20, Number(setting("composeMaxLines", 8)) || 8))
  readonly property int previewLines: Math.max(1, Math.min(12, Number(setting("previewLines", 3)) || 3))
  readonly property bool showCount: setting("showCount", true) !== false
  readonly property bool newestFirst: setting("newestFirst", true) !== false

  // ---------------------------------------------------------------- state
  // Everything about the file lives in Store.qml. `notes` is its list, replaced
  // wholesale on every change.
  readonly property var notes: store.notes

  // A problem with the store is surfaced in the header rather than logged and
  // forgotten: a notes app that silently fails to save is worse than one that
  // refuses to take the note. `notice` is the short-lived kind, for an action
  // that was just turned down.
  readonly property string statusText: store.error !== "" ? store.error : notice
  property string notice: ""

  // The note whose action menu is open, and the note being edited. Only one of
  // the two is ever set — opening the editor closes the menu that launched it.
  property string menuNoteId: ""
  property string editingNoteId: ""

  // The text of the note being edited, held here and not only in the row's
  // editor: the list rebuilds every row whenever the notes change, so an outside
  // edit landing mid-edit would otherwise throw away what you were typing.
  property string editDraft: ""
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

  // The list is a Repeater in a Column, so every row it is given becomes a live
  // item — there is no recycling and nothing is freed by scrolling past it.
  // That is the right trade for the handful of notes this panel is actually
  // for, and the wrong one for a store that grew without anyone watching, so
  // the model is capped and the remainder is reported rather than built. The
  // cap is far past what anyone scrolls to; it exists to keep a pathological
  // file from instantiating thousands of items inside a process that has to
  // stay responsive for the rest of the session.
  readonly property int renderLimit: 500
  readonly property var renderedNotes:
    visibleNotes.length > renderLimit ? visibleNotes.slice(0, renderLimit) : visibleNotes
  readonly property int hiddenCount: visibleNotes.length - renderedNotes.length
  readonly property color fg: bar ? bar.foreground : Color.foreground
  readonly property color accentColor: Color.accent
  readonly property color urgentColor: bar ? bar.urgent : Color.urgent
  readonly property string face: bar ? bar.fontFamily : Style.font.family

  function dim(alpha) {
    return Qt.rgba(fg.r, fg.g, fg.b, alpha)
  }

  // ------------------------------------------------------------ persistence
  function mutate(next) {
    return store.commit(next)
  }

  function showNotice(text) {
    notice = text
    noticeTimer.restart()
  }

  // Turns a change down and says why, unless the store's own error is already
  // on screen saying it.
  function refuse() {
    if (store.error === "") showNotice(store.loaded ? "saving is off" : "still loading notes")
    return false
  }

  function refuseTooLong() {
    showNotice("notes are limited to " + Notes.MAX_NOTE_CHARS + " characters")
    return false
  }

  // The store replaced the list from disk, so whatever the panel was pointing
  // at may be gone.
  function storeReplaced() {
    if (editingNoteId !== "" && Notes.indexOfId(notes, editingNoteId) === -1) cancelEdit()
    if (menuNoteId !== "" && Notes.indexOfId(notes, menuNoteId) === -1) closeMenu()
    cursorIndex = Math.min(cursorIndex, renderedNotes.length - 1)
  }

  // ---------------------------------------------------------------- actions
  // Every action checks the store first. A turned-down note stays in the input
  // and a turned-down edit stays open, so nothing typed is lost to a store that
  // can't save right now.
  function fileNote(text) {
    if (Notes.isBlank(text)) return false
    if (!store.canWrite) return refuse()
    if (Notes.isTooLong(text)) return refuseTooLong()
    if (!mutate(Notes.addNote(notes, text))) return refuse()
    cursorIndex = -1
    return true
  }

  // Returns whether the edit ended.
  function commitEdit(id, text) {
    if (!store.canWrite) return refuse()
    if (Notes.isTooLong(text)) return refuseTooLong()
    if (!mutate(Notes.updateNote(notes, id, text))) return refuse()
    editingNoteId = ""
    editDraft = ""
    focusCompose()
    return true
  }

  function cancelEdit() {
    editingNoteId = ""
    editDraft = ""
    focusCompose()
  }

  function deleteNote(id) {
    var note = Notes.findById(notes, id)
    if (!note) return
    if (!store.canWrite) {
      refuse()
      return
    }

    // Position is part of what undo restores — dropping a note back on top of
    // the list would silently reorder it.
    var index = Notes.indexOfId(notes, id)
    if (!mutate(Notes.removeNote(notes, id))) {
      refuse()
      return
    }
    pendingUndo = { note: note, index: index }
    undoTimer.restart()

    if (editingNoteId === id) cancelEdit()
    closeMenu()
    cursorIndex = Math.min(cursorIndex, renderedNotes.length - 1)
  }

  function undoDelete() {
    if (!pendingUndo) return
    if (!store.canWrite) {
      refuse()
      return
    }
    var restored = Notes.restoreNote(notes, pendingUndo.note, pendingUndo.index)
    pendingUndo = null
    undoTimer.stop()
    mutate(restored)
  }

  // Straight into wl-copy's stdin, with wl-copy named by absolute path. No shell
  // in between, so the note is never quoted, parsed, or expanded on the way.
  function copyNote(id) {
    var note = Notes.findById(notes, id)
    if (!note) return
    var copier = copyProcess.createObject(root, { payload: note.text })
    copier.running = true
    closeMenu()
  }

  function beginEdit(id) {
    var note = Notes.findById(notes, id)
    if (!note) return
    menuNoteId = ""
    editDraft = note.text
    editingNoteId = id
  }

  // Closing the panel with an edit open keeps the edit, the way every other
  // change here saves itself. An emptied editor counts as a change of heart,
  // not a delete: deleting by clearing the text takes an explicit Enter. An edit
  // the store turns down stays open for when the panel comes back.
  function finishEditOnClose() {
    if (editingNoteId === "") return
    if (Notes.isBlank(editDraft)) {
      cancelEdit()
      return
    }
    commitEdit(editingNoteId, editDraft)
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
    if (renderedNotes.length === 0) return
    if (cursorIndex === -1) {
      cursorIndex = delta > 0 ? 0 : renderedNotes.length - 1
    } else {
      cursorIndex = Math.max(0, Math.min(renderedNotes.length - 1, cursorIndex + delta))
    }
    keys.forceActiveFocus()
  }

  function cursorNoteId() {
    if (cursorIndex < 0 || cursorIndex >= renderedNotes.length) return ""
    return renderedNotes[cursorIndex].id
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

  // Walking the list with j/k could go past the bottom of the scrolled view,
  // leaving the highlighted row, and any menu opened from it, out of sight.
  onCursorIndexChanged: Qt.callLater(revealCursor)

  function revealCursor() {
    if (cursorIndex < 0 || !listFlick.interactive) return
    var row = rows.itemAt(cursorIndex)
    if (!row) return
    if (row.y < listFlick.contentY)
      listFlick.contentY = row.y
    else if (row.y + row.height > listFlick.contentY + listFlick.height)
      listFlick.contentY = row.y + row.height - listFlick.height
  }

  // ------------------------------------------------------------- lifecycle
  onOpenedChanged: {
    if (opened) {
      cursorIndex = -1
      menuNoteId = ""
      store.recheck()
      // An edit still open here is one the store turned down on close; it
      // keeps the keyboard.
      if (editingNoteId === "") Qt.callLater(focusCompose)
    } else {
      // The compose draft is left alone on purpose: clicking away from the
      // panel is not a decision to throw out a half-typed thought.
      finishEditOnClose()
      store.flush()
      pendingUndo = null
      undoTimer.stop()
    }
  }

  // Store writes whatever is pending when it goes away itself; this only makes
  // sure an open edit is part of it.
  Component.onDestruction: finishEditOnClose()

  Timer {
    id: undoTimer
    interval: 8000
    onTriggered: root.pendingUndo = null
  }

  Timer {
    id: noticeTimer
    interval: 4000
    onTriggered: root.notice = ""
  }

  Store {
    id: store
    path: root.storeTarget.path
    pathProblem: root.storeTarget.problem
    onExternalChange: root.storeReplaced()
  }

  // One process per copy, so a second copy while the first is still running
  // isn't dropped.
  Component {
    id: copyProcess
    Process {
      property string payload: ""
      command: ["/usr/bin/wl-copy"]
      stdinEnabled: true
      onStarted: {
        write(payload)
        stdinEnabled = false
      }
      onRunningChanged: if (!running) destroy()
    }
  }

  // ------------------------------------------------------------- bar button
  readonly property string barGlyph: "\u{F021A}"
  readonly property bool countVisible: showCount && noteCount > 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button

    anchors.fill: parent
    bar: root.bar
    text: root.barGlyph
    // `notes` is stored newest-first, so the tooltip shows the most recent few
    // whichever way round the list is set to display.
    tooltipText: Notes.tooltip(root.notes)
    active: root.opened
    onPressed: function(b) { if (b === Qt.LeftButton) root.toggle() }

    // Count as a corner badge rather than a second glyph-sized run beside the
    // icon: at a glance the icon is the thing you aim at, and the number is a
    // detail hanging off it. Sits in the slot's bottom-right, outside the
    // centered icon canvas, so it never sits on top of the glyph itself.
    Text {
      id: countBadge

      visible: root.countVisible
      textFormat: Text.PlainText
      text: root.noteCount > 99 ? "99+" : String(root.noteCount)
      color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      font.family: root.face
      font.pixelSize: Math.max(7, Math.round(Style.bar.iconFont * 0.68))
      font.bold: true

      anchors.right: parent.right
      anchors.bottom: parent.bottom
      anchors.rightMargin: Style.spaceReal(1)
      anchors.bottomMargin: Style.spaceReal(3)
    }
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

            // No wider than the space the title leaves, so a long message
            // elides instead of running over "Napkin".
            readonly property real room: parent.width - title.implicitWidth - Style.spacing.xl

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            implicitWidth: root.statusText !== ""
              ? Math.min(errorLabel.implicitWidth, room)
              : (root.pendingUndo ? undoRow.implicitWidth : countLabel.implicitWidth)
            implicitHeight: Math.max(errorLabel.implicitHeight,
              Math.max(undoRow.implicitHeight, countLabel.implicitHeight))

            Text {
              id: errorLabel
              visible: root.statusText !== ""
              width: Math.min(implicitWidth, trailing.room)
              textFormat: Text.PlainText
              text: root.statusText
              elide: Text.ElideRight
              color: root.urgentColor
              font.family: root.face
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter

              HoverHandler { id: errorHover }

              PanelToolTip {
                visible: errorHover.hovered && errorLabel.truncated
                text: root.statusText
              }
            }

            Text {
              id: countLabel
              visible: !root.pendingUndo && root.statusText === ""
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
              visible: !!root.pendingUndo && root.statusText === ""
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
                model: root.renderedNotes

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
                  editText: root.editDraft
                  menuOpen: root.menuNoteId === modelData.id
                  hasCursor: root.cursorIndex === index

                  onMenuRequested: function(x, top, rowWidth, rowHeight) {
                    root.cursorIndex = index
                    root.openMenu(modelData.id, x, top, rowWidth, rowHeight)
                  }
                  onEditTextEdited: function(text) { if (editing) root.editDraft = text }
                  onEditCommitted: function(text) { root.commitEdit(modelData.id, text) }
                  onEditCancelled: root.cancelEdit()
                }
              }

              Text {
                visible: root.hiddenCount > 0
                width: notesColumn.width
                padding: Style.spacing.controlPaddingY
                horizontalAlignment: Text.AlignHCenter
                text: "… and " + root.hiddenCount + " older "
                      + (root.hiddenCount === 1 ? "note" : "notes") + " not shown"
                color: root.dim(0.5)
                font.family: root.face
                font.pixelSize: Style.font.bodySmall
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
            : Math.max(0, Math.min(aboveY, parent.height - implicitHeight))

          // The mouse and j/k share one selection. Hovering reports up here
          // rather than setting the menu's own index, which would cut that
          // binding and leave Enter acting on a row that isn't highlighted.
          onRowHovered: function(index) { root.menuIndex = index }
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
