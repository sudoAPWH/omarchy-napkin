import QtQuick
import qs.Commons
import qs.Ui

// The little menu that opens against a note. Rendered as a plain Item rather
// than its own window: the panel is already a full-screen layer surface, so
// floating a card inside it keeps the menu on the same surface as the list —
// no second popup to position, focus, or lose to a compositor stacking rule.
//
// State (which row the cursor is on) is owned by the panel so the same j/k
// navigation drives the list and the menu; this file only draws.
Item {
  id: root

  property color foreground: Color.foreground
  property color accent: Color.accent
  property color urgent: Color.urgent
  property string fontFamily: Style.font.family
  property int selectedIndex: 0

  signal copyRequested()
  signal editRequested()
  signal deleteRequested()

  // Hover is reported, not applied: the panel owns the selection so the mouse
  // and j/k move the same one.
  signal rowHovered(int index)

  readonly property int count: 3
  readonly property real rowHeight: Math.max(Style.spacing.popupRowHeight, Style.space(28))

  function activate(index) {
    if (index === 0) root.copyRequested()
    else if (index === 1) root.editRequested()
    else if (index === 2) root.deleteRequested()
  }

  implicitWidth: Style.space(150)
  implicitHeight: menuColumn.implicitHeight + card.contentTopInset + card.contentBottomInset

  BorderSurface {
    id: card

    anchors.fill: parent
    color: Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(1)))
    radius: Style.cornerRadius
    padding: Style.space(4)
  }

  Column {
    id: menuColumn

    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.leftMargin: card.contentLeftInset
    anchors.rightMargin: card.contentRightInset
    anchors.topMargin: card.contentTopInset
    spacing: 0

    Repeater {
      model: [
        { glyph: "\u{F018F}", label: "Copy",   danger: false },
        { glyph: "\u{F03EB}", label: "Edit",   danger: false },
        { glyph: "\u{F0A79}", label: "Delete", danger: true }
      ]

      delegate: Item {
        id: row

        required property int index
        required property var modelData

        width: menuColumn.width
        height: root.rowHeight

        readonly property color tint: row.modelData.danger ? root.urgent : root.foreground
        readonly property bool active: root.selectedIndex === row.index

        Rectangle {
          anchors.fill: parent
          radius: Style.cornerRadius
          visible: row.active
          color: Style.controlFill(false, true, row.tint, root.accent)
        }

        HoverHandler {
          id: rowHover
          cursorShape: Qt.PointingHandCursor
          onHoveredChanged: if (hovered) root.rowHovered(row.index)
        }

        MouseArea {
          anchors.fill: parent
          onClicked: root.activate(row.index)
        }

        Text {
          id: rowGlyph
          textFormat: Text.PlainText
          text: row.modelData.glyph
          color: row.tint
          font.family: root.fontFamily
          font.pixelSize: Style.font.iconSmall
          anchors.left: parent.left
          anchors.leftMargin: Style.space(9)
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          textFormat: Text.PlainText
          text: row.modelData.label
          color: row.tint
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          anchors.left: rowGlyph.right
          anchors.leftMargin: Style.space(9)
          anchors.verticalCenter: parent.verticalCenter
        }
      }
    }
  }
}
