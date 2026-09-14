import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui

// Ask Potluck — a summoned overlay that streams an answer from the local
// model without opening the desktop app, plus a usage view over the asks made
// through it.
//
// It talks to the sidecar's OpenAI-compatible local API (/v1), the door
// Potluck opens for other programs on the machine (Settings → Connect tools),
// with the key from ~/.potluck/config.json. A packaged Potluck locks its
// internal routes behind a per-launch token that only the app holds, so /v1
// is the only route an outside caller can use. Every ask is sent with
// X-Potluck-Scope: local, so it runs on this machine or fails: it is never
// routed to a household peer or the pool, whatever the app's own default.
//
// Usage is measured here rather than read back from the sidecar: the local
// chat route persists no per-message token telemetry (only the cloud gateway
// path returns a `usage` block), so the only honest source for "what have I
// asked and how fast was it" is what this overlay observes as it streams.
Item {
  id: root

  property var shell: null
  property var manifest: null

  property bool opened: false
  property string mode: "ask"            // "ask" | "usage"

  readonly property string sidecarUrl: "http://127.0.0.1:8321"
  readonly property string statePath: Quickshell.env("HOME") + "/.local/state/omarchy-potluck/usage.json"
  readonly property string configPath: Quickshell.env("HOME") + "/.potluck/config.json"

  // ---- local API (gateway) state, from ~/.potluck/config.json ----
  property bool gatewayEnabled: false
  property string gatewayKey: ""
  property bool copied: false

  // ---- models view state, from GET /v1/potluck/models ----
  property var models: []          // [{slug, name, tier, size_bytes, size_on_disk, installed, loaded, download}]
  property string loadedSlug: ""
  property int cursor: 0
  onCursorChanged: modelsFlick.reveal(cursor)
  property string busySlug: ""     // a load or unload in flight
  property string busyAction: ""
  property string modelsError: ""
  property string modelsNotice: ""
  readonly property int maxModelsBytes: 262144
  readonly property int maxModels: 200
  // The overlay has no settings of its own, so the app command matches the
  // bar widget's default. Ctrl+O runs it from any view.
  readonly property string launchCommand: "omarchy-launch-or-focus potluck-ai-desktop potluck-ai-desktop"

  // ---- ask state ----
  property string prompt: ""
  property string thinking: ""
  property string answer: ""
  property bool streaming: false
  property bool inThink: false
  property string errorText: ""
  property string modelId: ""
  property int tokenCount: 0
  property double startedAt: 0
  property double elapsedMs: 0

  // ---- usage state ----
  property var history: []               // [{ts, model, prompt, tokens, ms}]

  // ---- hard limits -------------------------------------------------------
  // Everything below the sidecar boundary is untrusted: the model controls the
  // stream body, and usage.json is a plain user-writable file. Each limit is
  // enforced at the earliest point it can be, so nothing unbounded is ever
  // retained, buffered, or rendered.
  readonly property int maxStreamBytes: 262144   // OS-level cap on the whole response
  readonly property int maxLineChars: 16384      // one SSE event is tiny; this is generous
  readonly property int maxAnswerChars: 40000    // cap on what QML retains and renders
  readonly property int maxStateBytes: 262144    // cap on usage.json before it is parsed
  readonly property int maxHistoryEntries: 200
  readonly property int maxPromptChars: 120
  // Upper bounds on retained numbers. Without these a tampered state file can
  // put absurd values straight into the totals.
  readonly property int maxEntryTokens: 1000000
  readonly property int maxEntryMs: 86400000
  // Local inference does not exceed this; anything above it is bad data, not a
  // fast machine, so it is excluded from rates rather than shown.
  readonly property int maxPlausibleRate: 100000
  readonly property int maxHealthBytes: 16384
  readonly property int maxModelIdChars: 96
  readonly property int maxConfigBytes: 65536

  property bool truncated: false

  readonly property real tokPerSec: (elapsedMs > 0 && tokenCount > 0)
    ? (tokenCount / (elapsedMs / 1000)) : 0

  // ---- theme tokens (shared with the menu surface, like the emoji overlay) --
  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color scrimColor: Color.menu.scrim
  readonly property color accent: Color.menu.selectedBackground
  readonly property string fontFamily: Style.font.menuFamily

  // ---------------------------------------------------------------------------
  // Lifecycle — the contract the shell's summon/hide/toggle routing expects.
  // ---------------------------------------------------------------------------

  // `omarchy-shell shell summon newtorob.potluck '{"prompt": "..."}'` opens
  // the overlay with that question already sent, so a keybinding or a menu
  // entry can ask about the clipboard, a selection, or anything a script
  // builds. Any other payload just opens it empty.
  readonly property int maxSummonPromptChars: 8000

  function open(payloadJson) {
    root.opened = true
    root.mode = "ask"
    root.errorText = ""
    var summoned = ""
    try {
      var payload = JSON.parse(String(payloadJson || "{}"))
      if (payload && typeof payload.prompt === "string")
        summoned = payload.prompt.substring(0, root.maxSummonPromptChars).trim()
      // {"view": "models"} or {"view": "usage"} opens straight onto that view.
      if (payload && (payload.view === "models" || payload.view === "usage")) {
        root.mode = payload.view
        if (root.mode === "models") root.refreshModels()
      }
    } catch (e) {}
    if (summoned !== "" && !root.streaming) {
      input.text = summoned
      root.prompt = summoned
      // The key and the model id are re-read on open; give those reads a
      // moment so the first summoned ask carries the current key.
      Qt.callLater(function () { root.ask() })
    }
    Qt.callLater(function () { input.forceActiveFocus() })
  }

  function close() {
    root.cancel()
    root.opened = false
  }

  function dismiss() {
    root.cancel()
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "newtorob.potluck")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---------------------------------------------------------------------------
  // Streaming
  // ---------------------------------------------------------------------------

  function ask() {
    if (streaming || prompt.trim() === "") return
    answer = ""
    thinking = ""
    errorText = ""
    inThink = false
    tokenCount = 0
    elapsedMs = 0
    startedAt = Date.now()
    streaming = true

    truncated = false

    var body = JSON.stringify({
      messages: [{ role: "user", content: root.prompt }],
      stream: true,
      max_tokens: 2048
    })

    // The prompt, the URL and the key travel as environment values, never as
    // text inside the shell command, so none of them can alter the command
    // line. The bearer header is only added when a key is configured: a dev
    // sidecar with no token gate answers on /v1 without one.
    // `head -c` caps the response at the OS level: the parser cannot buffer or
    // retain more than maxStreamBytes even from a single unterminated line, and
    // when head exits curl takes SIGPIPE and stops producing.
    askProc.environment = ({
      "POTLUCK_ASK_URL": root.sidecarUrl + "/v1/chat/completions",
      "POTLUCK_ASK_BODY": body,
      "POTLUCK_ASK_KEY": root.gatewayKey
    })
    askProc.command = ["bash", "-c",
      'auth=(); if [ -n "$POTLUCK_ASK_KEY" ]; then auth=(-H "Authorization: Bearer $POTLUCK_ASK_KEY"); fi;'
      + ' curl -sN --max-time 300 -X POST "$POTLUCK_ASK_URL"'
      + ' -H "Content-Type: application/json"'
      + ' -H "X-Potluck-Scope: local"'
      + ' "${auth[@]}"'
      + ' --data-binary "$POTLUCK_ASK_BODY"'
      + ' | head -c ' + root.maxStreamBytes]
    askProc.running = true
  }

  // The gateway refuses a request with one JSON object instead of a stream.
  // Say what to do about it rather than echoing the server.
  function friendlyError(detail) {
    var d = String(detail || "")
    if (d.indexOf("gateway disabled") !== -1)
      return "Potluck's local API is off. In Potluck: Settings → Connect tools → turn it on, then ask again."
    if (d.indexOf("gateway API key") !== -1)
      return "Potluck rejected the API key. Close and reopen this overlay to re-read ~/.potluck/config.json."
    if (d.indexOf("No local model") !== -1 || d.indexOf("No model loaded") !== -1)
      return "No model is loaded. Open Potluck and load one, or Tab to Models."
    if (d === "Not Found")
      return "This Potluck is too old to manage models from here. Update to 0.1.6 or later."
    return d !== "" ? d.substring(0, 300) : "The sidecar returned an error."
  }

  function failWith(message) {
    root.errorText = message
    root.streaming = false
    if (askProc.running) askProc.running = false
  }

  function cancel() {
    if (askProc.running) {
      root.streaming = false
      askProc.running = false
    }
  }

  // One SSE line. Terminator is `data: [DONE]`; everything else carries a
  // choices[0].delta.content fragment.
  function onSseLine(raw) {
    // SSE separates events with a blank line, so every line after the first
    // arrives with a leading newline still attached. Trim before matching, or
    // only the very first event is ever recognised.
    // Drop absurdly long events rather than parsing them. head -c already caps
    // the total, but a single event should never approach this.
    if (String(raw).length > root.maxLineChars) { root.stopOverflow(); return }

    var line = String(raw).trim()
    if (line === "") return
    if (line.indexOf("data:") !== 0) {
      // Not an event. The gateway answered the request itself with one JSON
      // object: 401 (key rejected), 404 (gateway off), 503 (no model loaded).
      try {
        var refusal = JSON.parse(line)
        if (refusal && typeof refusal === "object" && refusal.detail !== undefined)
          root.failWith(root.friendlyError(refusal.detail))
      } catch (e) {}
      return
    }
    var payload = line.substring(5).trim()
    if (payload === "" ) return
    if (payload === "[DONE]") { root.finish(); return }

    var delta = ""
    try {
      var obj = JSON.parse(payload)
      if (obj && obj.error) {
        // An in-stream failure (inference error mid-answer) arrives as an
        // `error` event rather than a delta. Keep whatever text came first.
        root.failWith(root.friendlyError(obj.error.message || "inference error"))
        return
      }
      var choices = obj.choices || []
      if (choices.length > 0 && choices[0].delta)
        delta = choices[0].delta.content || ""
    } catch (e) {
      return
    }
    if (delta === "") return

    if (root.answer.length + root.thinking.length + delta.length > root.maxAnswerChars) {
      root.stopOverflow()
      return
    }

    root.tokenCount += 1
    root.elapsedMs = Date.now() - root.startedAt
    root.appendDelta(delta)
  }

  // Stop the producer the moment a cap is hit, and keep what was already
  // received rather than discarding a usable answer.
  function stopOverflow() {
    if (!root.streaming) return
    root.truncated = true
    root.streaming = false
    root.elapsedMs = Date.now() - root.startedAt
    if (askProc.running) askProc.running = false
    root.recordUsage()
  }

  // Reasoning models (Qwen3 among them) emit a <think>…</think> preamble before
  // the answer. Splitting them keeps the reasoning available but out of the way
  // instead of letting it dominate the reply.
  function appendDelta(delta) {
    var text = delta
    while (text.length > 0) {
      if (!root.inThink) {
        var openAt = text.indexOf("<think>")
        if (openAt === -1) { root.answer += text; return }
        root.answer += text.substring(0, openAt)
        text = text.substring(openAt + 7)
        root.inThink = true
      } else {
        var closeAt = text.indexOf("</think>")
        if (closeAt === -1) { root.thinking += text; return }
        root.thinking += text.substring(0, closeAt)
        text = text.substring(closeAt + 8)
        root.inThink = false
      }
    }
  }

  function finish() {
    if (!root.streaming) return
    root.streaming = false
    root.elapsedMs = Date.now() - root.startedAt
    root.recordUsage()
  }

  Process {
    id: askProc
    stdout: SplitParser { onRead: function (line) { root.onSseLine(line) } }
    onExited: function (exitCode) {
      if (root.streaming) {
        // [DONE] never arrived — curl died, the sidecar went away, or the
        // request timed out. Say so rather than leaving a half answer looking
        // complete.
        root.streaming = false
        if (root.answer === "" && root.thinking === "")
          root.errorText = "No response from the sidecar (curl exit " + exitCode + ")"
        else
          root.recordUsage()
      }
    }
  }

  Timer {
    interval: 100
    running: root.streaming
    repeat: true
    onTriggered: root.elapsedMs = Date.now() - root.startedAt
  }

  // ---------------------------------------------------------------------------
  // Usage persistence
  // ---------------------------------------------------------------------------

  function recordUsage() {
    if (tokenCount <= 0) return
    var entry = {
      ts: Date.now(),
      model: root.modelId,
      prompt: root.prompt.substring(0, root.maxPromptChars),
      tokens: root.tokenCount,
      ms: Math.round(root.elapsedMs)
    }
    var next = [entry].concat(root.history)
    root.history = next.slice(0, root.maxHistoryEntries)
    usageWriter.environment = ({
      "POTLUCK_STATE": root.statePath,
      "POTLUCK_STATE_JSON": JSON.stringify(root.history, null, 2) + "\n"
    })
    usageWriter.running = true
  }

  // usage.json is an ordinary user-writable file, so it is treated as untrusted
  // input: size-capped before parsing, then every retained field is coerced to a
  // known type and clamped. Nothing from disk reaches the UI unbounded.
  function loadUsage(raw) {
    var text = String(raw || "")
    if (text.length > root.maxStateBytes) {
      console.warn("[potluck] usage.json exceeds " + root.maxStateBytes
        + " bytes; ignoring it rather than retaining it")
      root.history = []
      return
    }

    var parsed
    try {
      parsed = JSON.parse(text)
    } catch (e) {
      root.history = []
      return
    }
    if (!Array.isArray(parsed)) { root.history = []; return }

    var clean = []
    for (var i = 0; i < parsed.length && clean.length < root.maxHistoryEntries; i++) {
      var e = parsed[i]
      if (!e || typeof e !== "object") continue
      var tokens = Number(e.tokens)
      var ms = Number(e.ms)
      var ts = Number(e.ts)
      clean.push({
        ts: isFinite(ts) && ts > 0 ? Math.min(ts, Date.now()) : 0,
        model: String(e.model || "").substring(0, 64),
        prompt: String(e.prompt || "").substring(0, root.maxPromptChars),
        tokens: isFinite(tokens) && tokens >= 0
          ? Math.min(Math.floor(tokens), root.maxEntryTokens) : 0,
        ms: isFinite(ms) && ms >= 0
          ? Math.min(Math.floor(ms), root.maxEntryMs) : 0
      })
    }
    root.history = clean
  }

  function totalAsks() { return history.length }

  function totalTokens() {
    var n = 0
    for (var i = 0; i < history.length; i++) n += Number(history[i].tokens || 0)
    return n
  }

  // Aggregate rate over all recorded time, not a mean of per-ask rates — a
  // two-token ask would otherwise weigh as much as a thousand-token one.
  function avgTokPerSec() {
    var tok = 0, ms = 0
    for (var i = 0; i < history.length; i++) {
      var e = history[i]
      // Only entries that are individually plausible contribute, so one bad
      // record cannot distort the aggregate.
      if (root.rateOf(e.tokens, e.ms) < 0) continue
      tok += Number(e.tokens || 0)
      ms += Number(e.ms || 0)
    }
    return root.rateOf(tok, ms)
  }

  function bestTokPerSec() {
    var best = -1
    for (var i = 0; i < history.length; i++) {
      var e = history[i]
      var r = root.rateOf(e.tokens, e.ms)
      if (r > best) best = r
    }
    return best
  }

  // Rates are only meaningful over a real interval; anything shorter reports as
  // "-" rather than a number scaled by an almost-zero denominator.
  function rateOf(tokens, ms) {
    var t = Number(tokens), m = Number(ms)
    if (!isFinite(t) || !isFinite(m) || m < 50 || t <= 0) return -1
    var r = t / (m / 1000)
    return r > root.maxPlausibleRate ? -1 : r
  }

  function fmtRate(v) {
    if (!isFinite(v) || v < 0) return "-"
    return (Math.round(v * 10) / 10).toFixed(1)
  }

  function fmtAgo(ts) {
    var s = Math.max(0, Math.round((Date.now() - Number(ts)) / 1000))
    if (s < 60) return s + "s ago"
    if (s < 3600) return Math.round(s / 60) + "m ago"
    if (s < 86400) return Math.round(s / 3600) + "h ago"
    return Math.round(s / 86400) + "d ago"
  }

  Process {
    id: usageReader
    running: true
    environment: ({ "POTLUCK_STATE": root.statePath })
    // The state file is replaceable by anything the user's account can create,
    // so it is never handed to QML unbounded. FileView would read the whole
    // file into the long-lived shell process before any check could run, follow
    // a symlink to an arbitrary target, and block indefinitely on a FIFO. This
    // refuses a symlink or non-regular path outright, caps the read at
    // maxStateBytes in the pipe, and bounds a blocking open with a timeout, so
    // at most maxStateBytes of a regular file is ever retained.
    command: ["bash", "-lc",
      'f="$POTLUCK_STATE"; d=$(dirname "$f");'
      + ' [ -L "$d" ] && exit 5;'
      + ' [ -L "$f" ] && exit 3;'
      + ' [ -f "$f" ] || exit 4;'
      + ' exec timeout 2 head -c ' + root.maxStateBytes + ' "$f"']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadUsage(text)
    }
    onExited: function (exitCode) {
      // 3 symlink, 4 missing/not a regular file, 5 symlinked directory.
      if (exitCode === 3 || exitCode === 5) {
        console.warn("[potluck] refusing to read usage state through a symlink")
        root.history = []
      } else if (exitCode !== 0) {
        root.history = []
      }
    }
  }

  // Writes go through the same guards: never through a symlink or a
  // non-regular path, and atomically via a temp file in the same directory.
  Process {
    id: usageWriter
    environment: ({
      "POTLUCK_STATE": root.statePath,
      "POTLUCK_STATE_JSON": ""
    })
    command: ["bash", "-lc",
      'f="$POTLUCK_STATE"; d=$(dirname "$f");'
      + ' [ -L "$d" ] && exit 5;'
      + ' mkdir -p "$d" || exit 1;'
      + ' if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then rm -f "$f" || exit 1; fi;'
      + ' t=$(mktemp "$d/.usage.XXXXXX") || exit 1;'
      + ' printf "%s" "$POTLUCK_STATE_JSON" > "$t" && mv -f "$t" "$f" || { rm -f "$t"; exit 1; }']
  }

  // ---------------------------------------------------------------------------
  // Local API key
  // ---------------------------------------------------------------------------

  // The gateway switch and key live in ~/.potluck/config.json, the app's own
  // settings file, which Settings → Connect tools writes. Read with the same
  // guards as usage.json: never through a symlink, never more than
  // maxConfigBytes, and only a key that looks like one is kept.
  Process {
    id: configReader
    running: true
    environment: ({ "POTLUCK_CONFIG": root.configPath })
    command: ["bash", "-c",
      'f="$POTLUCK_CONFIG";'
      + ' [ -L "$f" ] && exit 3;'
      + ' [ -f "$f" ] || exit 4;'
      + ' exec timeout 2 head -c ' + root.maxConfigBytes + ' "$f"']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadConfig(text)
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) { root.gatewayEnabled = false; root.gatewayKey = "" }
    }
  }

  function loadConfig(raw) {
    var text = String(raw || "")
    root.gatewayEnabled = false
    root.gatewayKey = ""
    // At the cap the file was truncated, so it is not trustworthy JSON.
    if (text.length === 0 || text.length >= root.maxConfigBytes) return
    try {
      var c = JSON.parse(text)
      var gw = c && c.gateway
      if (gw && typeof gw === "object") {
        root.gatewayEnabled = gw.enabled === true
        var key = String(gw.api_key || "")
        if (root.gatewayEnabled && /^[A-Za-z0-9._\-]{8,256}$/.test(key)) root.gatewayKey = key
      }
    } catch (e) {}
  }

  // ---------------------------------------------------------------------------
  // Clipboard
  // ---------------------------------------------------------------------------

  function copyAnswer() {
    if (root.answer === "") return
    copyProc.environment = ({ "POTLUCK_COPY_TEXT": root.answer })
    copyProc.running = true
    root.copied = true
    copiedTimer.restart()
  }

  Process {
    id: copyProc
    environment: ({ "POTLUCK_COPY_TEXT": "" })
    command: ["bash", "-c", 'printf "%s" "$POTLUCK_COPY_TEXT" | wl-copy']
  }

  Timer {
    id: copiedTimer
    interval: 1500
    onTriggered: root.copied = false
  }

  // Which model is answering — shown in the header and stamped on each entry.
  Process {
    id: healthProc
    // --max-time bounds how long the response may take, not how large it may
    // be, so the body is capped in the pipe before QML collects it. Anything
    // holding the sidecar port is untrusted.
    environment: ({ "POTLUCK_HEALTH_URL": root.sidecarUrl + "/health" })
    command: ["bash", "-lc",
      'curl -s --max-time 3 "$POTLUCK_HEALTH_URL" | head -c ' + root.maxHealthBytes]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "")
        // At the cap the body was truncated, so it is not trustworthy JSON.
        if (raw.length === 0 || raw.length >= root.maxHealthBytes) { root.modelId = ""; return }
        try {
          var h = JSON.parse(raw)
          root.modelId = String(h.active_model_id || "").substring(0, root.maxModelIdChars)
        } catch (e) { root.modelId = "" }
      }
    }
  }

  onOpenedChanged: if (opened) { healthProc.running = true; configReader.running = true }

  // ---------------------------------------------------------------------------
  // Views
  // ---------------------------------------------------------------------------

  function cycleMode() {
    root.mode = root.mode === "ask" ? "models" : (root.mode === "models" ? "usage" : "ask")
    if (root.mode === "ask") Qt.callLater(function () { input.forceActiveFocus() })
    if (root.mode === "models") root.refreshModels()
  }

  // ---------------------------------------------------------------------------
  // The app itself
  // ---------------------------------------------------------------------------

  function openApp() {
    Quickshell.execDetached(["bash", "-c", root.launchCommand])
    root.modelsNotice = "opening Potluck"
  }

  // Close the app's window the way the compositor would on Super+W: a normal
  // close request, so the app can shut its sidecar down cleanly. Matches the
  // window the same way omarchy-launch-or-focus finds it.
  function closeApp() {
    closeProc.running = true
    root.modelsNotice = "closing Potluck"
  }

  Process {
    id: closeProc
    command: ["bash", "-c",
      'addr=$(hyprctl clients -j | jq -r \'.[] | select((.class | test("\\\\bpotluck-ai-desktop\\\\b|^Potluck AI"; "i")) or (.title | test("^Potluck AI"; "i"))) | .address\' | head -n1);'
      + ' [ -n "$addr" ] && hyprctl dispatch closewindow "address:$addr" >/dev/null']
  }

  // ---------------------------------------------------------------------------
  // Models: the keyed management surface at /v1/potluck/models
  // ---------------------------------------------------------------------------

  // Same shape as ask(): key, URL and method travel as environment values,
  // never as text in the command line; the body is capped in the pipe.
  function apiCommand(cap) {
    return ["bash", "-c",
      'auth=(); if [ -n "$POTLUCK_KEY" ]; then auth=(-H "Authorization: Bearer $POTLUCK_KEY"); fi;'
      + ' curl -s --max-time "$POTLUCK_TIMEOUT" -X "$POTLUCK_METHOD" "$POTLUCK_URL" "${auth[@]}"'
      + ' -H "Content-Type: application/json" | head -c ' + cap]
  }

  function apiEnv(method, path, timeoutSec) {
    return {
      "POTLUCK_KEY": root.gatewayKey,
      "POTLUCK_URL": root.sidecarUrl + path,
      "POTLUCK_METHOD": method,
      "POTLUCK_TIMEOUT": String(timeoutSec)
    }
  }

  function refreshModels() {
    if (modelsProc.running) return
    modelsProc.environment = root.apiEnv("GET", "/v1/potluck/models", 10)
    modelsProc.command = root.apiCommand(root.maxModelsBytes)
    modelsProc.running = true
  }

  function slugOk(v) { return /^[A-Za-z0-9._\-]{1,96}$/.test(String(v || "")) }

  // Scriptable: `omarchy-shell shell call newtorob.potluck act
  // '{"slug": "qwen3-4b-instruct-2507-q4", "action": "load"}'`. The same
  // guarded path as the keys, so a menu entry or keybinding can load, unload,
  // install or cancel a download without opening the overlay.
  function act(payloadJson) {
    var p
    try { p = JSON.parse(String(payloadJson || "{}")) } catch (e) { return "bad payload" }
    if (!p || typeof p !== "object" || !root.slugOk(p.slug)) return "bad slug"
    root.modelAction(String(p.slug), String(p.action || ""))
    return root.busySlug !== "" ? "started" : "refused"
  }

  function applyModels(raw) {
    var text = String(raw || "")
    if (text.length === 0) { root.modelsError = "Potluck is not running."; return }
    if (text.length >= root.maxModelsBytes) { root.modelsError = "The model list was too large to read."; return }
    var d
    try { d = JSON.parse(text) } catch (e) { root.modelsError = "Unreadable reply from the sidecar."; return }
    if (d && d.detail !== undefined) { root.modelsError = root.friendlyError(d.detail); return }
    var list = d && Array.isArray(d.models) ? d.models : []
    var clean = []
    for (var i = 0; i < list.length && clean.length < root.maxModels; i++) {
      var m = list[i]
      if (!m || typeof m !== "object" || !root.slugOk(m.slug)) continue
      var dl = m.download && typeof m.download === "object" ? m.download : null
      clean.push({
        slug: String(m.slug),
        name: String(m.name || m.slug).substring(0, 64),
        tier: String(m.tier || "").substring(0, 16),
        sizeBytes: Math.max(0, Math.min(Number(m.size_on_disk || m.size_bytes || 0) || 0, 1e13)),
        installed: m.installed === true,
        loaded: m.loaded === true,
        dlStatus: dl ? String(dl.status || "").substring(0, 16) : "",
        dlDone: dl ? Math.max(0, Number(dl.bytes_downloaded) || 0) : 0,
        dlTotal: dl ? Math.max(0, Number(dl.bytes_total) || 0) : 0,
        dlSpeed: dl ? Math.max(0, Number(dl.speed_bps) || 0) : 0,
        dlError: dl && dl.error ? String(dl.error).substring(0, 120) : ""
      })
    }
    root.models = clean
    root.loadedSlug = root.slugOk(d.loaded) ? String(d.loaded) : ""
    if (root.cursor >= clean.length) root.cursor = Math.max(0, clean.length - 1)
    root.modelsError = ""
  }

  function anyDownloading() {
    for (var i = 0; i < root.models.length; i++) {
      var st = root.models[i].dlStatus
      if (st === "downloading" || st === "verifying") return true
    }
    return false
  }

  function installedCount() {
    var n = 0
    for (var i = 0; i < root.models.length; i++) if (root.models[i].installed) n++
    return n
  }

  // One action at a time. A load blocks for seconds and holds the runtime
  // lock, so the view marks the slug busy and polls the list until it ends.
  function modelAction(slug, action) {
    if (actionProc.running || !root.slugOk(slug)) return
    var timeouts = { "load": 600, "unload": 60, "install": 30, "cancel-download": 10 }
    if (timeouts[action] === undefined) return
    root.busySlug = slug
    root.busyAction = action
    root.modelsError = ""
    root.modelsNotice = ""
    actionProc.environment = root.apiEnv("POST", "/v1/potluck/models/" + slug + "/" + action, timeouts[action])
    actionProc.command = root.apiCommand(root.maxHealthBytes)
    actionProc.running = true
  }

  function onActionResult(raw) {
    var text = String(raw || "")
    var d = null
    try { d = text.length > 0 && text.length < root.maxHealthBytes ? JSON.parse(text) : null } catch (e) {}
    if (!d || typeof d !== "object") {
      root.modelsError = text.length === 0 ? "Potluck is not running." : "Unreadable reply from the sidecar."
      return
    }
    if (d.detail !== undefined) { root.modelsError = root.friendlyError(d.detail); return }
    if (d.load_time_seconds !== undefined) {
      var inf = d.inference && typeof d.inference === "object" ? d.inference : null
      var where = inf ? (inf.device_kind === "gpu" ? "GPU" : inf.device_kind === "mixed" ? "GPU + CPU" : "CPU")
        + (inf.backend && inf.backend !== "cpu" ? " · " + String(inf.backend).substring(0, 16) : "") : ""
      root.modelsNotice = "loaded " + String(d.model_id || "").substring(0, 64)
        + " in " + (Math.round(Number(d.load_time_seconds) * 10) / 10) + " s"
        + (where !== "" ? " on " + where : "")
      return
    }
    var status = String(d.status || "").substring(0, 32)
    var said = {
      "downloading": "download started", "already_downloading": "already downloading",
      "already_installed": "already installed", "unloaded": "unloaded", "cancelled": "download cancelled"
    }
    root.modelsNotice = said[status] || status
  }

  function currentModel() {
    return root.cursor >= 0 && root.cursor < root.models.length ? root.models[root.cursor] : null
  }

  // Keys for the models view. Returns true when the key was used.
  function modelsKey(event) {
    var k = event.key
    if (k === Qt.Key_J || k === Qt.Key_Down) { if (root.cursor < root.models.length - 1) root.cursor++; return true }
    if (k === Qt.Key_K || k === Qt.Key_Up) { if (root.cursor > 0) root.cursor--; return true }
    if (k === Qt.Key_R) { root.refreshModels(); return true }
    var m = root.currentModel()
    if (k === Qt.Key_Return || k === Qt.Key_Enter) {
      if (!m || root.busySlug !== "") return true
      if (m.dlStatus === "downloading" || m.dlStatus === "verifying") return true
      if (m.loaded) { root.modelsNotice = m.name + " is already loaded"; return true }
      root.modelAction(m.slug, m.installed ? "load" : "install")
      return true
    }
    if (k === Qt.Key_U) {
      if (root.loadedSlug !== "" && root.busySlug === "") root.modelAction(root.loadedSlug, "unload")
      return true
    }
    if (k === Qt.Key_X) {
      if (m && (m.dlStatus === "downloading" || m.dlStatus === "verifying")) root.modelAction(m.slug, "cancel-download")
      return true
    }
    return false
  }

  function fmtBytes(b) {
    var n = Number(b) || 0
    if (n >= 1073741824) return (Math.round(n / 1073741824 * 10) / 10).toFixed(1) + " GB"
    if (n >= 1048576) return Math.round(n / 1048576) + " MB"
    return Math.round(n / 1024) + " KB"
  }

  function stateText(m) {
    if (root.busySlug === m.slug) return root.busyAction === "load" ? "loading…" : root.busyAction + "…"
    if (m.dlStatus === "downloading") {
      var pct = m.dlTotal > 0 ? Math.round(m.dlDone / m.dlTotal * 100) : 0
      return "downloading " + pct + "%" + (m.dlSpeed > 0 ? " · " + root.fmtBytes(m.dlSpeed) + "/s" : "")
    }
    if (m.dlStatus === "verifying") return "verifying…"
    if (m.dlStatus === "error") return "download failed"
    if (m.loaded) return "loaded"
    if (m.installed) return "installed"
    return root.fmtBytes(m.sizeBytes) + " download"
  }

  Process {
    id: modelsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyModels(text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onActionResult(text)
    }
    onExited: function (exitCode) {
      root.busySlug = ""
      root.busyAction = ""
      root.refreshModels()
      healthProc.running = true
    }
  }

  // Poll while something is in flight so progress and "loading…" move.
  Timer {
    interval: 2000
    repeat: true
    running: root.opened && root.mode === "models" && (root.busySlug !== "" || root.anyDownloading())
    onTriggered: root.refreshModels()
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  PanelWindow {
    id: panel
    visible: root.opened
    color: "transparent"
    anchors { top: true; bottom: true; left: true; right: true }

    WlrLayershell.namespace: "omarchy-potluck-ask"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

    Rectangle {
      anchors.fill: parent
      color: root.scrimColor
      MouseArea { anchors.fill: parent; onClicked: root.dismiss() }
    }

    FocusScope {
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem
      Keys.onPressed: function (event) {
        if (event.key === Qt.Key_Escape) {
          if (root.streaming) root.cancel()
          else root.dismiss()
          event.accepted = true
        } else if (event.key === Qt.Key_Tab) {
          root.cycleMode()
          event.accepted = true
        } else if (event.key === Qt.Key_O && (event.modifiers & Qt.ControlModifier)) {
          root.openApp()
          event.accepted = true
        } else if (event.key === Qt.Key_W && (event.modifiers & Qt.ControlModifier)) {
          root.closeApp()
          event.accepted = true
        } else if (root.mode === "models" && root.modelsKey(event)) {
          event.accepted = true
        } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
          // Ctrl+C copies the finished answer, unless the input has its own
          // selection to copy; then the TextInput keeps the key.
          if (root.mode === "ask" && root.answer !== "" && !root.streaming
              && input.selectedText === "") {
            root.copyAnswer()
            event.accepted = true
          }
        }
      }

      Rectangle {
        id: card
        anchors.centerIn: parent
        width: Math.min(760, parent.width - 80)
        height: Math.min(560, parent.height - 80)
        radius: Style.cornerRadius
        color: root.background
        border.width: 1
        border.color: root.borderColor

        // Swallow clicks so they do not reach the dismiss scrim behind.
        MouseArea { anchors.fill: parent; onClicked: {} }

        Column {
          anchors.fill: parent
          anchors.margins: 18
          spacing: 12

          // ---- header ----
          Item {
            width: parent.width
            height: 22

            Text {
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "ask" ? "Ask Potluck" : (root.mode === "models" ? "Potluck models" : "Potluck usage")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 15
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "ask"
                ? (root.modelId !== "" ? root.modelId : "no model")
                : (root.mode === "models"
                  ? (root.models.length + " in catalog · " + root.installedCount() + " installed")
                  : (root.totalAsks() + " asks recorded"))
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: 11
            }
          }

          // ---- ask mode ----
          Rectangle {
            visible: root.mode === "ask"
            width: parent.width
            height: 38
            radius: 6
            color: "transparent"
            border.width: 1
            border.color: input.activeFocus ? root.accent : root.borderColor

            TextInput {
              id: input
              anchors.fill: parent
              anchors.leftMargin: 10
              anchors.rightMargin: 10
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: 13
              selectByMouse: true
              clip: true
              text: root.prompt
              onTextChanged: root.prompt = text
              onAccepted: root.ask()

              Text {
                textFormat: Text.PlainText
                anchors.verticalCenter: parent.verticalCenter
                visible: input.text === ""
                text: "Ask the local model…  ·  Enter to send, Tab for models, Esc to close"
                color: root.foreground
                opacity: 0.4
                font.family: root.fontFamily
                font.pixelSize: 12
              }
            }
          }

          Flickable {
            visible: root.mode === "ask"
            width: parent.width
            height: parent.height - 38 - 22 - 24 - 24
            contentWidth: width
            contentHeight: answerCol.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: answerCol
              width: parent.width
              spacing: 8

              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.errorText !== ""
                text: root.errorText
                color: "#e06c75"
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: 12
              }

              // Reasoning, kept visible but subordinate to the answer.
              Text {
                textFormat: Text.PlainText
                width: parent.width
                visible: root.thinking !== "" && root.answer === ""
                text: root.thinking
                color: root.foreground
                opacity: 0.4
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: 11
                font.italic: true
              }

              Text {
                width: parent.width
                visible: root.answer !== ""
                text: root.answer
                color: root.foreground
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                font.family: root.fontFamily
                font.pixelSize: 13
              }
            }
          }

          // ---- ask footer ----
          Text {
            textFormat: Text.PlainText
            visible: root.mode === "ask"
            width: parent.width
            color: root.foreground
            opacity: 0.55
            font.family: root.fontFamily
            font.pixelSize: 11
            text: {
              if (root.copied)
                return "answer copied to the clipboard"
              if (root.streaming)
                return "streaming · " + root.tokenCount + " tokens · "
                  + root.fmtRate(root.tokPerSec) + " tok/s"
              if (root.truncated)
                return "stopped at the size limit · " + root.tokenCount + " tokens · "
                  + root.fmtRate(root.tokPerSec) + " tok/s"
              if (root.tokenCount > 0)
                return "done · " + root.tokenCount + " tokens · "
                  + root.fmtRate(root.tokPerSec) + " tok/s · "
                  + (Math.round(root.elapsedMs / 100) / 10) + "s · Ctrl+C to copy"
              if (!root.gatewayEnabled)
                return "Local API off? Potluck → Settings → Connect tools · Esc to close"
              return "Enter to send · Tab for models and usage · Ctrl+O open app · Esc to close"
            }
          }

          // ---- models mode ----
          Column {
            visible: root.mode === "models"
            width: parent.width
            spacing: 8

            Text {
              textFormat: Text.PlainText
              width: parent.width
              visible: root.modelsError !== "" || root.modelsNotice !== ""
              text: root.modelsError !== "" ? root.modelsError : root.modelsNotice
              color: root.modelsError !== "" ? "#e06c75" : root.foreground
              opacity: root.modelsError !== "" ? 1.0 : 0.6
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: 12
            }

            Text {
              textFormat: Text.PlainText
              visible: root.models.length === 0 && root.modelsError === ""
              text: "Reading the catalog…"
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: 12
            }

            Flickable {
              id: modelsFlick
              width: parent.width
              height: card.height - 36 - 22 - 24 - 40 - (root.modelsError !== "" || root.modelsNotice !== "" ? 28 : 0)
              contentWidth: width
              contentHeight: modelsCol.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              // Keep the cursor row in view as j/k move it.
              function reveal(index) {
                var y = index * 34
                if (y < contentY) contentY = y
                else if (y + 34 > contentY + height) contentY = y + 34 - height
              }

              Column {
                id: modelsCol
                width: parent.width
                spacing: 0

                Repeater {
                  model: root.models

                  delegate: Rectangle {
                    width: modelsCol.width
                    height: 34
                    radius: 5
                    color: index === root.cursor ? root.accent : "transparent"
                    opacity: index === root.cursor ? 0.9 : 1.0

                    Rectangle {
                      // The loaded model carries a filled dot; installed ones a hollow one.
                      anchors.left: parent.left
                      anchors.leftMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      width: 7; height: 7; radius: 3.5
                      color: modelData.loaded ? root.foreground : "transparent"
                      border.width: modelData.installed ? 1 : 0
                      border.color: root.foreground
                      opacity: modelData.installed ? 1.0 : 0.0
                    }

                    Text {
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.leftMargin: 26
                      anchors.right: stateLabel.left
                      anchors.rightMargin: 12
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.name + "   " + modelData.tier
                      color: root.foreground
                      opacity: modelData.installed ? 1.0 : 0.7
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: 12
                      font.bold: modelData.loaded
                    }

                    Text {
                      textFormat: Text.PlainText
                      id: stateLabel
                      anchors.right: parent.right
                      anchors.rightMargin: 10
                      anchors.verticalCenter: parent.verticalCenter
                      text: root.stateText(modelData)
                      color: root.foreground
                      opacity: 0.6
                      font.family: root.fontFamily
                      font.pixelSize: 11
                    }

                    MouseArea {
                      anchors.fill: parent
                      onClicked: root.cursor = index
                      onDoubleClicked: { root.cursor = index; root.modelsKey({ key: Qt.Key_Return }) }
                    }
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: 11
              elide: Text.ElideRight
              text: "Enter load or download · u unload · x cancel · j/k move · r refresh · Ctrl+O open app · Ctrl+W close app"
            }
          }

          // ---- usage mode ----
          Column {
            visible: root.mode === "usage"
            width: parent.width
            spacing: 10

            Row {
              width: parent.width
              spacing: 28

              Repeater {
                model: [
                  { k: "Asks",      v: String(root.totalAsks()) },
                  { k: "Tokens",    v: String(root.totalTokens()) },
                  { k: "Avg tok/s", v: root.fmtRate(root.avgTokPerSec()) },
                  { k: "Best tok/s",v: root.fmtRate(root.bestTokPerSec()) }
                ]
                delegate: Column {
                  spacing: 2
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.v
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: 20
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.k
                    color: root.foreground
                    opacity: 0.5
                    font.family: root.fontFamily
                    font.pixelSize: 10
                  }
                }
              }
            }

            Rectangle {
              width: parent.width
              height: 1
              color: root.borderColor
              opacity: 0.5
            }

            Text {
              textFormat: Text.PlainText
              visible: root.history.length === 0
              text: "No asks recorded yet. Tab back to Ask and ask something."
              color: root.foreground
              opacity: 0.45
              font.family: root.fontFamily
              font.pixelSize: 12
            }

            Flickable {
              width: parent.width
              height: card.height - 200
              contentWidth: width
              contentHeight: histCol.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: histCol
                width: parent.width
                spacing: 6

                Repeater {
                  model: root.history

                  delegate: Item {
                    width: histCol.width
                    height: 30

                    Text {
                      textFormat: Text.PlainText
                      anchors.left: parent.left
                      anchors.right: statsText.left
                      anchors.rightMargin: 12
                      anchors.verticalCenter: parent.verticalCenter
                      text: modelData.prompt || "(empty)"
                      color: root.foreground
                      opacity: 0.85
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: 12
                    }

                    Text {
                      textFormat: Text.PlainText
                      id: statsText
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      text: (modelData.tokens || 0) + " tok · "
                        + root.fmtRate(root.rateOf(modelData.tokens, modelData.ms))
                        + " tok/s · " + root.fmtAgo(modelData.ts)
                      color: root.foreground
                      opacity: 0.45
                      font.family: root.fontFamily
                      font.pixelSize: 10
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
