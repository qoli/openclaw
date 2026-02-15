#!/usr/bin/env bash
set -euo pipefail

DEFAULT_OPENCLAW_LOG_SOURCE_VM="/tmp/openclaw"
DEFAULT_OPENCLAW_LOG_MIRROR_VM="/home/ronnie/.openclaw/logs/openclaw-tailspin"
LEGACY_OPENCLAW_LOG_MAC="/Users/ronnie/OrbStack/debian/mnt/linux/tmp/openclaw"
DEFAULT_LM_STUDIO_LOG_GLOB="/Users/ronnie/.cache/lm-studio/server-logs/*/*.log"

DEFAULT_CACHE_TRACE_VM="/home/ronnie/.openclaw/logs/cache-trace.jsonl"
DEFAULT_CACHE_TRACE_MAC="/Users/ronnie/OrbStack/debian/home/ronnie/.openclaw/logs/cache-trace.jsonl"
LEGACY_CACHE_TRACE_VM="/tmp/openclaw/cache-trace.jsonl"
LEGACY_CACHE_TRACE_MAC="/Users/ronnie/OrbStack/debian/mnt/linux/tmp/openclaw/cache-trace.jsonl"

OPENCLAW_CONFIG_VM="/home/ronnie/.openclaw/openclaw.json"
OPENCLAW_CONFIG_MAC="/Users/ronnie/OrbStack/debian/home/ronnie/.openclaw/openclaw.json"

OPENCLAW_SYNC_SSH_HOST="${OPENCLAW_SYNC_SSH_HOST:-ronnie@debian.orb.local}"
OPENCLAW_SYNC_INTERVAL_SEC="${OPENCLAW_SYNC_INTERVAL_SEC:-1}"
OPENCLAW_MONITOR_LOG="${OPENCLAW_MONITOR_LOG:-1}"
OPENCLAW_MONITOR_CACHE_TRACE="${OPENCLAW_MONITOR_CACHE_TRACE:-1}"

OPENCLAW_LOG_DIR_ARG="${1:-}"
LM_STUDIO_LOG_GLOB_ARG="${2:-}"
CACHE_TRACE_FILE_ARG="${3:-}"
LASTONE_JSON_FILE_ARG="${4:-}"

SYNC_PID=""
LOG_MONITOR_PID=""
CACHE_MONITOR_PID=""
HIGHLIGHTER_PID=""
PIPE_DIR=""
MERGE_PIPE=""

map_vm_path_to_mac() {
  local p="$1"
  if [[ "$p" == /home/ronnie/* ]] && [[ -d /Users/ronnie/OrbStack/debian/home/ronnie ]]; then
    printf '/Users/ronnie/OrbStack/debian%s\n' "$p"
    return 0
  fi
  printf '%s\n' "$p"
}

resolve_cache_trace_from_config() {
  local config_file=""
  if [[ -f "$OPENCLAW_CONFIG_VM" ]]; then
    config_file="$OPENCLAW_CONFIG_VM"
  elif [[ -f "$OPENCLAW_CONFIG_MAC" ]]; then
    config_file="$OPENCLAW_CONFIG_MAC"
  fi

  if [[ -z "$config_file" ]]; then
    return 1
  fi

  local resolved
  resolved="$(
    node -e '
const fs = require("node:fs");
const p = process.argv[1];
try {
  const cfg = JSON.parse(fs.readFileSync(p, "utf8"));
  const v = cfg?.diagnostics?.cacheTrace?.filePath;
  if (typeof v === "string" && v.trim()) {
    process.stdout.write(v.trim());
  }
} catch {}
' "$config_file"
  )"

  if [[ -z "$resolved" ]]; then
    return 1
  fi

  map_vm_path_to_mac "$resolved"
}

sync_vm_logs_once_local() {
  local src="$DEFAULT_OPENCLAW_LOG_SOURCE_VM"
  local dst="$DEFAULT_OPENCLAW_LOG_MIRROR_VM"
  mkdir -p "$dst"
  if [[ ! -d "$src" ]]; then
    return 1
  fi

  shopt -s nullglob
  for f in "$src"/*.log; do
    cp -f "$f" "$dst"/
  done
  shopt -u nullglob
}

sync_vm_logs_once_ssh() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$OPENCLAW_SYNC_SSH_HOST" 'bash -s' -- \
    "$DEFAULT_OPENCLAW_LOG_SOURCE_VM" "$DEFAULT_OPENCLAW_LOG_MIRROR_VM" <<'EOS'
set -euo pipefail
src="$1"
dst="$2"
mkdir -p "$dst"
if [[ ! -d "$src" ]]; then
  exit 1
fi
shopt -s nullglob
for f in "$src"/*.log; do
  cp -f "$f" "$dst"/
done
EOS
}

sync_vm_logs_once() {
  if [[ "$(uname -s)" == "Darwin" ]] && [[ -d /Users/ronnie/OrbStack/debian/home/ronnie ]]; then
    sync_vm_logs_once_ssh
    return $?
  fi
  sync_vm_logs_once_local
}

start_sync_loop() {
  (
    while true; do
      sleep "$OPENCLAW_SYNC_INTERVAL_SEC"
      sync_vm_logs_once >/dev/null 2>&1 || true
    done
  ) &
  SYNC_PID="$!"
}

cleanup() {
  if [[ -n "$LOG_MONITOR_PID" ]] && kill -0 "$LOG_MONITOR_PID" 2>/dev/null; then
    kill "$LOG_MONITOR_PID" 2>/dev/null || true
  fi
  if [[ -n "$CACHE_MONITOR_PID" ]] && kill -0 "$CACHE_MONITOR_PID" 2>/dev/null; then
    kill "$CACHE_MONITOR_PID" 2>/dev/null || true
  fi
  if [[ -n "$SYNC_PID" ]] && kill -0 "$SYNC_PID" 2>/dev/null; then
    kill "$SYNC_PID" 2>/dev/null || true
  fi
  if [[ -n "$HIGHLIGHTER_PID" ]] && kill -0 "$HIGHLIGHTER_PID" 2>/dev/null; then
    kill "$HIGHLIGHTER_PID" 2>/dev/null || true
  fi
  if [[ -n "$MERGE_PIPE" ]] && [[ -p "$MERGE_PIPE" ]]; then
    rm -f "$MERGE_PIPE"
  fi
  if [[ -n "$PIPE_DIR" ]] && [[ -d "$PIPE_DIR" ]]; then
    rmdir "$PIPE_DIR" 2>/dev/null || true
  fi
}

select_highlighter() {
  if command -v tspin >/dev/null 2>&1; then
    HIGHLIGHTER=(tspin)
  elif command -v tailspin >/dev/null 2>&1; then
    if tailspin 2>&1 | grep -q "To view current tailspin status on this system"; then
      HIGHLIGHTER=(cat)
      echo "WARN: detected macOS /usr/bin/tailspin (not log highlighter); install 'tspin' for colors" >&2
    else
      HIGHLIGHTER=(tailspin)
    fi
  else
    HIGHLIGHTER=(cat)
    echo "WARN: tailspin/tspin not found; fallback to plain output" >&2
  fi
}

setup_log_monitor() {
  local auto_sync=0
  if [[ -z "$OPENCLAW_LOG_DIR_ARG" ]]; then
    auto_sync=1
  fi

  if [[ "$auto_sync" -eq 1 ]]; then
    OPENCLAW_LOG_DIR="$(map_vm_path_to_mac "$DEFAULT_OPENCLAW_LOG_MIRROR_VM")"
    if mkdir -p "$OPENCLAW_LOG_DIR" && sync_vm_logs_once; then
      echo "INFO mirrored openclaw logs to: $OPENCLAW_LOG_DIR" >&2
      echo "INFO syncing $DEFAULT_OPENCLAW_LOG_SOURCE_VM -> $OPENCLAW_LOG_DIR every ${OPENCLAW_SYNC_INTERVAL_SEC}s" >&2
    else
      echo "WARN unable to mirror logs from VM source: $DEFAULT_OPENCLAW_LOG_SOURCE_VM (host=$OPENCLAW_SYNC_SSH_HOST)" >&2
    fi
    start_sync_loop
  else
    OPENCLAW_LOG_DIR="$OPENCLAW_LOG_DIR_ARG"
  fi

  if [[ -z "$LM_STUDIO_LOG_GLOB_ARG" ]]; then
    LM_STUDIO_LOG_GLOB="$DEFAULT_LM_STUDIO_LOG_GLOB"
  else
    LM_STUDIO_LOG_GLOB="$LM_STUDIO_LOG_GLOB_ARG"
  fi

  if [[ ! -d "$OPENCLAW_LOG_DIR" ]]; then
    if [[ "$auto_sync" -eq 1 ]] && [[ -d "$LEGACY_OPENCLAW_LOG_MAC" ]]; then
      OPENCLAW_LOG_DIR="$LEGACY_OPENCLAW_LOG_MAC"
      echo "WARN fallback to legacy mac tmp path: $OPENCLAW_LOG_DIR" >&2
    else
      echo "ERROR: openclaw log directory not found: $OPENCLAW_LOG_DIR" >&2
      return 1
    fi
  fi

  LATEST_OPENCLAW_LOG="$(ls -1t "$OPENCLAW_LOG_DIR"/*.log 2>/dev/null | head -n 1 || true)"
  if [[ -z "$LATEST_OPENCLAW_LOG" ]]; then
    echo "ERROR: no openclaw .log files found in: $OPENCLAW_LOG_DIR" >&2
    return 1
  fi

  LATEST_SUMMARY_AUDIT_LOG="$(ls -1t "$OPENCLAW_LOG_DIR"/ephemeral-summary-*.log 2>/dev/null | head -n 1 || true)"
  LATEST_LM_STUDIO_LOG="$(ls -1t $LM_STUDIO_LOG_GLOB 2>/dev/null | head -n 1 || true)"

  if [[ -n "$LATEST_SUMMARY_AUDIT_LOG" ]]; then
    SUMMARY_LOG_INPUT="$LATEST_SUMMARY_AUDIT_LOG"
    echo "INFO monitoring summary audit log: $LATEST_SUMMARY_AUDIT_LOG" >&2
  else
    SUMMARY_LOG_INPUT="$LATEST_OPENCLAW_LOG"
    echo "WARN summary audit log not found; fallback to openclaw log: $LATEST_OPENCLAW_LOG" >&2
  fi

  if [[ -n "$LATEST_LM_STUDIO_LOG" ]]; then
    echo "INFO monitoring lm-studio log: $LATEST_LM_STUDIO_LOG" >&2
  else
    echo "WARN lm-studio logs not found via glob: $LM_STUDIO_LOG_GLOB" >&2
  fi

  echo "INFO filters: LLM message count + ephemeral summary status (new lines only)" >&2
}

setup_cache_monitor() {
  if [[ -n "$CACHE_TRACE_FILE_ARG" ]]; then
    CACHE_TRACE_FILE="$CACHE_TRACE_FILE_ARG"
  else
    CACHE_TRACE_FILE="$(resolve_cache_trace_from_config || true)"
    if [[ -z "$CACHE_TRACE_FILE" ]]; then
      if [[ -d "$(dirname "$DEFAULT_CACHE_TRACE_VM")" ]]; then
        CACHE_TRACE_FILE="$DEFAULT_CACHE_TRACE_VM"
      elif [[ -d "$(dirname "$DEFAULT_CACHE_TRACE_MAC")" ]]; then
        CACHE_TRACE_FILE="$DEFAULT_CACHE_TRACE_MAC"
      elif [[ -f "$LEGACY_CACHE_TRACE_VM" ]]; then
        CACHE_TRACE_FILE="$LEGACY_CACHE_TRACE_VM"
      elif [[ -f "$LEGACY_CACHE_TRACE_MAC" ]]; then
        CACHE_TRACE_FILE="$LEGACY_CACHE_TRACE_MAC"
      elif [[ -d "$(dirname "$LEGACY_CACHE_TRACE_VM")" ]]; then
        CACHE_TRACE_FILE="$LEGACY_CACHE_TRACE_VM"
      else
        CACHE_TRACE_FILE="$LEGACY_CACHE_TRACE_MAC"
      fi
    fi
  fi

  if [[ -n "$LASTONE_JSON_FILE_ARG" ]]; then
    LASTONE_JSON_FILE="$LASTONE_JSON_FILE_ARG"
  else
    LASTONE_JSON_FILE="$(dirname "$CACHE_TRACE_FILE")/lastone.json"
  fi

  if ! mkdir -p "$(dirname "$CACHE_TRACE_FILE")"; then
    echo "WARN: cannot create cache trace directory: $(dirname "$CACHE_TRACE_FILE")" >&2
  fi
  if [[ ! -f "$CACHE_TRACE_FILE" ]] && ! touch "$CACHE_TRACE_FILE"; then
    echo "WARN: cannot initialize cache trace file: $CACHE_TRACE_FILE" >&2
  fi
  if [[ ! -r "$CACHE_TRACE_FILE" ]]; then
    echo "ERROR: cache trace file is not readable: $CACHE_TRACE_FILE" >&2
    return 1
  fi
  if ! mkdir -p "$(dirname "$LASTONE_JSON_FILE")" || ! touch "$LASTONE_JSON_FILE"; then
    echo "WARN: cannot initialize lastone output file: $LASTONE_JSON_FILE" >&2
  fi

  echo "INFO monitoring cache trace: $CACHE_TRACE_FILE" >&2
  echo "INFO filter: stage=stream:context (outbound model payload)" >&2
  echo "INFO writing latest stream:context event to: $LASTONE_JSON_FILE" >&2
}

run_log_monitor() {
  local -a tail_input
  if [[ -n "$LATEST_LM_STUDIO_LOG" ]]; then
    tail_input=(tail -n 0 -F "$SUMMARY_LOG_INPUT" "$LATEST_LM_STUDIO_LOG")
  else
    tail_input=(tail -n 0 -F "$SUMMARY_LOG_INPUT")
  fi

  "${tail_input[@]}" | awk -v summary_input="$SUMMARY_LOG_INPUT" '
BEGIN {
  req = 0;
  total = 0;
  summary_ok = 0;
  summary_fail = 0;
  current = summary_input;
}

function extract_num(line, key,    pat, value) {
  pat = "\\\"" key "\\\":[0-9]+";
  if (match(line, pat)) {
    value = substr(line, RSTART, RLENGTH);
    sub("^\\\"" key "\\\":", "", value);
    return value;
  }
  return "-";
}

/^==> .* <==$/ {
  current = $2;
  next;
}

/Running chat completion on conversation with [0-9]+ messages\./ {
  n = $0;
  sub(/.*with /, "", n);
  sub(/ messages.*/, "", n);
  req += 1;
  total += (n + 0);
  avg = (req > 0 ? total / req : 0);
  printf("INFO LLM req=%d messages=%d avg_messages=%.1f src=%s\\n", req, (n + 0), avg, current);
  fflush();
  next;
}

/\\\"type\\\":\\\"summary_updated\\\"/ {
  summary_ok += 1;
  compressed = extract_num($0, "compressedRounds");
  remaining = extract_num($0, "remainingMessages");
  printf("INFO SUMMARY_OK count=%d compressedRounds=%s remainingMessages=%s src=%s\\n", summary_ok, compressed, remaining, current);
  fflush();
  next;
}

/\\\"type\\\":\\\"summary_failed\\\"/ {
  summary_fail += 1;
  pending = extract_num($0, "pendingRounds");
  printf("WARN SUMMARY_FAIL count=%d pendingRounds=%s src=%s\\n", summary_fail, pending, current);
  fflush();
  next;
}

/ephemeral tool context: summary updated/ {
  summary_ok += 1;
  compressed = "-";
  remaining = "-";
  if (match($0, /compressedRounds=[0-9]+/)) {
    compressed = substr($0, RSTART + 17, RLENGTH - 17);
  }
  if (match($0, /remainingMessages=[0-9]+/)) {
    remaining = substr($0, RSTART + 18, RLENGTH - 18);
  }
  printf("INFO SUMMARY_OK count=%d compressedRounds=%s remainingMessages=%s src=%s\\n", summary_ok, compressed, remaining, current);
  fflush();
  next;
}

/ephemeral tool context: summary update failed/ {
  summary_fail += 1;
  printf("WARN SUMMARY_FAIL count=%d src=%s\\n", summary_fail, current);
  fflush();
  next;
}
'
}

run_cache_monitor() {
  tail -n +1 -F "$CACHE_TRACE_FILE" | LASTONE_JSON_FILE="$LASTONE_JSON_FILE" node -e '
const fs = require("node:fs");
const path = require("node:path");
const readline = require("node:readline");

const lastonePath = String(process.env.LASTONE_JSON_FILE || "").trim();

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

let requestCount = 0;
let totalMessages = 0;
let totalToolResults = 0;
let lastWriteError = "";

function writeLastone(event) {
  if (!lastonePath) {
    return;
  }
  try {
    const dir = path.dirname(lastonePath);
    fs.mkdirSync(dir, { recursive: true });
    const tmpPath = `${lastonePath}.tmp`;
    fs.writeFileSync(tmpPath, `${JSON.stringify(event, null, 2)}\n`, "utf8");
    fs.renameSync(tmpPath, lastonePath);
    lastWriteError = "";
  } catch (err) {
    const msg = String(err && err.message ? err.message : err);
    if (msg !== lastWriteError) {
      process.stderr.write(`WARN failed to write lastone.json: ${msg}\n`);
      lastWriteError = msg;
    }
  }
}

function countToolResultsFromMessages(messages) {
  let count = 0;
  for (const msg of messages) {
    if (msg && typeof msg === "object" && msg.role === "toolResult") {
      count += 1;
    }
  }
  return count;
}

function countToolResultsFromRoles(roles) {
  let count = 0;
  for (const role of roles) {
    if (role === "toolResult") {
      count += 1;
    }
  }
  return count;
}

rl.on("line", (line) => {
  const trimmed = String(line || "").trim();
  if (!trimmed) {
    return;
  }

  let event;
  try {
    event = JSON.parse(trimmed);
  } catch {
    return;
  }

  if (!event || event.stage !== "stream:context") {
    return;
  }

  writeLastone(event);

  const messages = Array.isArray(event.messages) ? event.messages : [];
  const messageRoles = Array.isArray(event.messageRoles) ? event.messageRoles : [];
  const messageCount =
    typeof event.messageCount === "number" && Number.isFinite(event.messageCount)
      ? event.messageCount
      : messages.length;

  let toolResultCount = countToolResultsFromMessages(messages);
  if (toolResultCount === 0 && messageRoles.length > 0) {
    toolResultCount = countToolResultsFromRoles(messageRoles);
  }

  requestCount += 1;
  totalMessages += messageCount;
  totalToolResults += toolResultCount;

  const reqPct = messageCount > 0 ? ((toolResultCount * 100) / messageCount).toFixed(1) : "0.0";
  const totalPct =
    totalMessages > 0 ? ((totalToolResults * 100) / totalMessages).toFixed(1) : "0.0";

  const provider = typeof event.provider === "string" ? event.provider : "-";
  const modelId = typeof event.modelId === "string" ? event.modelId : "-";
  const sessionKey = typeof event.sessionKey === "string" ? event.sessionKey : "-";
  const ts = typeof event.ts === "string" ? event.ts : "-";

  process.stdout.write(
    `INFO CACHE_TRACE req=${requestCount} ` +
      `messages=${messageCount} toolResult=${toolResultCount} reqToolResultPct=${reqPct}% ` +
      `totalMessages=${totalMessages} totalToolResult=${totalToolResults} totalToolResultPct=${totalPct}% ` +
      `provider=${provider} model=${modelId} session=${sessionKey} ts=${ts}\n`,
  );
});
'
}

if [[ "$OPENCLAW_MONITOR_LOG" != "1" && "$OPENCLAW_MONITOR_CACHE_TRACE" != "1" ]]; then
  echo "ERROR: both monitors are disabled (OPENCLAW_MONITOR_LOG=0 and OPENCLAW_MONITOR_CACHE_TRACE=0)." >&2
  exit 1
fi

trap cleanup EXIT INT TERM

if [[ "$OPENCLAW_MONITOR_LOG" == "1" ]]; then
  setup_log_monitor
fi
if [[ "$OPENCLAW_MONITOR_CACHE_TRACE" == "1" ]]; then
  setup_cache_monitor
fi

select_highlighter

PIPE_DIR="$(mktemp -d /tmp/openclaw-tailspin.XXXXXX)"
MERGE_PIPE="$PIPE_DIR/stream.pipe"
mkfifo "$MERGE_PIPE"

"${HIGHLIGHTER[@]}" <"$MERGE_PIPE" &
HIGHLIGHTER_PID="$!"

if [[ "$OPENCLAW_MONITOR_LOG" == "1" ]]; then
  run_log_monitor >"$MERGE_PIPE" 2>&1 &
  LOG_MONITOR_PID="$!"
fi
if [[ "$OPENCLAW_MONITOR_CACHE_TRACE" == "1" ]]; then
  run_cache_monitor >"$MERGE_PIPE" 2>&1 &
  CACHE_MONITOR_PID="$!"
fi

while true; do
  if [[ -n "$LOG_MONITOR_PID" ]] && ! kill -0 "$LOG_MONITOR_PID" 2>/dev/null; then
    break
  fi
  if [[ -n "$CACHE_MONITOR_PID" ]] && ! kill -0 "$CACHE_MONITOR_PID" 2>/dev/null; then
    break
  fi
  sleep 1
done
