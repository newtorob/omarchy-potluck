import QtQuick

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
  function fetchJson(path, onOk, onFail) {
    var xhr = new XMLHttpRequest()
    xhr.onreadystatechange = function () {
      if (xhr.readyState !== XMLHttpRequest.DONE) return
      if (xhr.status === 200) {
        try {
          onOk(JSON.parse(xhr.responseText))
          return
        } catch (e) {
          // fall through to onFail
        }
      }
      if (onFail) onFail()
    }
    try {
      xhr.open("GET", root.sidecarUrl + path)
      xhr.send()
    } catch (e) {
      if (onFail) onFail()
    }
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
    fetchJson("/health", function (h) {
      root.online = true
      root.modelLoaded = h.model_loaded === true
      root.nCtx = h.n_ctx_loaded ? Number(h.n_ctx_loaded) : 0

      var id = h.active_model_id ? String(h.active_model_id) : ""
      if (id !== root.activeModelId) {
        root.activeModelId = id
        root.modelName = ""
        // The catalog is the only place the human-readable name lives, so it
        // is fetched on change rather than on every tick.
        if (id !== "") root.refreshCatalog()
      }
      if (root.installedCount === 0) root.refreshCatalog()

      root.refreshHardware()
    }, root.goOffline)
  }

  function refreshCatalog() {
    fetchJson("/models", function (d) {
      var models = Array.isArray(d) ? d : (d && d.models ? d.models : [])
      var installed = 0
      var bytes = 0
      for (var i = 0; i < models.length; i++) {
        var m = models[i]
        if (m.installed === true) {
          installed++
          bytes += Number(m.size_on_disk || m.size_bytes || 0)
        }
        if (m.slug === root.activeModelId && m.name) root.modelName = String(m.name)
      }
      root.installedCount = installed
      root.installedBytes = bytes
    })
  }

  function refreshHardware() {
    fetchJson("/hardware", function (hw) {
      root.ramAvailableGb = Number(hw.ram_available_gb || 0)
      root.ramTotalGb = Number(hw.ram_total_gb || 0)
      root.gpuName = hw.gpu_name ? String(hw.gpu_name) : ""
    })
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
