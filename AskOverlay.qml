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

  function open(payloadJson) {
    root.opened = true
    root.mode = "ask"
    root.errorText = ""
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

    // The prompt and the sidecar URL travel as environment values, never as
    // text inside the shell command, so neither can alter the command line.
    // `head -c` caps the response at the OS level: the parser cannot buffer or
    // retain more than maxStreamBytes even from a single unterminated line, and
    // when head exits curl takes SIGPIPE and stops producing.
    askProc.environment = ({
      "POTLUCK_ASK_URL": root.sidecarUrl + "/chat/completions",
      "POTLUCK_ASK_BODY": body
    })
    askProc.command = ["bash", "-lc",
      "curl -sN --max-time 300 -X POST \"$POTLUCK_ASK_URL\""
      + " -H 'Content-Type: application/json'"
      + " --data-binary \"$POTLUCK_ASK_BODY\""
      + " | head -c " + root.maxStreamBytes]
    askProc.running = true
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
    if (line.indexOf("data:") !== 0) return
    var payload = line.substring(5).trim()
    if (payload === "" ) return
    if (payload === "[DONE]") { root.finish(); return }

    var delta = ""
    try {
      var obj = JSON.parse(payload)
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
    stderr: StdioCollector { waitForEnd: true }
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

  // Which model is answering — shown in the header and stamped on each entry.
  Process {
    id: healthProc
    command: ["curl", "-s", "--max-time", "3", root.sidecarUrl + "/health"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var h = JSON.parse(String(text))
          root.modelId = h.active_model_id ? String(h.active_model_id) : ""
        } catch (e) { root.modelId = "" }
      }
    }
  }

  onOpenedChanged: if (opened) healthProc.running = true

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
          root.mode = root.mode === "ask" ? "usage" : "ask"
          if (root.mode === "ask") Qt.callLater(function () { input.forceActiveFocus() })
          event.accepted = true
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
              text: root.mode === "ask" ? "Ask Potluck" : "Potluck usage"
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
                : (root.totalAsks() + " asks recorded")
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
                text: "Ask the local model…  ·  Enter to send, Tab for usage, Esc to close"
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
              if (root.streaming)
                return "streaming · " + root.tokenCount + " tokens · "
                  + root.fmtRate(root.tokPerSec) + " tok/s"
              if (root.truncated)
                return "stopped at the size limit · " + root.tokenCount + " tokens · "
                  + root.fmtRate(root.tokPerSec) + " tok/s"
              if (root.tokenCount > 0)
                return "done · " + root.tokenCount + " tokens · "
                  + root.fmtRate(root.tokPerSec) + " tok/s · "
                  + (Math.round(root.elapsedMs / 100) / 10) + "s"
              return "Enter to send · Tab for usage · Esc to close"
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
              text: "No asks recorded yet. Press Tab and ask something."
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
