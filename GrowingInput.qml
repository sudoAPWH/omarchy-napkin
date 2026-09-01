import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui

// Multi-line text input that grows with its content instead of scrolling a
// fixed box. Starts at `minLines`, expands a line at a time as you type, and
// once it reaches `maxLines` stops growing and scrolls internally with the
// cursor.
//
// The kit ships a single-line TextField and nothing taller, so the chrome here
// is deliberately copied from it — same Border.controlSpec state ladder, same
// Style.controlFill, same padding tokens — so the box reads as part of the
// same family rather than a stray Qt Quick Controls default.
//
// The Flickable + `TextArea.flickable` pairing is what buys cursor-follow
// scrolling for free; a bare TextArea with a capped height would simply clip
// the line you are typing on.
Item {
  id: root

  property alias text: edit.text
  property alias placeholderText: edit.placeholderText
  property alias cursorPosition: edit.cursorPosition
  property alias readOnly: edit.readOnly

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int fontSize: Style.font.body
  property int minLines: 1
  property int maxLines: 8
  property real horizontalPadding: Style.spacing.controlPaddingX
  property real verticalPadding: Style.spacing.inputPaddingY

  // Enter submits, Shift+Enter inserts a newline. A note is usually one line
  // and reaching for a Save button every time would be the wrong default; the
  // multi-line case is the one that gets the modifier.
  signal submitted()
  signal cancelled()

  // Up/Down while the box is empty are not cursor movement — there is nothing
  // to move through — so they are handed back to the panel to drive the list
  // instead. Once there is text to edit, the arrows go back to being arrows.
  signal navigationRequested(int delta)

  readonly property bool editing: edit.activeFocus
  readonly property bool empty: edit.text.replace(/^\s+|\s+$/g, "").length === 0

  function forceEditFocus() { edit.forceActiveFocus() }
  function selectAllText() { edit.selectAll() }
  function moveCursorToEnd() { edit.cursorPosition = edit.length }
  function clear() { edit.text = "" }

  readonly property bool _hot: hover.hovered
  readonly property var _borderSpec:
    Border.controlSpec(editing ? "focus" : (_hot ? "hover-cursor" : "normal"), foreground, accent)

  readonly property real _lineHeight: Math.ceil(metrics.height)
  readonly property real _chromeHeight:
    verticalPadding * 2 + Border.top(_borderSpec) + Border.bottom(_borderSpec)
  readonly property real _minHeight: Math.max(1, minLines) * _lineHeight
  readonly property real _maxHeight: Math.max(Math.max(1, minLines), maxLines) * _lineHeight

  implicitHeight: Math.round(
    Math.min(Math.max(edit.contentHeight, _minHeight), _maxHeight) + _chromeHeight)

  FontMetrics {
    id: metrics
    font.family: root.fontFamily
    font.pixelSize: root.fontSize
  }

  HoverHandler {
    id: hover
    cursorShape: Qt.IBeamCursor
  }

  BorderSurface {
    anchors.fill: parent
    color: Style.controlFill(root.editing, root._hot, root.foreground, root.accent)
    borderSpec: root._borderSpec
    radius: Style.cornerRadius
  }

  Flickable {
    id: flick

    anchors.fill: parent
    anchors.topMargin: Border.top(root._borderSpec)
    anchors.bottomMargin: Border.bottom(root._borderSpec)
    anchors.leftMargin: Border.left(root._borderSpec)
    anchors.rightMargin: Border.right(root._borderSpec)

    clip: true
    boundsBehavior: Flickable.StopAtBounds
    contentWidth: width
    contentHeight: edit.contentHeight + edit.topPadding + edit.bottomPadding
    interactive: contentHeight > height

    TextArea.flickable: TextArea {
      id: edit

      wrapMode: TextArea.Wrap
      selectByMouse: true
      font.family: root.fontFamily
      font.pixelSize: root.fontSize
      color: root.foreground
      selectionColor: Style.selectionFillFor(root.foreground, root.accent)
      selectedTextColor: root.foreground
      placeholderTextColor: Qt.darker(root.foreground, 1.6)

      leftPadding: root.horizontalPadding
      rightPadding: root.horizontalPadding
      topPadding: root.verticalPadding
      bottomPadding: root.verticalPadding

      background: null

      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
          root.cancelled()
          event.accepted = true
          return
        }
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
          if (event.modifiers & Qt.ShiftModifier) return  // let the newline through
          root.submitted()
          event.accepted = true
          return
        }
        if ((event.key === Qt.Key_Down || event.key === Qt.Key_Up) && root.empty) {
          root.navigationRequested(event.key === Qt.Key_Down ? 1 : -1)
          event.accepted = true
        }
      }
    }

    ScrollBar.vertical: ScrollBar {
      policy: flick.interactive ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
      width: Style.space(4)
    }
  }
}
