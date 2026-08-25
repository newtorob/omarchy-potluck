import QtQuick
import Quickshell.Io

// Potluck bar widget.
//
// Reads the Potluck desktop app's local Python sidecar over loopback and
// renders one pill: a status dot plus the loaded model's name. Everything it
// shows already lives on this machine -- the sidecar is the same process the
// app itself talks to, so this adds no network exposure of its own.
//
// Third-party plugins get `bar`, `moduleName`, and `settings` injected by the
// bar after loading; see /usr/share/omarchy/shell/plugins/bar/README.md.
Item {
  id: root

  property var bar: null
  property string moduleName: "newtorob.potluck"
  property var settings: ({})

  // ---- settings, with the manifest defaults restated so the widget still
  // renders if it is loaded before the bar injects `settings`. ----
  readonly property string sidecarUrl: (settings && settings.sidecarUrl)
    ? String(settings.sidecarUrl).replace(/\/+$/, "")
    : "http://127.0.0.1:8321"
  readonly property int refreshIntervalSec: (settings && settings.refreshIntervalSec > 0)
    ? Math.max(2, Math.min(300, settings.refreshIntervalSec))
    : 10
  readonly property bool showModelName: (settings && settings.showModelName !== undefined)
    ? settings.showModelName === true
    : true
  readonly property string launchCommand: (settings && settings.launchCommand)
    ? String(settings.launchCommand)
    : "omarchy-launch-or-focus potluck-ai-desktop potluck-ai-desktop"

  // ---- observed state ----
  property bool online: false
  property bool modelLoaded: false
  property string activeModelId: ""
  property string modelName: ""
  property int nCtx: 0
  property real ramAvailableGb: 0
  property real ramTotalGb: 0
  property string gpuName: ""
  property int installedCount: 0
  property real installedBytes: 0

  // Anything on the sidecar port is untrusted: --max-time bounds how long a
  // response may take, not how large it may be, so every read is capped in
  // bytes by the OS before QML collects it, and every retained string is
  // clamped before it can reach a label or tooltip.
  readonly property int maxHealthBytes: 16384
  readonly property int maxHardwareBytes: 16384
  readonly property int maxCatalogBytes: 262144
  readonly property int maxNameChars: 96

  function clamp(v) { return String(v === undefined || v === null ? "" : v).substring(0, root.maxNameChars) }

  // A vertical bar has no room for a name, so the dot stands alone there
  // regardless of the setting.
  readonly property bool wantText: showModelName && !(bar && bar.vertical)

  readonly property color fg: bar ? bar.foreground : "white"
  readonly property color urgent: bar ? bar.urgent : "#e06c75"
  readonly property color okColor: Qt.rgba(fg.r, fg.g, fg.b, 1.0)

  readonly property string label: {
    if (!online) return "Potluck"
    if (!modelLoaded) return "No model"
    return modelName !== "" ? modelName : activeModelId
  }

  implicitWidth: Math.max(dotSize + 8, row.implicitWidth + 12)
  implicitHeight: bar ? bar.barSize : 26

  readonly property int dotSize: 8

  // -------------------------------------------------------------------------
  // Sidecar polling
  // -------------------------------------------------------------------------

  // Fire-and-forget JSON GET. Any failure (sidecar down, refused, malformed)
  // routes to onFail so a stopped app degrades to "offline" instead of
  // freezing the last-known values on screen.
  // One bounded reader per endpoint. `head -c` caps the body in the pipe, so a
  // process squatting on the sidecar port cannot make the long-lived shell
  // buffer an arbitrarily large response before it is parsed.
  function parseBounded(raw, cap) {
    var text = String(raw || "")
    if (text.length === 0 || text.length >= cap) return null
    try { return JSON.parse(text) } catch (e) { return null }
  }

  function fetchCommand(path, cap) {
    return ["bash", "-lc", 'curl -s --max-time 3 "$POTLUCK_URL" | head -c ' + cap]
  }

  function goOffline() {
    online = false
    modelLoaded = false
    activeModelId = ""
    modelName = ""
    nCtx = 0
    ramAvailableGb = 0
    ramTotalGb = 0
    gpuName = ""
  }

  function refresh() {
    healthProc.environment = ({ "POTLUCK_URL": root.sidecarUrl + "/health" })
    healthProc.command = root.fetchCommand("/health", root.maxHealthBytes)
    healthProc.running = true
  }

  function applyHealth(h) {
    root.online = true
    root.modelLoaded = h.model_loaded === true
    var ctx = Number(h.n_ctx_loaded)
    root.nCtx = isFinite(ctx) && ctx > 0 ? Math.min(Math.floor(ctx), 100000000) : 0

    var id = root.clamp(h.active_model_id)
    if (id !== root.activeModelId) {
      root.activeModelId = id
      root.modelName = ""
      // The catalog is the only place the human-readable name lives, so it is
      // fetched on change rather than on every tick.
      if (id !== "") root.refreshCatalog()
    }
    if (root.installedCount === 0) root.refreshCatalog()
    root.refreshHardware()
  }

  function refreshCatalog() {
    catalogProc.environment = ({ "POTLUCK_URL": root.sidecarUrl + "/models" })
    catalogProc.command = root.fetchCommand("/models", root.maxCatalogBytes)
    catalogProc.running = true
  }

  function refreshHardware() {
    hardwareProc.environment = ({ "POTLUCK_URL": root.sidecarUrl + "/hardware" })
    hardwareProc.command = root.fetchCommand("/hardware", root.maxHardwareBytes)
    hardwareProc.running = true
  }

  Process {
    id: healthProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var h = root.parseBounded(text, root.maxHealthBytes)
        if (h) root.applyHealth(h); else root.goOffline()
      }
    }
  }

  Process {
    id: catalogProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = root.parseBounded(text, root.maxCatalogBytes)
        if (!d) return
        var models = Array.isArray(d) ? d : (d && d.models ? d.models : [])
        var installed = 0, bytes = 0
        // Bounded independently of the byte cap: a valid but enormous catalog
        // must not turn into an unbounded loop or an absurd total.
        var limit = Math.min(models.length, 500)
        for (var i = 0; i < limit; i++) {
          var m = models[i]
          if (!m || typeof m !== "object") continue
          if (m.installed === true) {
            installed++
            var sz = Number(m.size_on_disk || m.size_bytes || 0)
            if (isFinite(sz) && sz > 0) bytes += Math.min(sz, 1e13)
          }
          if (m.slug === root.activeModelId && m.name) root.modelName = root.clamp(m.name)
        }
        root.installedCount = installed
        root.installedBytes = bytes
      }
    }
  }

  Process {
    id: hardwareProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var hw = root.parseBounded(text, root.maxHardwareBytes)
        if (!hw) return
        var avail = Number(hw.ram_available_gb), total = Number(hw.ram_total_gb)
        root.ramAvailableGb = isFinite(avail) && avail >= 0 ? Math.min(avail, 1e6) : 0
        root.ramTotalGb = isFinite(total) && total >= 0 ? Math.min(total, 1e6) : 0
        root.gpuName = root.clamp(hw.gpu_name)
      }
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // -------------------------------------------------------------------------
  // Tooltip
  // -------------------------------------------------------------------------

  function formatGb(v) {
    return (Math.round(v * 10) / 10).toFixed(1) + " GB"
  }

  function tooltipText() {
    if (!online)
      return "Potluck\nSidecar not running\n" + sidecarUrl

    var lines = ["Potluck"]
    if (modelLoaded) {
      lines.push((modelName !== "" ? modelName : activeModelId)
        + (nCtx > 0 ? "  ·  " + Math.round(nCtx / 1024) + "K ctx" : ""))
    } else {
      lines.push("No model loaded")
    }
    if (installedCount > 0) {
      lines.push(installedCount + (installedCount === 1 ? " model" : " models")
        + " installed  ·  " + formatGb(installedBytes / 1073741824))
    }
    if (ramTotalGb > 0)
      lines.push("RAM " + formatGb(ramAvailableGb) + " free of " + formatGb(ramTotalGb))
    if (gpuName !== "")
      lines.push("GPU " + gpuName)
    return lines.join("\n")
  }

  // -------------------------------------------------------------------------
  // Presentation
  // -------------------------------------------------------------------------

  Row {
    id: row
    anchors.centerIn: parent
    spacing: root.wantText ? 6 : 0

    Rectangle {
      id: dot
      width: root.dotSize
      height: root.dotSize
      radius: width / 2
      anchors.verticalCenter: parent.verticalCenter
      // Filled when a model is ready to serve; hollow when the sidecar is up
      // but idle; dim when there is nothing running at all.
      color: root.modelLoaded ? root.okColor : "transparent"
      border.width: root.modelLoaded ? 0 : 1
      border.color: root.online ? root.okColor : Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.35)
      opacity: root.online ? 1.0 : 0.5
    }

    Text {
      visible: root.wantText
      anchors.verticalCenter: parent.verticalCenter
      text: root.label
      color: root.fg
      opacity: root.online ? 1.0 : 0.5
      font.family: bar ? bar.fontFamily : "monospace"
      font.pixelSize: 12
      elide: Text.ElideRight
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton

    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    onExited: if (root.bar) root.bar.hideTooltip(root)

    onClicked: function (mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.refresh()
        return
      }
      if (root.bar && root.launchCommand !== "") root.bar.run(root.launchCommand)
    }
  }
}
