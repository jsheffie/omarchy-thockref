import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "ThockRefModel.js" as Model

// The ThockRef popup: a search field over a list of shortcut libraries.
//
// Three views share one card. With an empty query the libraries are listed;
// typing filters every shortcut across every library; picking a library
// shows its sections, rows, collapsible keyboard-layout legend, and links.
// Mirrors the macOS app's ContentView and ShortcutListView.
//
// BarWidget.qml owns the bar icon and hands this panel the button to anchor
// against.
Panel {
  id: root
  moduleName: "io.github.jsheffie.thockref"
  ipcTarget: "io.github.jsheffie.thockref"
  manageIpc: false

  property var anchorItem: null

  // The bar tracks the widget mounted in its slot, not this nested panel, so
  // everything the bar identifies a panel by has to be that widget.
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // ---- Data
  property var libraries: []
  property bool loading: false

  readonly property string configDir: {
    var xdg = Quickshell.env("XDG_CONFIG_HOME")
    var base = xdg && xdg !== "" ? xdg : Quickshell.env("HOME") + "/.config"
    return base + "/thockref"
  }
  readonly property string listScript: decodeURIComponent(
    Qt.resolvedUrl("list-libraries.sh").toString().replace(/^file:\/\//, ""))
  // list-libraries.sh caps its output at 8 MiB of file content; JSON escaping
  // can at most double that. Anything larger is not something to parse here.
  readonly property int maxScanChars: 20 * 1024 * 1024

  // ---- View state. The search field is the source of truth for the query.
  readonly property string query: searchField.text
  property int detailIndex: -1
  property int selectedIndex: -1
  property bool legendExpanded: false

  readonly property string mode: detailIndex >= 0 ? "detail" : (query !== "" ? "results" : "libraries")
  readonly property var results: mode === "results" ? Model.search(query, libraries) : []
  readonly property var detailLibrary: detailIndex >= 0 && detailIndex < libraries.length ? libraries[detailIndex] : null
  readonly property var detailRows: Model.detailRows(detailLibrary)
  readonly property var rows: mode === "detail" ? detailRows : (mode === "results" ? resultRows(results) : libraryRows(libraries))
  readonly property bool hasLegend: !!detailLibrary && detailLibrary.layoutLegend !== null

  function libraryRows(libs) {
    var out = []
    for (var i = 0; i < libs.length; i++) out.push({ kind: "library", name: libs[i].name, index: i })
    return out
  }

  function resultRows(found) {
    var out = []
    for (var i = 0; i < found.length; i++) {
      out.push({
        kind: "result",
        keys: found[i].shortcut.keys,
        description: found[i].shortcut.description,
        source: found[i].shortcut.source,
        libraryIndex: found[i].libraryIndex
      })
    }
    return out
  }

  // Guarded so the widget renders before the bar is injected.
  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property color accentColor: Color.accent
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimForeground: Qt.darker(contentForeground, 1.4)
  readonly property color faintForeground: Qt.darker(contentForeground, 1.9)
  readonly property color hoverFill: Style.hoverFillFor(contentForeground, accentColor)
  readonly property int keysColumnWidth: Style.space(120)

  // ---- Lifecycle

  function open() {
    root.detailIndex = -1
    root.selectedIndex = -1
    root.legendExpanded = false
    searchField.text = ""
    root.disarmHover()
    root.refresh()
    root.controller.show()
    // Set after showing: showing hands the popout coordinator over, which
    // closes whichever panel was open, and that close clears the shared flag.
    Qt.callLater(function() {
      if (root.opened) setCenterHoverRevealSuppressed(true)
    })
  }

  function close() {
    setCenterHoverRevealSuppressed(false)
    root.controller.hide()
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Summoning by hotkey moves no pointer, so a hover the bar was still
  // holding must not keep the center indicators revealed behind the panel.
  function setCenterHoverRevealSuppressed(value) {
    if (root.bar && "centerHoverRevealSuppressed" in root.bar)
      root.bar.centerHoverRevealSuppressed = value
  }

  // ---- Loading

  function refresh() {
    if (loadProc.running) {
      loadProc.rerun = true
      return
    }
    root.loading = true
    loadProc.command = ["bash", root.listScript, root.configDir]
    loadProc.running = true
  }

  function applyScan(raw) {
    var next = Model.parseScan(raw)
    var keepName = root.detailLibrary ? root.detailLibrary.name : ""
    root.libraries = next
    if (keepName !== "") root.detailIndex = Model.indexOfLibrary(next, keepName)
    if (root.selectedIndex >= root.rows.length) root.selectedIndex = root.rows.length - 1
  }

  Process {
    id: loadProc
    property bool rerun: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        if (raw.length > root.maxScanChars) {
          console.warn("ThockRef: ignoring an oversized library scan (" + raw.length + " chars)")
          raw = "[]"
        }
        root.applyScan(raw)
      }
    }

    onExited: {
      root.loading = false
      if (rerun) {
        rerun = false
        root.refresh()
      }
    }
  }

  // ---- Navigation

  function showDetail(index) {
    if (index < 0 || index >= root.libraries.length) return
    root.detailIndex = index
    root.selectedIndex = -1
    root.legendExpanded = false
    root.disarmHover()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function goBack() {
    root.detailIndex = -1
    root.selectedIndex = -1
    root.disarmHover()
    Qt.callLater(function() { searchField.forceActiveFocus() })
  }

  function moveCursor(delta) {
    pointerGate.reset()
    root.selectedIndex = Model.stepCursor(root.rows, root.selectedIndex, delta, root.mode === "detail" && root.hasLegend)
  }

  function activateCursor() {
    if (root.mode === "detail" && root.selectedIndex < 0) {
      if (root.hasLegend) root.legendExpanded = !root.legendExpanded
      return
    }
    var row = root.rows[root.selectedIndex]
    if (!row) return
    if (row.kind === "library") root.showDetail(row.index)
    else if (row.kind === "result") root.showDetail(row.libraryIndex)
    else if (row.kind === "link") root.openLink(row.url)
  }

  function openLink(url) {
    if (!root.bar) return
    if (!/^https?:\/\//.test(String(url))) return
    root.bar.run("xdg-open " + Util.shellQuote(url))
    root.close()
  }

  function clearOrClose() {
    if (searchField.text !== "") searchField.text = ""
    else root.close()
  }

  // Hover moves the cursor only when the pointer itself moved. Without the
  // gate, keyboard scrolling slides new rows under a resting pointer and each
  // one would grab the cursor back.
  function pointerMoved(item, mouse) {
    if (!root.hoverArmed) return false
    return pointerGate.moved(item, mouse)
  }

  // The card is placed after it maps, so the first hover samples after an
  // open (or a list swap) can look like movement to a resting pointer. Hover
  // is ignored until the layout has settled.
  property bool hoverArmed: false

  function disarmHover() {
    root.hoverArmed = false
    pointerGate.reset()
    hoverArmTimer.restart()
  }

  Timer {
    id: hoverArmTimer
    interval: 250
    onTriggered: {
      pointerGate.reset()
      root.hoverArmed = true
    }
  }

  PointerMoveGate {
    id: pointerGate
    referenceItem: keyCatcher
  }

  // ---- Surface

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: searchField
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.cappedContentHeight(Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the search field owns the keys, the catcher does nothing at all;
      // the field handles Up/Down/Enter/Esc/Tab itself below.
      blocked: searchField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx < 0 && root.mode === "detail") root.goBack()
      }
      onActivateRequested: root.activateCursor()
      onCloseRequested: {
        if (root.mode === "detail") root.goBack()
        else root.clearOrClose()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "/" && root.mode === "detail") root.goBack()
        else if (t === "L" && root.mode === "detail") root.legendExpanded = !root.legendExpanded
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // ---- Header: search field, or back button + library title
        Item {
          width: parent.width
          height: Math.max(searchRow.implicitHeight, detailHeader.implicitHeight)

          Row {
            id: searchRow
            visible: root.mode !== "detail"
            width: parent.width
            spacing: Style.space(6)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "󰍉"
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.icon
            }

            TextField {
              id: searchField
              width: parent.width - parent.spacing * 2 - Style.font.icon - clearButton.width
              foreground: root.contentForeground
              accent: root.accentColor
              font.family: root.contentFontFamily
              placeholderText: "Search shortcuts…"

              onTextChanged: { pointerGate.reset(); root.selectedIndex = -1 }

              Keys.onPressed: function(event) {
                if (event.key === Qt.Key_Down) {
                  root.moveCursor(1); event.accepted = true
                } else if (event.key === Qt.Key_Up) {
                  root.moveCursor(-1); event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                  root.activateCursor(); event.accepted = true
                } else if (event.key === Qt.Key_Escape) {
                  root.clearOrClose(); event.accepted = true
                } else if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                  var backwards = event.key === Qt.Key_Backtab || (event.modifiers & Qt.ShiftModifier)
                  root.switchPanel(backwards ? -1 : 1)
                  event.accepted = true
                }
              }
            }

            PanelActionButton {
              id: clearButton
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅖"
              tooltipText: "Clear"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              visible: root.query !== ""
              onClicked: {
                searchField.text = ""
                searchField.forceActiveFocus()
              }
            }
          }

          Item {
            id: detailHeader
            visible: root.mode === "detail"
            width: parent.width
            implicitHeight: backButton.implicitHeight

            PanelActionButton {
              id: backButton
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              iconText: "󰅁"
              tooltipText: "Back"
              foreground: root.contentForeground
              fontFamily: root.contentFontFamily
              onClicked: root.goBack()
            }

            Text {
              anchors.centerIn: parent
              width: parent.width - backButton.width * 2 - Style.space(8)
              text: root.detailLibrary ? root.detailLibrary.name : ""
              textFormat: Text.PlainText
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // ---- Body
        Item {
          width: parent.width
          height: content.height - y

          // Empty states
          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(24)
            spacing: Style.space(6)
            visible: root.libraries.length === 0 && !root.loading

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "󰌌"
              textFormat: Text.PlainText
              color: root.faintForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.displayLarge
            }
            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "No shortcut libraries yet"
              textFormat: Text.PlainText
              color: root.dimForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.subtitle
            }
            Text {
              width: parent.width
              text: "Add .md files to " + root.configDir + "/"
              textFormat: Text.PlainText
              color: root.faintForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
              horizontalAlignment: Text.AlignHCenter
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.libraries.length > 0 && root.mode === "results" && root.results.length === 0
            text: "No results for “" + root.query + "”"
            textFormat: Text.PlainText
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          Text {
            anchors.centerIn: parent
            visible: root.mode === "detail" && root.detailRows.length === 0 && !root.hasLegend
            text: "No shortcuts found"
            textFormat: Text.PlainText
            color: root.dimForeground
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.body
          }

          // Libraries
          ListView {
            id: libraryList
            anchors.fill: parent
            visible: root.mode === "libraries"
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
            model: root.mode === "libraries" ? root.rows : []
            currentIndex: root.selectedIndex
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain); else positionViewAtBeginning()

            delegate: CursorSurface {
              id: libraryRow
              required property var modelData
              required property int index
              width: ListView.view.width
              height: libraryRowContent.implicitHeight + Style.space(12)
              hasCursor: root.selectedIndex === index
              foreground: root.contentForeground
              accent: root.accentColor

              Row {
                id: libraryRowContent
                anchors.verticalCenter: parent.verticalCenter
                x: Style.spacing.rowPaddingX
                width: parent.width - Style.spacing.rowPaddingX * 2
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰈙"
                  textFormat: Text.PlainText
                  color: root.accentColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.icon
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - parent.spacing * 2 - Style.font.icon * 2
                  text: modelData ? String(modelData.name) : ""
                  textFormat: Text.PlainText
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "󰅂"
                  textFormat: Text.PlainText
                  color: root.faintForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.icon
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) { if (root.pointerMoved(libraryRow, mouse)) root.selectedIndex = libraryRow.index }
                onClicked: root.showDetail(modelData.index)
              }
            }
          }

          // Search results
          ListView {
            id: resultList
            anchors.fill: parent
            visible: root.mode === "results"
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
            model: root.mode === "results" ? root.rows : []
            currentIndex: root.selectedIndex
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain); else positionViewAtBeginning()

            delegate: CursorSurface {
              id: resultRow
              required property var modelData
              required property int index
              width: ListView.view.width
              height: resultRowContent.implicitHeight + Style.space(10)
              hasCursor: root.selectedIndex === index
              foreground: root.contentForeground
              accent: root.accentColor

              Row {
                id: resultRowContent
                anchors.verticalCenter: parent.verticalCenter
                x: Style.spacing.rowPaddingX
                width: parent.width - Style.spacing.rowPaddingX * 2
                spacing: Style.space(12)

                Text {
                  width: root.keysColumnWidth
                  text: modelData ? Model.highlightMarkup(modelData.keys, root.query, root.accentColor.toString()) : ""
                  textFormat: Text.StyledText
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  wrapMode: Text.Wrap
                }
                Column {
                  width: parent.width - parent.spacing - root.keysColumnWidth
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData ? Model.highlightMarkup(modelData.description, root.query, root.accentColor.toString()) : ""
                    textFormat: Text.StyledText
                    color: root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
                  }
                  Text {
                    width: parent.width
                    text: modelData ? String(modelData.source) : ""
                    textFormat: Text.PlainText
                    color: root.faintForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
              }

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onPositionChanged: function(mouse) { if (root.pointerMoved(resultRow, mouse)) root.selectedIndex = resultRow.index }
                onClicked: root.showDetail(modelData.libraryIndex)
              }
            }
          }

          // Library detail
          ListView {
            id: detailList
            anchors.fill: parent
            visible: root.mode === "detail"
            clip: true
            spacing: Style.space(2)
            boundsBehavior: Flickable.StopAtBounds
            interactive: contentHeight > height
            QQC.ScrollBar.vertical: QQC.ScrollBar { policy: QQC.ScrollBar.AsNeeded }
            model: root.mode === "detail" ? root.rows : []
            currentIndex: root.selectedIndex
            onCurrentIndexChanged: if (currentIndex >= 0) positionViewAtIndex(currentIndex, ListView.Contain); else positionViewAtBeginning()

            header: Column {
              width: ListView.view ? ListView.view.width : 0
              spacing: 0
              visible: root.hasLegend
              height: visible ? implicitHeight : 0
              // A header that grows or shrinks leaves the view anchored on the
              // first row, with the legend itself out of sight. While the cursor
              // sits on the header, keep the top in view.
              onHeightChanged: if (root.selectedIndex < 0) Qt.callLater(detailList.positionViewAtBeginning)

              CursorSurface {
                width: parent.width
                height: legendToggle.implicitHeight + Style.space(10)
                hasCursor: root.selectedIndex === -1 && keyCatcher.activeFocus
                foreground: root.contentForeground
                accent: root.accentColor

                Row {
                  id: legendToggle
                  anchors.verticalCenter: parent.verticalCenter
                  x: Style.spacing.rowPaddingX
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.legendExpanded ? "󰅀" : "󰅂"
                    textFormat: Text.PlainText
                    color: root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.iconSmall
                  }
                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰌌  Keyboard Layout"
                    textFormat: Text.PlainText
                    color: root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: function(mouse) { if (root.pointerMoved(parent, mouse)) root.selectedIndex = -1 }
                  onClicked: root.legendExpanded = !root.legendExpanded
                }
              }

              Text {
                visible: root.legendExpanded
                width: parent.width
                text: root.detailLibrary && root.detailLibrary.layoutLegend !== null ? root.detailLibrary.layoutLegend : ""
                textFormat: Text.PlainText
                color: root.dimForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.NoWrap
                leftPadding: Style.spacing.rowPaddingX + Style.space(4)
                topPadding: Style.space(2)
                bottomPadding: Style.space(8)
                clip: true
              }

              PanelSeparator { foreground: root.contentForeground }

              Item { width: 1; height: Style.space(4) }
            }

            delegate: Item {
              id: detailRow
              required property var modelData
              required property int index
              readonly property string kind: modelData ? String(modelData.kind) : ""
              width: ListView.view.width
              height: sectionItem.visible ? sectionItem.implicitHeight
                    : (shortcutItem.visible ? shortcutItem.height
                    : (linksHeaderItem.visible ? linksHeaderItem.implicitHeight : linkItem.height))

              // Section header, styled like the mac app's inverted header bar.
              Column {
                id: sectionItem
                visible: detailRow.kind === "section"
                width: parent.width
                topPadding: detailRow.index === 0 ? 0 : Style.space(10)

                Rectangle {
                  width: parent.width
                  height: Style.spacing.hairline
                  color: root.contentForeground
                }
                Rectangle {
                  width: parent.width
                  height: sectionLabel.implicitHeight + Style.space(8)
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

                  Text {
                    id: sectionLabel
                    anchors.verticalCenter: parent.verticalCenter
                    x: Style.spacing.rowPaddingX
                    width: parent.width - Style.spacing.rowPaddingX * 2
                    text: detailRow.kind === "section" ? String(modelData.title || "").toUpperCase() : ""
                    textFormat: Text.PlainText
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                }
              }

              // Key sequence and description.
              CursorSurface {
                id: shortcutItem
                visible: detailRow.kind === "shortcut"
                width: parent.width
                height: shortcutContent.implicitHeight + Style.space(8)
                hasCursor: root.selectedIndex === detailRow.index
                foreground: root.contentForeground
                accent: root.accentColor

                Row {
                  id: shortcutContent
                  anchors.verticalCenter: parent.verticalCenter
                  x: Style.spacing.rowPaddingX
                  width: parent.width - Style.spacing.rowPaddingX * 2
                  spacing: Style.space(12)

                  Text {
                    width: root.keysColumnWidth
                    text: detailRow.kind === "shortcut" ? String(modelData.keys || "") : ""
                    textFormat: Text.PlainText
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
                  }
                  Text {
                    width: parent.width - parent.spacing - root.keysColumnWidth
                    text: detailRow.kind === "shortcut" ? String(modelData.description || "") : ""
                    textFormat: Text.PlainText
                    color: root.dimForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    wrapMode: Text.Wrap
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  onPositionChanged: function(mouse) { if (root.pointerMoved(shortcutItem, mouse)) root.selectedIndex = detailRow.index }
                }
              }

              // "Links" heading
              Column {
                id: linksHeaderItem
                visible: detailRow.kind === "linksHeader"
                width: parent.width
                topPadding: Style.space(10)
                spacing: Style.space(6)

                PanelSeparator { foreground: root.contentForeground }
                PanelSectionHeader {
                  x: Style.spacing.rowPaddingX
                  text: "LINKS"
                  foreground: root.contentForeground
                  fontFamily: root.contentFontFamily
                }
              }

              // One link row; click or Enter opens it in the browser.
              CursorSurface {
                id: linkItem
                visible: detailRow.kind === "link"
                width: parent.width
                height: linkLabel.implicitHeight + Style.space(8)
                hasCursor: root.selectedIndex === detailRow.index
                foreground: root.contentForeground
                accent: root.accentColor

                Row {
                  anchors.verticalCenter: parent.verticalCenter
                  x: Style.spacing.rowPaddingX
                  width: parent.width - Style.spacing.rowPaddingX * 2
                  spacing: Style.space(8)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰌷"
                    textFormat: Text.PlainText
                    color: root.accentColor
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.iconSmall
                  }
                  Text {
                    id: linkLabel
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - parent.spacing - Style.font.iconSmall
                    text: detailRow.kind === "link" ? String(modelData.label || "") : ""
                    textFormat: Text.PlainText
                    color: root.accentColor
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onPositionChanged: function(mouse) { if (root.pointerMoved(linkItem, mouse)) root.selectedIndex = detailRow.index }
                  onClicked: root.openLink(modelData.url)
                }
              }
            }
          }
        }
      }
    }
  }
}
