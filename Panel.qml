import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Uptime + keyboard + screen time bar widget.
//
// Bar label: system uptime with a selectable suffix. Clicking (any button)
// opens the activity panel: uptime, typing and screen time line graphs overlaid
// on the same axes per window (last 24 hours / 7 days / 30 days). The uptime
// format offsets and the display suffix (UT / UpTime) are chosen in the
// panel's settings section, and persist to
// ~/.config/omarchy/bar/uptime-settings.json.
//
// Uptime format modes:
//   0  days / hours / minutes   "12d 3h 45m UT"
//   1  total minutes            "17,827m UT"
//   2  total seconds            "1,069,663s UT"
//   3  total milliseconds       "1,069,663,000ms UT"
//
// Graph data comes from bar/scripts/activity-graphs, fed by the
// robbie-activity user service (bar/scripts/activity-daemon). Keyboard time
// is the sum of typing bursts: presses within 60 seconds of each other form
// one burst, and a burst counts from its first press to its last. Screen
// time is webcam motion: a person counts as present while the camera sees
// movement, and a session closes after two calm minutes.

Panel {
  id: root
  moduleName: "robbie.uptime"
  ipcTarget: "robbie.uptime"

  // ---- uptime state ----
  readonly property int modeCount: 4
  property int mode: 0
  readonly property int suffixCount: 3
  property int suffix: 0
  property real baseSeconds: 0
  property double baseTimeMs: 0
  property real upSeconds: 0

  // ---- panel state ----
  property bool settingsOpen: false
  property var uptimeData: null
  property var keyboardData: null
  property var presenceData: null

  // ---- panel display options ----
  property bool show24: true
  property bool show7: true
  property bool show30: true
  property bool showUptimeLine: true
  property bool showKeyboardLine: true
  property bool showScreenLine: true
  property bool solidBackground: false
  property bool showIcon: true
  property bool infoOpen: false

  readonly property string settingsFilePath: Quickshell.env("HOME") + "/.config/omarchy/bar/uptime-settings.json"

  readonly property var modeNames: [
    "Days / hours / minutes", "Total minutes", "Total seconds", "Total milliseconds"
  ]
  readonly property var suffixNames: ["UT:", "Uptime:", ""]
  readonly property var modeOptions: [
    { label: "D H:M", tip: "Days / hours / minutes" },
    { label: "Min", tip: "Total minutes" },
    { label: "Sec", tip: "Total seconds" },
    { label: "ms", tip: "Total milliseconds" }
  ]
  readonly property var suffixOptions: [
    { label: "UT:", tip: "Display suffix \u201cUT:\u201d" },
    { label: "Uptime:", tip: "Display suffix \u201cUptime:\u201d" },
    { label: "None", tip: "No suffix" }
  ]

  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ~30% upscale for the activity panel and its charts (two 15% bumps).
  readonly property real panelScale: 1.32
  readonly property int panelMargin: Math.round(Style.spacing.sm * root.panelScale)

  // Highest the panel may grow before its content starts scrolling.
  readonly property int panelMaxHeight: {
    var scr = panel.screen || (root.bar ? root.bar.screen : null)
    if (!scr) return 100000
    var barSize = Number(root.bar ? root.bar.barSize : 0)
    return Math.max(Style.space(140), Math.round(Number(scr.height) - barSize - Style.gapsOut * 3))
  }
  readonly property int captionPx: Math.max(1, Math.round(Style.font.caption * root.panelScale))
  readonly property int titlePx: Math.max(1, Math.round(Style.font.title * root.panelScale))
  readonly property int displayPx: Math.max(1, Math.round(Style.font.display * root.panelScale))

  // Chart series colors: green = uptime, yellow = typing, indigo = screen
  // time by default. Edited with the graduated pickers in the settings
  // section; saved as hex strings.
  property color uptimeColor: "#45c26a"
  property color typingColor: "#e2c044"
  property color presenceColor: "#8f8cff"

  // The old discrete swatch palette, kept only so previously-saved color
  // indices migrate to hex on load.
  readonly property var legacyPalette: [
    "#45c26a", "#e2c044", "#8f8cff", "#e5534b", "#39c5cf", "#f778ba",
    "#e6e6e6", "#9aa0a6", "#b57bff", "#ff9f43", "#5eead4", "#4cc3ff"
  ]

  // Graph threshold: a red informational line drawn on every chart at the
// chosen level (seconds per chart). Off by default.
  readonly property var thresholdOptions: [
    { label: "Off", seconds: 0, tip: "No threshold line" },
    { label: "1h", seconds: 3600, tip: "Threshold line at 1 hour per chart" },
    { label: "2h", seconds: 2 * 3600, tip: "Threshold line at 2 hours per chart" },
    { label: "3h", seconds: 3 * 3600, tip: "Threshold line at 3 hours per chart" },
    { label: "4h", seconds: 4 * 3600, tip: "Threshold line at 4 hours per chart" },
    { label: "5h", seconds: 5 * 3600, tip: "Threshold line at 5 hours per chart" },
    { label: "6h", seconds: 6 * 3600, tip: "Threshold line at 6 hours per chart" },
    { label: "8h", seconds: 8 * 3600, tip: "Threshold line at 8 hours per chart" },
    { label: "12h", seconds: 12 * 3600, tip: "Threshold line at 12 hours per chart" }
  ]
  readonly property int thresholdCount: root.thresholdOptions.length
  property int thresholdIndex: 0
  readonly property real thresholdSecs: root.thresholdOptions[root.thresholdIndex] ? Number(root.thresholdOptions[root.thresholdIndex].seconds || 0) : 0
  readonly property color thresholdColor: "#e5484d"

  // ---- persisted settings (uptime-settings.json) ----
  function modIndex(i, n) {
    var v = Math.round(Number(i))
    if (!isFinite(v)) v = 0
    return ((v % n) + n) % n
  }

  function loadSettings(raw) {
    var data = {}
    try { data = JSON.parse(raw || "{}") } catch (err) { data = {} }
    // Pre-v2 files had "hours / minutes" as mode 0, which has since been
    // removed; shift those older indices down so the saved choice survives.
    var legacy = data.version === undefined
    if (data.mode !== undefined) {
      var m = Math.round(Number(data.mode))
      if (!isFinite(m)) m = 0
      if (legacy) m = Math.max(0, m - 1)
      root.mode = root.modIndex(m, root.modeCount)
    }
    if (data.suffix !== undefined) root.suffix = root.modIndex(data.suffix, root.suffixCount)
    if (data.threshold !== undefined) root.thresholdIndex = root.modIndex(data.threshold, root.thresholdCount)
    if (data.colorUp !== undefined) root.uptimeColor = root.onColorSetting(data.colorUp, root.uptimeColor)
    if (data.colorKey !== undefined) root.typingColor = root.onColorSetting(data.colorKey, root.typingColor)
    if (data.colorPres !== undefined) root.presenceColor = root.onColorSetting(data.colorPres, root.presenceColor)
    if (data.show24 !== undefined) root.show24 = !!data.show24
    if (data.show7 !== undefined) root.show7 = !!data.show7
    if (data.show30 !== undefined) root.show30 = !!data.show30
    if (data.showUp !== undefined) root.showUptimeLine = !!data.showUp
    if (data.showKey !== undefined) root.showKeyboardLine = !!data.showKey
    if (data.showPres !== undefined) root.showScreenLine = !!data.showPres
    if (data.solid !== undefined) root.solidBackground = !!data.solid
    if (data.icon !== undefined) root.showIcon = !!data.icon
    root.tick()
  }

  // Saved color values may be a hex string (current) or a legacy palette
  // index (number); resolve both to a color.
  function onColorSetting(v, fallback) {
    if (typeof v === "number") {
      var hex = root.legacyPalette[root.modIndex(v, root.legacyPalette.length)]
      return hex ? hex : fallback
    }
    return String(v)
  }

  function settingsJson() {
    return JSON.stringify({
      version: 2,
      mode: root.mode,
      suffix: root.suffix,
      threshold: root.thresholdIndex,
      colorUp: root.uptimeColor.toString(),
      colorKey: root.typingColor.toString(),
      colorPres: root.presenceColor.toString(),
      show24: root.show24,
      show7: root.show7,
      show30: root.show30,
      showUp: root.showUptimeLine,
      showKey: root.showKeyboardLine,
      showPres: root.showScreenLine,
      solid: root.solidBackground,
      icon: root.showIcon
    }, null, 2) + "\n"
  }

  function scheduleSettingsSave() { saveSettingsTimer.restart() }

  FileView {
    id: settingsFile
    path: root.settingsFilePath
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSettings(text())
    onLoadFailed: root.loadSettings("")
  }

  Timer {
    id: saveSettingsTimer
    interval: 150
    repeat: false
    onTriggered: settingsFile.setText(root.settingsJson())
  }

  function groupDigits(n) {
    var s = String(n)
    var out = ""
    for (var i = 0; i < s.length; i++) {
      var r = s.length - i
      if (i > 0 && r % 3 === 0) out += ","
      out += s[i]
    }
    return out
  }

  // ---- uptime formatting ----
  function formatDays(seconds) {
    var s = Math.floor(seconds)
    var days = Math.floor(s / 86400)
    var hours = Math.floor((s % 86400) / 3600)
    var mins = Math.floor((s % 3600) / 60)
    if (days > 0) return days + "d " + hours + "h " + mins + "m"
    if (hours > 0) return hours + "h " + mins + "m"
    return mins + "m"
  }

  function formatBrief(seconds) {
    var total = Number(seconds) || 0
    switch (root.mode) {
      case 0: return root.formatDays(total)
      case 1: return root.groupDigits(Math.floor(total / 60)) + "m"
      case 2: return root.groupDigits(Math.floor(total)) + "s"
      case 3: return root.groupDigits(Math.floor(total * 1000)) + "ms"
    }
    return ""
  }

  // Compact duration for graph totals and tooltips: "3d 4h", "5h 30m",
  // "45m", "12s".
  function fmtSeconds(s) {
    var t = Math.max(0, Math.floor(Number(s) || 0))
    var d = Math.floor(t / 86400)
    var h = Math.floor((t % 86400) / 3600)
    var m = Math.floor((t % 3600) / 60)
    if (d > 0) return d + "d " + h + "h"
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m"
    return t + "s"
  }

  // ---- uptime data ----
  function refreshUptime() {
    uptimeReadProc.running = false
    uptimeReadProc.running = true
  }

  function applyUptime(line) {
    var parts = String(line).trim().split(" ")
    var up = Math.floor(parseFloat(parts[0]) * 1000) / 1000
    if (isNaN(up)) return
    root.baseSeconds = up
    root.baseTimeMs = Date.now()
    root.tick()
  }

  function chooseMode(i) {
    root.mode = ((Math.round(i) % root.modeCount) + root.modeCount) % root.modeCount
    root.tick()
    root.scheduleSettingsSave()
    if (root.bar) root.bar.showTooltip(root, root.tooltipBody())
  }

  function chooseSuffix(i) {
    root.suffix = ((Math.round(i) % root.suffixCount) + root.suffixCount) % root.suffixCount
    root.tick()
    root.scheduleSettingsSave()
    if (root.bar) root.bar.showTooltip(root, root.tooltipBody())
  }

  function chooseThreshold(i) {
    root.thresholdIndex = ((Math.round(i) % root.thresholdCount) + root.thresholdCount) % root.thresholdCount
    root.tick()
    root.scheduleSettingsSave()
    if (root.bar) root.bar.showTooltip(root, root.tooltipBody())
  }

  function toggleGraph(key) {
    if (key === "24h") root.show24 = !root.show24
    else if (key === "7d") root.show7 = !root.show7
    else if (key === "30d") root.show30 = !root.show30
    root.scheduleSettingsSave()
  }

  function graphChecked(key) {
    if (key === "24h") return root.show24
    if (key === "7d") return root.show7
    if (key === "30d") return root.show30
    return false
  }

  function setSeriesColor(which, c) {
    if (which === "up") root.uptimeColor = c
    else if (which === "key") root.typingColor = c
    else if (which === "pres") root.presenceColor = c
    root.scheduleSettingsSave()
  }

  function toggleSeries(key) {
    if (key === "up") root.showUptimeLine = !root.showUptimeLine
    else if (key === "key") root.showKeyboardLine = !root.showKeyboardLine
    else if (key === "pres") root.showScreenLine = !root.showScreenLine
    root.scheduleSettingsSave()
  }

  function seriesChecked(key) {
    if (key === "up") return root.showUptimeLine
    if (key === "key") return root.showKeyboardLine
    if (key === "pres") return root.showScreenLine
    return false
  }

  function toggleSolid() {
    root.solidBackground = !root.solidBackground
    root.scheduleSettingsSave()
  }

  function solidChecked() {
    return root.solidBackground
  }

  function toggleIcon() {
    root.showIcon = !root.showIcon
    root.scheduleSettingsSave()
  }

  function iconChecked() {
    return root.showIcon
  }

  // ---- clear saved activity data ----
  property bool clearArmed: false

  Timer {
    id: clearDisarm
    interval: 5000
    repeat: false
    onTriggered: root.clearArmed = false
  }

  function requestClear() {
    if (!root.clearArmed) {
      root.clearArmed = true
      clearDisarm.start()
      return
    }
    root.clearArmed = false
    clearDisarm.stop()
    if (!clearActivityProc.running) clearActivityProc.running = true
  }

  // ---- presentation ----
  function barText() {
    return root.formatBrief(root.upSeconds)
  }

  function tooltipBody() {
    var s = Number(root.upSeconds) || 0
    var lines = ["Uptime \u00b7 Click for activity panel"]
    lines.push("Uptime: " + root.formatDays(s))
    lines.push("")
    lines.push(root.groupDigits(Math.floor(s / 60)) + " total minutes")
    lines.push(root.groupDigits(Math.floor(s)) + " total seconds")
    lines.push(root.groupDigits(Math.floor(s * 1000)) + " total milliseconds")
    lines.push("")
    lines.push("Format \u00b7 " + root.modeNames[root.mode])
    lines.push("Suffix \u00b7 " + (root.suffixNames[root.suffix] === "" ? "(none)" : "\u201c" + root.suffixNames[root.suffix] + "\u201d"))
    lines.push("Threshold \u00b7 \u201c" + root.thresholdOptions[root.thresholdIndex].label + "\u201d")
    return lines.join("\n")
  }

  function tick() {
    root.upSeconds = root.baseSeconds + (Date.now() - root.baseTimeMs) / 1000
  }

  implicitWidth: Math.max(12, labelRow.implicitWidth + 16)
  implicitHeight: bar ? bar.barSize : 24

  Row {
    id: labelRow
    anchors.centerIn: parent
    spacing: 8
    leftPadding: 10

    Text {
      id: uptimeIcon
      text: "\uf06e"
      visible: root.showIcon
      color: bar ? bar.barForeground : Color.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      renderType: Text.NativeRendering
    }

    Text {
      id: suffixLabel
      text: root.suffixNames[root.suffix]
      visible: text !== ""
      color: bar ? bar.barForeground : Color.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      renderType: Text.NativeRendering
    }

    Text {
      id: label
      text: root.barText()
      color: bar ? bar.barForeground : Color.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.bar.iconFont
      renderType: Text.NativeRendering
    }
  }

  // Any click opens the activity panel; format is configured in the panel's
  // settings section rather than on the bar.
  MouseArea {
    id: mainArea
    anchors.fill: parent
    z: 5
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) { root.toggle() }
    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipBody())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  Process {
    id: uptimeReadProc
    command: ["cat", "/proc/uptime"]
    stdout: SplitParser {
      onRead: function(line) {
        root.applyUptime(line)
      }
    }
  }

  // Rebase every 60s to avoid accumulated drift.
  Timer {
    id: rebaseTimer
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshUptime()
  }

  // Smooth 1s tick for all formats except the sub-second modes.
  Timer {
    id: tickTimer
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.tick()
  }

  // Second/millisecond modes tick at 20Hz for a live feel.
  Timer {
    id: msTick
    interval: 50
    running: root.mode === 2 || root.mode === 3
    repeat: true
    onTriggered: root.tick()
  }

  Component.onCompleted: {
    root.refreshUptime()
  }

  // ---- graph data ----
  function parseGraphs(text) {
    try {
      var data = JSON.parse(text)
      if (data && data.windows) return data
    } catch (err) {}
    return null
  }

  function fetchGraphs() {
    graphsUptimeProc.running = false
    graphsUptimeProc.running = true
    graphsKeyboardProc.running = false
    graphsKeyboardProc.running = true
    graphsPresenceProc.running = false
    graphsPresenceProc.running = true
  }

  Process {
    id: graphsUptimeProc
    command: ["python3", Quickshell.env("HOME") + "/.config/omarchy/bar/scripts/activity-graphs", "--metric", "uptime"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.uptimeData = root.parseGraphs(text)
    }
  }

  Process {
    id: graphsKeyboardProc
    command: ["python3", Quickshell.env("HOME") + "/.config/omarchy/bar/scripts/activity-graphs", "--metric", "keyboard"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.keyboardData = root.parseGraphs(text)
    }
  }

  Process {
    id: graphsPresenceProc
    command: ["python3", Quickshell.env("HOME") + "/.config/omarchy/bar/scripts/activity-graphs", "--metric", "presence"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.presenceData = root.parseGraphs(text)
    }
  }

  // Wipe all saved activity history via the daemon's --clear request. Two
  // clicks arm-then-confirm so a stray press can't erase ~90 days of data.
  Process {
    id: clearActivityProc
    command: ["python3", Quickshell.env("HOME") + "/.config/omarchy/bar/scripts/activity-daemon", "--clear"]
  }

  onOpenedChanged: {
    if (root.opened) {
      root.fetchGraphs()
      pollTimer.start()
    } else {
      pollTimer.stop()
    }
  }

  Timer {
    id: pollTimer
    interval: 3000
    repeat: true
    triggeredOnStart: false
    onTriggered: root.fetchGraphs()
  }

  readonly property var upWindow24: root.uptimeData ? root.uptimeData.windows["24h"] : null
  readonly property var upWindow7: root.uptimeData ? root.uptimeData.windows["7d"] : null
  readonly property var upWindow30: root.uptimeData ? root.uptimeData.windows["30d"] : null
  readonly property var keyWindow24: root.keyboardData ? root.keyboardData.windows["24h"] : null
  readonly property var keyWindow7: root.keyboardData ? root.keyboardData.windows["7d"] : null
  readonly property var keyWindow30: root.keyboardData ? root.keyboardData.windows["30d"] : null
  readonly property var presWindow24: root.presenceData ? root.presenceData.windows["24h"] : null
  readonly property var presWindow7: root.presenceData ? root.presenceData.windows["7d"] : null
  readonly property var presWindow30: root.presenceData ? root.presenceData.windows["30d"] : null

  // ---- activity panel ----
  //
  // PopupCard owns the popup surface, the edge-aware anchoring, outside-click
  // dismissal and the popout coordination; this widget supplies the content
  // and its height. It is deliberately a PopupCard rather than a
  // KeyboardPanel: the activity panel has no text input and must not take
  // keyboard focus away from whatever you were typing in.

  PopupCard {
    id: panel
    anchorItem: labelRow
    owner: root
    bar: root.bar
    open: root.opened
    padding: root.panelMargin
    readonly property real contentMaxHeight: Math.max(
      Style.space(80),
      root.panelMaxHeight - root.panelMargin * 2 - hero.implicitHeight - Style.spacing.xs
    )
    contentWidth: panel.fittedContentWidth(Style.space(Math.round(300 * root.panelScale)))
    contentHeight: panel.cappedContentHeight(panelColumn.implicitHeight)

    Column {
      id: panelColumn
      width: parent.width
      spacing: Style.spacing.xs

      // ---- header + settings gear ----
      PanelHero {
        id: hero
        width: parent.width
        title: "Uptime"
        meta: "Uptime " + root.formatDays(root.upSeconds)
            + " \u00b7 typed " + (root.keyWindow24 ? root.keyWindow24.totalText : "\u2026")
            + " \u00b7 screen " + (root.presWindow24 ? root.presWindow24.totalText : "\u2026")
            + " in 24h"
        detail: ""
        foreground: Color.popups.text
        fontFamily: bar ? bar.fontFamily : Style.font.family
        iconComponent: Component {
          Row {
            leftPadding: 10
            Text {
              text: "\uf06e"
              color: Color.popups.text
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: root.displayPx
          }
        }
        }
        trailingControl: Component {
          Row {
            spacing: 2
            transform: Translate { x: -10 }

            Item {
              id: infoButton
              readonly property bool hovered: infoHover.hovered
              visible: root.settingsOpen
              width: root.captionPx + Style.spacing.sm
              height: root.titlePx

              Text {
                anchors.centerIn: parent
                text: "\uf05a"
                color: (infoButton.hovered || root.infoOpen) ? Color.popups.text : Util.alpha(Color.popups.text, 0.55)
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: root.captionPx
              }

              MouseArea {
                id: infoHover
                property bool hovered: false
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: infoHover.hovered = true
                onExited: infoHover.hovered = false
                onClicked: root.infoOpen = !root.infoOpen
              }
            }

            Item {
              id: gearButton
              readonly property bool hovered: gearHover.hovered
              width: root.captionPx + Style.spacing.sm
              height: root.titlePx

              Text {
                anchors.centerIn: parent
                text: "\uf013"
                color: (gearButton.hovered || root.settingsOpen) ? Color.popups.text : Util.alpha(Color.popups.text, 0.55)
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: root.captionPx
              }

              MouseArea {
                id: gearHover
                property bool hovered: false
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: gearHover.hovered = true
                onExited: gearHover.hovered = false
                onClicked: {
                  root.settingsOpen = !root.settingsOpen
                  if (!root.settingsOpen) root.infoOpen = false
                }
              }
            }
          }
        }
      }

      Flickable {
        id: scroller
        width: parent.width
        implicitHeight: Math.min(contentColumn.implicitHeight, panel.contentMaxHeight)
        height: implicitHeight
        contentWidth: width
        contentHeight: contentColumn.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height

        Column {
          id: contentColumn
          width: scroller.width
          spacing: Style.spacing.xs

          // ---- settings: format, suffix, threshold, series, colors ----
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.settingsOpen

            OptionPills {
              caption: "UPTIME"
              options: root.modeOptions
              current: root.mode
              onPicked: function(index) { root.chooseMode(index) }
            }

            OptionPills {
              caption: "SUFFIX"
              options: root.suffixOptions
              current: root.suffix
              onPicked: function(index) { root.chooseSuffix(index) }
            }

            OptionPills {
              caption: "THRESHOLD"
              options: root.thresholdOptions
              current: root.thresholdIndex
              onPicked: function(index) { root.chooseThreshold(index) }
            }

            Checklist {
              caption: "GRAPHS"
              options: [
                { key: "24h", label: "24h" },
                { key: "7d", label: "7d" },
                { key: "30d", label: "30d" }
              ]
              isChecked: root.graphChecked
              onToggled: function(key) { root.toggleGraph(key) }
            }

            Checklist {
              caption: "SHOW"
              options: [
                { key: "up", label: "Uptime" },
                { key: "key", label: "Keytime" },
                { key: "pres", label: "Screentime" }
              ]
              isChecked: root.seriesChecked
              onToggled: function(key) { root.toggleSeries(key) }
            }

            Checklist {
              caption: "PANEL BG"
              options: [ { key: "solid", label: "Solid" } ]
              isChecked: root.solidChecked
              onToggled: function(key) { root.toggleSolid() }
            }

            Checklist {
              caption: "ICON"
              options: [ { key: "icon", label: "Show" } ]
              isChecked: root.iconChecked
              onToggled: function(key) { root.toggleIcon() }
            }

            ColorPicker {
              caption: "UPTIME"
              value: root.uptimeColor
              onPicked: function(c) { root.setSeriesColor("up", c) }
            }

            ColorPicker {
              caption: "TYPING"
              value: root.typingColor
              onPicked: function(c) { root.setSeriesColor("key", c) }
            }

            ColorPicker {
              caption: "SCREEN TIME"
              value: root.presenceColor
              onPicked: function(c) { root.setSeriesColor("pres", c) }
            }

            Item { width: parent.width; height: 5 }

            Item {
              width: parent.width
              height: Style.spacing.controlHeight

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(Math.round(84 * root.panelScale))
                text: "DATA"
                color: Util.alpha(Color.popups.text, 0.7)
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: root.captionPx
                font.letterSpacing: 1
              }

              Button {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.clearArmed ? "Press again to confirm" : "Clear activity data"
                fontSize: root.captionPx
                foreground: Color.popups.text
                bordered: true
                horizontalPadding: Style.space(8)
                verticalPadding: Style.space(3)
                tooltipText: "Erase all saved graphs history (uptime, keytime, screentime)"
                onClicked: root.requestClear()
              }
            }
          }

          // ---- HOW IT WORKS (info view) ----
          Column {
            width: parent.width
            spacing: Style.spacing.xl
            visible: root.infoOpen

            SectionLabel { text: "HOW IT WORKS" }

            Text {
              width: parent.width
              text: "Uptime is how long the machine has been running since it was last started."
              color: Util.alpha(Color.popups.text, 0.8)
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: root.captionPx
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Keyboard time is the time you actually spent typing. A key press starts the timer, and it gets 60 seconds of grace so brief pauses don't end it. The activity log contains only timestamps — never what you typed — and is encrypted on disk with a key only your account can read, so the record stays private even if the file is copied elsewhere."
              color: Util.alpha(Color.popups.text, 0.8)
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: root.captionPx
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "Screen time is an estimate of how long you were sitting at the computer. By comparing two low-resolution images taken every ten seconds, the app works out whether you're there. Nothing is saved or recorded except the timestamps themselves, written to the same encrypted log; no images ever touch disk. After two minutes with no movement, the session ends."
              color: Util.alpha(Color.popups.text, 0.8)
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: root.captionPx
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              text: "No data is gathered unless you ask for it. Turning off Keytime or Screentime in the settings stops that data being collected at all — no keys are read and the webcam is not used. Turning it back on resumes collection from then on."
              color: Util.alpha(Color.popups.text, 0.8)
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: root.captionPx
              wrapMode: Text.WordWrap
            }
          }

          // ---- uptime + typing + screen time line graphs ----
          Column {
            width: parent.width
            spacing: Style.spacing.xs
            visible: !root.settingsOpen && !root.infoOpen

            PanelSeparator { foreground: Color.popups.text }

            SectionLabel { text: "ACTIVITY" }

            ActivityChart {
              title: "Last 24 hours"
              visible: root.show24
              upWindow: root.upWindow24
              keyWindow: root.keyWindow24
              presWindow: root.presWindow24
              upColor: root.uptimeColor
              keyColor: root.typingColor
              presColor: root.presenceColor
              showUp: root.showUptimeLine
              showKey: root.showKeyboardLine
              showPres: root.showScreenLine
              thresholdSecs: root.thresholdSecs
            }

            Item { width: parent.width; height: 15; visible: root.show24 && root.show7 }

            ActivityChart {
              title: "Last 7 days"
              visible: root.show7
              upWindow: root.upWindow7
              keyWindow: root.keyWindow7
              presWindow: root.presWindow7
              upColor: root.uptimeColor
              keyColor: root.typingColor
              presColor: root.presenceColor
              showUp: root.showUptimeLine
              showKey: root.showKeyboardLine
              showPres: root.showScreenLine
              thresholdSecs: root.thresholdSecs
            }

            Item { width: parent.width; height: 15; visible: root.show7 && root.show30 }

            ActivityChart {
              title: "Last 30 days"
              visible: root.show30
              upWindow: root.upWindow30
              keyWindow: root.keyWindow30
              presWindow: root.presWindow30
              upColor: root.uptimeColor
              keyColor: root.typingColor
              presColor: root.presenceColor
              showUp: root.showUptimeLine
              showKey: root.showKeyboardLine
              showPres: root.showScreenLine
              thresholdSecs: root.thresholdSecs
            }
          }
        }

        // Thin themed scrollbar, shown only when the content overflows.
        Item {
          id: scrollbar
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: Style.space(4)
          visible: scroller.contentHeight > scroller.height

          Rectangle {
            anchors.fill: parent
            radius: width / 2
            color: Util.alpha(Color.popups.text, 0.10)
          }

          Rectangle {
            width: parent.width
            radius: width / 2
            color: Util.alpha(Color.popups.text, 0.35)
            readonly property real ratio: scroller.visibleArea.heightRatio
            height: Math.max(Style.space(10), scroller.height * ratio)
            y: scroller.height * scroller.visibleArea.yPosition
          }
        }
      }
    }
  }

  component SectionLabel: Text {
    id: section
    width: parent ? parent.width : 0
    text: ""
    color: Util.alpha(Color.popups.text, 0.65)
    font.family: bar ? bar.fontFamily : Style.font.family
    font.pixelSize: root.captionPx
    font.letterSpacing: 1
    font.bold: true
    horizontalAlignment: Text.AlignLeft
    leftPadding: Style.spacing.xxs
  }

  // One entry of the per-series legend: a colored swatch plus a value.
  component SeriesLegend: Item {
    id: legend
    required property color color
    required property string text
    required property bool highlighted

    implicitWidth: swatch.width + Style.spacing.xxs + valueText.implicitWidth
    implicitHeight: Math.max(swatch.height, valueText.implicitHeight)
    width: implicitWidth
    height: implicitHeight

    Rectangle {
      id: swatch
      width: 9
      height: 3
      radius: Math.min(1.5, height / 2)
      color: legend.color
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: valueText
      anchors.left: swatch.right
      anchors.leftMargin: Style.spacing.xxs
      anchors.verticalCenter: parent.verticalCenter
      text: legend.text
      color: legend.highlighted ? legend.color : Color.popups.text
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: root.captionPx
      font.bold: legend.highlighted
    }
  }

  // Multi-select checkbox row for the settings section. options is
  // [{key, label}], isChecked(key) reports the current state and toggled(key)
  // fires on click.
  component Checklist: Item {
    id: checklist
    required property string caption
    required property var options
    property var isChecked: null
    signal toggled(string key)

    implicitWidth: parent ? parent.width : 0
    implicitHeight: Math.max(capText.implicitHeight, checkRow.height)
    width: implicitWidth

    function isOn(key) {
      return checklist.isChecked ? !!checklist.isChecked(key) : false
    }

    Text {
      id: capText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(Math.round(84 * root.panelScale))
      text: checklist.caption
      color: Util.alpha(Color.popups.text, 0.7)
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: root.captionPx
      font.letterSpacing: 1
    }

    Flow {
      id: checkRow
      anchors.left: capText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: 6

      Repeater {
        model: checklist.options

        Item {
          id: checkItem
          required property var modelData
          readonly property bool on: checklist.isOn(checkItem.modelData.key)
          width: innerRow.implicitWidth + Style.spacing.md * 2
          height: Style.spacing.controlHeight
          implicitHeight: height

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: checkItem.on
              ? Util.alpha(Color.accent, 0.28)
              : (checkHover.containsMouse ? Util.alpha(Color.popups.text, 0.08) : "transparent")
            border.width: checkItem.on ? 1 : 0
            border.color: Util.alpha(Color.accent, 0.7)
          }

          Row {
            id: innerRow
            anchors.centerIn: parent
            spacing: 5

            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              width: 12
              height: 12
              radius: 2
              color: checkItem.on ? Util.alpha(Color.accent, 0.3) : "transparent"
              border.width: 1
              border.color: checkItem.on ? Util.alpha(Color.accent, 0.85) : Util.alpha(Color.popups.text, 0.5)

              Text {
                anchors.centerIn: parent
                visible: checkItem.on
                text: "\uf00c"
                color: Color.accent
                font.family: bar ? bar.fontFamily : Style.font.family
                font.pixelSize: Math.max(1, root.captionPx - 3)
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: checkItem.modelData.label
              color: checkItem.on ? Color.accent : Util.alpha(Color.popups.text, 0.75)
              font.family: bar ? bar.fontFamily : Style.font.family
              font.pixelSize: root.captionPx
            }
          }

          MouseArea {
            id: checkHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: checklist.toggled(checkItem.modelData.key)
          }
        }
      }
    }
  }

  // Graduated HSV color picker: a saturation/value square over a continuous
  // hue strip. value is the current color; picked(color) fires while dragging.
  component ColorPicker: Item {
    id: picker
    required property string caption
    required property color value
    signal picked(color color)

    property real hue: value.hsvHue >= 0 ? value.hsvHue : 0
    property real sat: value.hsvSaturation
    property real val: value.hsvValue
    readonly property real knob: Math.max(6, Math.round(9 * root.panelScale))
    readonly property real edgePad: 10

    onValueChanged: {
      picker.sat = value.hsvSaturation
      picker.val = value.hsvValue
      if (value.hsvHue >= 0) picker.hue = value.hsvHue
    }

    function commit() {
      picker.picked(Qt.hsva(picker.hue, picker.sat, picker.val, 1))
    }
    function setSV(px, py) {
      picker.sat = Math.max(0, Math.min(1, px / Math.max(1, svArea.width)))
      picker.val = Math.max(0, Math.min(1, 1 - py / Math.max(1, svArea.height)))
      picker.commit()
    }
    function setHue(px) {
      picker.hue = Math.max(0, Math.min(0.9999, px / Math.max(1, hueArea.width)))
      picker.commit()
    }

    implicitWidth: parent ? parent.width : 0
    implicitHeight: Math.max(capText.implicitHeight, pickerColumn.height)
    width: implicitWidth

    Text {
      id: capText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(Math.round(84 * root.panelScale))
      text: picker.caption
      color: Util.alpha(Color.popups.text, 0.7)
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: root.captionPx
      font.letterSpacing: 1
    }

    Column {
      id: pickerColumn
      anchors.left: capText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: parent.right
      anchors.rightMargin: picker.edgePad
      anchors.verticalCenter: parent.verticalCenter
      spacing: 4

      // saturation (x) / value (y) area
      Item {
        id: svArea
        width: parent.width
        height: Math.round(23 * root.panelScale)

        Canvas {
          anchors.fill: parent
          property color hueColor: Qt.hsva(picker.hue, 1, 1, 1)
          onHueColorChanged: requestPaint()
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            ctx.fillStyle = hueColor
            ctx.fillRect(0, 0, width, height)
            var gs = ctx.createLinearGradient(0, 0, width, 0)
            gs.addColorStop(0, "rgba(255,255,255,1)")
            gs.addColorStop(1, "rgba(255,255,255,0)")
            ctx.fillStyle = gs
            ctx.fillRect(0, 0, width, height)
            var gv = ctx.createLinearGradient(0, 0, 0, height)
            gv.addColorStop(0, "rgba(0,0,0,0)")
            gv.addColorStop(1, "rgba(0,0,0,1)")
            ctx.fillStyle = gv
            ctx.fillRect(0, 0, width, height)
          }
        }

        Rectangle {
          width: picker.knob
          height: picker.knob
          radius: width / 2
          color: "transparent"
          border.width: 2
          border.color: "white"
          x: Math.round(picker.sat * (svArea.width - width))
          y: Math.round((1 - picker.val) * (svArea.height - height))
          Rectangle {
            anchors.centerIn: parent
            width: parent.width + 2
            height: parent.height + 2
            radius: width / 2
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(0, 0, 0, 0.55)
            z: -1
          }
        }

        MouseArea {
          anchors.fill: parent
          onPressed: function(mouse) { picker.setSV(mouse.x, mouse.y) }
          onPositionChanged: function(mouse) { if (pressed) picker.setSV(mouse.x, mouse.y) }
        }
      }

      // continuous hue strip
      Item {
        id: hueArea
        width: parent.width
        height: Math.round(6 * root.panelScale)

        Canvas {
          anchors.fill: parent
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            var g = ctx.createLinearGradient(0, 0, width, 0)
            for (var i = 0; i <= 6; i++)
              g.addColorStop(i / 6, Qt.hsva(i / 6, 1, 1, 1).toString())
            ctx.fillStyle = g
            ctx.fillRect(0, 0, width, height)
          }
        }

        Rectangle {
          width: Math.max(4, Math.round(10 * root.panelScale))
          height: parent.height + 4
          anchors.verticalCenter: parent.verticalCenter
          x: Math.max(0, Math.min(hueArea.width - width,
                Math.round(picker.hue * hueArea.width - width / 2)))
          radius: 2
          color: "transparent"
          border.width: 2
          border.color: "white"
        }

        MouseArea {
          anchors.fill: parent
          onPressed: function(mouse) { picker.setHue(mouse.x) }
          onPositionChanged: function(mouse) { if (pressed) picker.setHue(mouse.x) }
        }
      }
    }
  }

  // A window of uptime, typing and screen time buckets drawn as overlaid line
  // graphs with a totals/legend header and a sparse time axis. Each series is
  // scaled to its own peak so all shapes stay readable; the header shows real
  // totals.
  component ActivityChart: Item {
    id: chart
    required property string title
    required property var upWindow       // null until the first poll lands
    required property var keyWindow
    required property var presWindow
    required property color upColor
    required property color keyColor
    required property color presColor
    required property real thresholdSecs
    property bool showUp: true
    property bool showKey: true
    property bool showPres: true
    property real trackHeight: Math.round(34 * 1.1 * 1.2 * root.panelScale)
    property real padTop: Math.round(4 * root.panelScale)
    property real padBottom: Math.round(3 * root.panelScale)

    implicitWidth: parent ? parent.width : 0
    implicitHeight: header.height + track.height + axis.height + Style.spacing.xs * 2
    width: implicitWidth

    readonly property int upCount: chart.upWindow && chart.upWindow.buckets ? chart.upWindow.buckets.length : 0
    readonly property int keyCount: chart.keyWindow && chart.keyWindow.buckets ? chart.keyWindow.buckets.length : 0
    readonly property int presCount: chart.presWindow && chart.presWindow.buckets ? chart.presWindow.buckets.length : 0
    readonly property int bucketCount: Math.max(chart.upCount, Math.max(chart.keyCount, chart.presCount))
    readonly property real maxUpSecs: chart.upWindow ? Math.max(1, Number(chart.upWindow.max || 1)) : 1
    readonly property real maxKeySecs: chart.keyWindow ? Math.max(1, Number(chart.keyWindow.max || 1)) : 1
    readonly property real maxPresSecs: chart.presWindow ? Math.max(1, Number(chart.presWindow.max || 1)) : 1
    readonly property real slot: width / Math.max(1, chart.bucketCount)
    readonly property var axisWindow: chart.upWindow || chart.keyWindow || chart.presWindow
    readonly property int bucketSeconds: chart.axisWindow ? Number(chart.axisWindow.bucketSeconds || 0) : 0

    property int hoverIndex: -1
    readonly property var hoverUp: chart.hoverIndex >= 0 && chart.upWindow && chart.upWindow.buckets
      ? chart.upWindow.buckets[Math.min(chart.hoverIndex, chart.upWindow.buckets.length - 1)] : null
    readonly property var hoverKey: chart.hoverIndex >= 0 && chart.keyWindow && chart.keyWindow.buckets
      ? chart.keyWindow.buckets[Math.min(chart.hoverIndex, chart.keyWindow.buckets.length - 1)] : null
    readonly property var hoverPres: chart.hoverIndex >= 0 && chart.presWindow && chart.presWindow.buckets
      ? chart.presWindow.buckets[Math.min(chart.hoverIndex, chart.presWindow.buckets.length - 1)] : null

    // Bucket label for the hover readout: "HH:00" for hourly windows, or a
    // "Wed 12"-style day label when buckets span days. Mirrors the axis
    // labels the activity-graphs script emits.
    function bucketLabel(bucket) {
      if (!bucket) return ""
      var d = new Date(Number(bucket.start) * 1000)
      if (chart.bucketSeconds === 86400) {
        var days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        return days[d.getDay()] + " " + d.getDate()
      }
      var h = d.getHours()
      return (h < 10 ? "0" : "") + h + ":00"
    }

    function yFor(seconds, max) {
      var usable = track.height - chart.padTop - chart.padBottom
      return track.height - chart.padBottom - (Math.max(0, Number(seconds)) / max) * usable
    }

    function drawLine(ctx, buckets, max, color) {
      if (!buckets || buckets.length < 2) return
      var n = buckets.length
      ctx.strokeStyle = color
      ctx.lineWidth = 1.8
      ctx.lineJoin = "round"
      ctx.lineCap = "round"
      ctx.beginPath()
      for (var i = 0; i < n; i++) {
        var x = (i + 0.5) * chart.slot
        var y = chart.yFor(buckets[i].seconds, max)
        if (i === 0) ctx.moveTo(x, y)
        else ctx.lineTo(x, y)
      }
      ctx.stroke()
    }

    // Red informational line at the configured threshold, on the uptime
    // scale. Clamped to the track so a level above the current peak still
    // reads as "maxed out".
    function drawThreshold(ctx) {
      if (chart.thresholdSecs <= 0) return
      var usable = track.height - chart.padTop - chart.padBottom
      var y = track.height - chart.padBottom - (chart.thresholdSecs / chart.maxUpSecs) * usable
      y = Math.max(chart.padTop, Math.min(track.height - chart.padBottom, y))
      ctx.save()
      ctx.strokeStyle = root.thresholdColor
      ctx.globalAlpha = 0.9
      ctx.lineWidth = 1
      ctx.setLineDash([2, 3])
      ctx.beginPath()
      ctx.moveTo(0, y)
      ctx.lineTo(width, y)
      ctx.stroke()
      ctx.setLineDash([])
      ctx.restore()
    }

    Column {
      anchors.fill: parent
      spacing: Style.spacing.xs

      // ---- header: title + per-series legend/totals (or hovered bucket) ----
      Item {
        id: header
        width: parent.width
        height: Math.max(titleText.implicitHeight, legendRow.height)

        Text {
          id: titleText
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          width: parent.width - legendRow.width - Style.spacing.sm
          elide: Text.ElideRight
          text: chart.title
          color: Util.alpha(Color.popups.text, 0.6)
          font.family: bar ? bar.fontFamily : Style.font.family
          font.pixelSize: root.captionPx
          font.letterSpacing: 1
          font.bold: true
        }

        Row {
          id: legendRow
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          SeriesLegend {
            color: chart.upColor
            visible: chart.showUp
            highlighted: chart.hoverUp !== null
            text: chart.hoverUp
              ? chart.bucketLabel(chart.hoverUp) + " \u00b7 Uptime " + root.fmtSeconds(chart.hoverUp.seconds)
              : (chart.upWindow ? "Uptime " + String(chart.upWindow.totalText) : "\u2026")
          }

          SeriesLegend {
            color: chart.keyColor
            visible: chart.showKey
            highlighted: chart.hoverKey !== null
            text: chart.hoverKey
              ? "Key " + root.fmtSeconds(chart.hoverKey.seconds)
              : (chart.keyWindow ? "Key " + String(chart.keyWindow.totalText) : "\u2026")
          }

          SeriesLegend {
            color: chart.presColor
            visible: chart.showPres
            highlighted: chart.hoverPres !== null
            text: chart.hoverPres
              ? "Screen " + root.fmtSeconds(chart.hoverPres.seconds)
              : (chart.presWindow ? "Screen " + String(chart.presWindow.totalText) : "\u2026")
          }

          SeriesLegend {
            color: root.thresholdColor
            highlighted: false
            text: "Thres " + Math.round(chart.thresholdSecs / 3600) + "h"
            visible: chart.thresholdSecs > 0
          }
        }
      }

      // ---- lines ----
      Item {
        id: track
        width: parent.width
        height: chart.trackHeight

        Canvas {
          id: lineCanvas
          anchors.fill: parent
          onPaint: {
            var ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            if (chart.bucketCount > 1) {
              if (chart.showUp) chart.drawLine(ctx, chart.upWindow && chart.upWindow.buckets, chart.maxUpSecs, chart.upColor)
              if (chart.showKey) chart.drawLine(ctx, chart.keyWindow && chart.keyWindow.buckets, chart.maxKeySecs, chart.keyColor)
              if (chart.showPres) chart.drawLine(ctx, chart.presWindow && chart.presWindow.buckets, chart.maxPresSecs, chart.presColor)
              chart.drawThreshold(ctx)
            }
          }
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
        }

        MouseArea {
          id: trackMouse
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.NoButton
          onPositionChanged: function(mouse) {
            if (chart.bucketCount === 0) return
            var i = Math.floor(mouse.x / chart.slot)
            chart.hoverIndex = Math.max(0, Math.min(chart.bucketCount - 1, i))
          }
          onExited: chart.hoverIndex = -1
        }
      }

      // ---- sparse time axis ----
      Item {
        id: axis
        width: parent.width
        height: Math.max(1, Math.round(root.captionPx * 1.35))
        clip: true

        Repeater {
          model: chart.axisWindow && chart.axisWindow.axisLabels ? chart.axisWindow.axisLabels : []

          Text {
            required property var modelData
            readonly property real slot: chart.slot
            width: slot
            x: Math.round(modelData.at * slot)
            verticalAlignment: Text.AlignTop
            text: modelData.label
            color: Util.alpha(Color.popups.text, 0.45)
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: root.captionPx
          }
        }
      }
    }

    onUpWindowChanged: if (lineCanvas) lineCanvas.requestPaint()
    onKeyWindowChanged: if (lineCanvas) lineCanvas.requestPaint()
    onPresWindowChanged: if (lineCanvas) lineCanvas.requestPaint()
    onThresholdSecsChanged: if (lineCanvas) lineCanvas.requestPaint()
    onTrackHeightChanged: if (lineCanvas) lineCanvas.requestPaint()
  }

  // Segmented picker row; options is [{label, tip}], current is the active
  // index, picked(index) fires on click.
  component OptionPills: Item {
    id: pills
    required property string caption
    required property var options
    required property int current
    signal picked(int index)

    implicitWidth: parent ? parent.width : 0
    implicitHeight: Math.max(capText.implicitHeight, pillsRow.height)
    width: implicitWidth

    Text {
      id: capText
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(Math.round(84 * root.panelScale))
      text: pills.caption
      color: Util.alpha(Color.popups.text, 0.7)
      font.family: bar ? bar.fontFamily : Style.font.family
      font.pixelSize: root.captionPx
      font.letterSpacing: 1
    }

    Row {
      id: pillsRow
      anchors.left: capText.right
      anchors.leftMargin: Style.spacing.sm
      anchors.right: parent.right
      spacing: 4

      Repeater {
        model: pills.options

        Item {
          required property var modelData
          required property int index

          readonly property bool active: index === pills.current
          width: (pillsRow.width - pillsRow.spacing * (pills.options.length - 1)) / pills.options.length
          height: Style.spacing.controlHeight
          implicitHeight: height

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: parent.active
              ? Util.alpha(Color.accent, 0.28)
              : (pillHover.containsMouse ? Util.alpha(Color.popups.text, 0.08) : "transparent")
            border.width: parent.active ? 1 : 0
            border.color: Util.alpha(Color.accent, 0.7)
          }

          Text {
            anchors.centerIn: parent
            text: modelData.label
            color: parent.active ? Color.accent : Util.alpha(Color.popups.text, 0.75)
            font.family: bar ? bar.fontFamily : Style.font.family
            font.pixelSize: root.captionPx
          }

          MouseArea {
            id: pillHover
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: pills.picked(index)
          }

          PanelToolTip {
            visible: pillHover.containsMouse
            text: modelData.tip
            fontFamily: bar ? bar.fontFamily : Style.font.family
          }
        }
      }
    }
  }

}