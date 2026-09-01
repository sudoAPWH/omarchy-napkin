import QtQuick
import qs.Commons

// One note in the list. Two states, swapped in place: a collapsed preview that
// truncates at `previewLines`, and an editor that expands with the text.
//
// The row is the whole click target — clicking anywhere on it asks the panel
// for the action menu — so there are no per-row buttons competing for a very
// small amount of horizontal space.
Item {
  id: root

  property string noteId: ""
  property string noteText: ""
  property string timeLabel: ""
  property bool editing: false
  property bool hasCursor: false
  property bool menuOpen: false

  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int previewLines: 3
  property int editorMaxLines: 10

  // Emitted with the row's geometry in `reporter` coordinates, so the panel
  // can float the action menu against the row — and flip it above when the row
  // sits near the bottom — without this item needing to know anything about
  // the surface it lives on.
  property Item reporter: null
  signal menuRequested(real x, real top, real rowWidth, real rowHeight)
  signal editCommitted(string text)
  signal editCancelled()

  readonly property bool active: hasCursor || menuOpen || hover.hovered
  readonly property real horizontalPadding: Style.spacing.rowPaddingX
  readonly property real verticalPadding: Style.spacing.controlPaddingY

  function beginEdit() {
    if (editorLoader.item) {
      editorLoader.item.text = root.noteText
      editorLoader.item.forceEditFocus()
      editorLoader.item.moveCursorToEnd()
    }
  }

  implicitHeight: editing
    ? editorLoader.implicitHeight + verticalPadding * 2
    : preview.implicitHeight + verticalPadding * 2

  Behavior on implicitHeight {
    enabled: !root.editing
    NumberAnimation { duration: 90; easing.type: Easing.OutQuad }
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    visible: root.active && !root.editing
    color: Style.controlFill(false, true, root.foreground, root.accent)
  }

  HoverHandler {
    id: hover
    enabled: !root.editing
    cursorShape: Qt.PointingHandCursor
  }

  MouseArea {
    anchors.fill: parent
    enabled: !root.editing
    acceptedButtons: Qt.LeftButton
    onClicked: {
      if (!root.reporter) return
      var corner = root.mapToItem(root.reporter, 0, 0)
      root.menuRequested(corner.x, corner.y, root.width, root.height)
    }
  }

  // ------------------------------------------------------------- collapsed
  Column {
    id: preview

    visible: !root.editing
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.leftMargin: root.horizontalPadding
    anchors.rightMargin: root.horizontalPadding
    anchors.verticalCenter: parent.verticalCenter
    spacing: Style.spacing.xxs

    Text {
      width: parent.width
      textFormat: Text.PlainText
      text: root.noteText
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      wrapMode: Text.Wrap
      maximumLineCount: Math.max(1, root.previewLines)
      elide: Text.ElideRight
    }

    Text {
      textFormat: Text.PlainText
      text: root.timeLabel
      color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // ---------------------------------------------------------------- editing
  Loader {
    id: editorLoader

    active: root.editing
    visible: root.editing
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.verticalCenter: parent.verticalCenter

    sourceComponent: GrowingInput {
      foreground: root.foreground
      accent: root.accent
      fontFamily: root.fontFamily
      minLines: 1
      maxLines: root.editorMaxLines
      text: root.noteText
      onSubmitted: root.editCommitted(text)
      onCancelled: root.editCancelled()
    }

    onLoaded: Qt.callLater(root.beginEdit)
  }
}
