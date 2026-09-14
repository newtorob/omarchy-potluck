import QtQuick
import Quickshell
import Quickshell.Io

// Potluck bar widget.
//
// Reads the Potluck desktop app's local Python sidecar over loopback and
// renders one pill: a status dot plus the loaded model's name. Everything it
// shows already lives on this machine -- the sidecar is the same process the
// app itself talks to, so this adds no network exposure of its own.
//
// Only /health is asked of the sidecar. A packaged Potluck locks every other
// route behind a per-launch token that only the app holds, so the rest of
// what the pill shows (installed models, the loaded model's name, free RAM,
// whether the local API is on) is read from the app's own files on disk.
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
  readonly property string clickAction: (settings && settings.clickAction)
    ? String(settings.clickAction)
    : "Ask overlay"

  // ---- observed state ----
  property bool online: false
  property bool modelLoaded: false
  property string activeModelId: ""
  property string modelName: ""
  property int nCtx: 0
  property real ramAvailableGb: 0
  property real ramTotalGb: 0
  property int installedCount: 0
  property real installedBytes: 0
  // Where the loaded model actually runs, from the sidecar's own load report
  // (/health `inference`). "unknown" until a llama.cpp model is loaded.
  property string deviceKind: "unknown"
  property string deviceName: ""
  property string backendName: ""
  property bool executionVerified: false
  // Whether the app's local API (the /v1 gateway) is switched on. The Ask
  // overlay needs it; the tooltip says so while it is off.
  property bool gatewayEnabled: false
  // Serve mode: the sidecar as a systemd user service, kept loaded at login.
  property bool serving: false

  // Anything on the sidecar port is untrusted: --max-time bounds how long a
  // response may take, not how large it may be, so every read is capped in
  // bytes by the OS before QML collects it, and every retained string is
  // clamped before it can reach a label or tooltip.
  readonly property int maxHealthBytes: 16384
  readonly property int maxLocalBytes: 4096
  readonly property int maxNameChars: 96
  readonly property string potluckDir: Quickshell.env("HOME") + "/.potluck"

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
  // `head -c` caps every body in the pipe, so a process squatting on the
  // sidecar port cannot make the long-lived shell buffer an arbitrarily large
  // response before it is parsed.
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
    deviceKind = "unknown"
    deviceName = ""
    backendName = ""
    executionVerified = false
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
    }

    // Where the model runs, as llama.cpp reported it during this exact load.
    // A missing block means "no llama.cpp model loaded", not "CPU".
    var inf = h.inference
    if (inf && typeof inf === "object") {
      root.deviceKind = root.clamp(inf.device_kind) || "unknown"
      root.deviceName = root.clamp(inf.device_name)
      root.backendName = root.clamp(inf.backend)
      root.executionVerified = inf.execution_verified === true
    } else {
      root.deviceKind = "unknown"
      root.deviceName = ""
      root.backendName = ""
      root.executionVerified = false
    }
    root.refreshLocal()
  }

  // Everything else the pill shows already lives on this machine as plain
  // files, so it is read from disk rather than asked of the sidecar. One
  // bounded process per tick, output capped before QML sees it.
  //   ~/.potluck/models/<slug>/model.gguf         installed models and size
  //   ~/.potluck/data/model_catalog_cache.json    the loaded model's name
  //   ~/.potluck/config.json                      whether the local API is on
  //   /proc/meminfo                               free RAM
  function refreshLocal() {
    localProc.environment = ({
      "POTLUCK_DIR": root.potluckDir,
      "POTLUCK_SLUG": root.activeModelId
    })
    localProc.running = true
  }

  function applyLocal(d) {
    var n = Number(d.models), b = Number(d.bytes)
    root.installedCount = isFinite(n) && n >= 0 ? Math.min(Math.floor(n), 500) : 0
    root.installedBytes = isFinite(b) && b >= 0 ? Math.min(b, 1e13) : 0
    var t = Number(d.memTotalKb), a = Number(d.memAvailKb)
    root.ramTotalGb = isFinite(t) && t > 0 ? Math.min(t, 1e12) / 1048576 : 0
    root.ramAvailableGb = isFinite(a) && a >= 0 ? Math.min(a, 1e12) / 1048576 : 0
    root.gatewayEnabled = d.gateway === true
    root.serving = d.serving === true
    var name = root.clamp(d.name)
    if (name !== "") root.modelName = name
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
    id: localProc
    // Shell metacharacters never reach this command line: the paths and the
    // slug travel as environment values, and every jq program takes them as
    // --arg variables. Reads refuse symlinks and are capped in bytes.
    command: ["bash", "-c",
      'd="$POTLUCK_DIR"; n=0; b=0;'
      + ' for f in "$d"/models/*/model.gguf; do [ -f "$f" ] || continue; n=$((n+1)); sz=$(stat -Lc %s "$f" 2>/dev/null || echo 0); b=$((b+sz)); done;'
      + ' t=$(awk "/^MemTotal:/{print \\$2; exit}" /proc/meminfo 2>/dev/null); a=$(awk "/^MemAvailable:/{print \\$2; exit}" /proc/meminfo 2>/dev/null);'
      + ' gw=false; c="$d/config.json"; if [ -f "$c" ] && [ ! -L "$c" ]; then gw=$(head -c 65536 "$c" | jq -r "if .gateway.enabled == true then true else false end" 2>/dev/null); fi;'
      + ' name=""; k="$d/data/model_catalog_cache.json"; if [ -n "$POTLUCK_SLUG" ] && [ -f "$k" ] && [ ! -L "$k" ]; then name=$(head -c 262144 "$k" | jq -r --arg s "$POTLUCK_SLUG" "[.models[]? | select(.slug == \\$s) | .name // empty] | first // \\"\\"" 2>/dev/null | head -c 96); fi;'
      + ' case "$gw" in true|false) ;; *) gw=false ;; esac;'
      + ' sv=false; systemctl --user is-active --quiet potluck-sidecar 2>/dev/null && sv=true;'
      + ' jq -cn --argjson n "$n" --argjson b "$b" --argjson t "${t:-0}" --argjson a "${a:-0}" --argjson gw "$gw" --argjson sv "$sv" --arg name "$name" "{models:\\$n, bytes:\\$b, memTotalKb:\\$t, memAvailKb:\\$a, gateway:\\$gw, serving:\\$sv, name:\\$name}"'
      + ' | head -c ' + root.maxLocalBytes]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var d = root.parseBounded(text, root.maxLocalBytes)
        if (d && typeof d === "object") root.applyLocal(d)
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

  // "Runs on GPU  ·  vulkan  ·  Intel(R) Graphics (MTL)". Only what llama.cpp
  // itself reported; "unverified" marks a load whose per-device buffers the
  // engine never showed, so the device is a claim rather than evidence.
  function runsOnText() {
    var where = deviceKind === "gpu" ? "GPU"
      : deviceKind === "mixed" ? "GPU + CPU"
      : deviceKind === "cpu" ? "CPU" : "unknown device"
    var s = "Runs on " + where
    if (backendName !== "" && backendName !== "cpu") s += "  ·  " + backendName
    if (deviceName !== "") s += "  ·  " + deviceName
    if (!executionVerified) s += "  (unverified)"
    return s
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  // The overlay is a second kind on this same plugin, but it is a separate
  // instance: the bar widget cannot call into it directly. Route through the
  // shell's own summon/hide IPC, which is the same path the keybinding takes,
  // so both entry points share one notion of whether the overlay is open.
  function toggleOverlay() {
    var id = root.moduleName !== "" ? root.moduleName : "newtorob.potluck"
    if (root.bar) root.bar.run("omarchy-shell shell toggle " + id)
  }

  function launchApp() {
    if (root.bar && root.launchCommand !== "") root.bar.run(root.launchCommand)
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
    if (modelLoaded && deviceKind !== "unknown")
      lines.push(runsOnText())
    if (ramTotalGb > 0)
      lines.push("RAM " + formatGb(ramAvailableGb) + " free of " + formatGb(ramTotalGb))
    if (serving)
      lines.push("Serve mode: kept loaded at login (potluck-sidecar user service)")
    if (!gatewayEnabled)
      lines.push("Ask needs the local API on: Potluck → Settings → Connect tools")
    lines.push(root.clickAction === "Launch app"
      ? "Click app  ·  right ask  ·  middle refresh"
      : "Click ask  ·  right app  ·  middle refresh")
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
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton

    onEntered: if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    onExited: if (root.bar) root.bar.hideTooltip(root)

    onClicked: function (mouse) {
      if (mouse.button === Qt.MiddleButton) {
        root.refresh()
        return
      }
      // Right-click is always the app, whatever left-click is bound to, so the
      // launch path never disappears behind a setting.
      if (mouse.button === Qt.RightButton) {
        root.launchApp()
        return
      }
      if (root.clickAction === "Launch app") root.launchApp()
      else root.toggleOverlay()
    }
  }
}
