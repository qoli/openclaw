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
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_MONITOR_AWK="$SCRIPT_DIR/scripts/watch-openclaw-log-tailspin/log-monitor.awk"
CACHE_MONITOR_NODE="$SCRIPT_DIR/scripts/watch-openclaw-log-tailspin/cache-monitor.mjs"

SYNC_PID=""
LOG_MONITOR_PID=""
CACHE_MONITOR_PID=""
HIGHLIGHTER_PID=""
PIPE_DIR=""
MERGE_PIPE=""
HIGHLIGHTER=()

log_info() {
  echo "INFO $*" >&2
}

log_warn() {
  echo "WARN $*" >&2
}

log_error() {
  echo "ERROR: $*" >&2
}

kill_if_running() {
  local pid="$1"
  if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
  fi
}

latest_file_in_dir() {
  local dir="$1"
  local pattern="$2"
  ls -1t "$dir"/$pattern 2>/dev/null | head -n 1 || true
}

latest_file_from_glob() {
  local glob="$1"
  # shellcheck disable=SC2086
  ls -1t $glob 2>/dev/null | head -n 1 || true
}

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
  kill_if_running "$LOG_MONITOR_PID"
  kill_if_running "$CACHE_MONITOR_PID"
  kill_if_running "$SYNC_PID"
  kill_if_running "$HIGHLIGHTER_PID"
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
      log_warn "detected macOS /usr/bin/tailspin (not log highlighter); install 'tspin' for colors"
    else
      HIGHLIGHTER=(tailspin)
    fi
  else
    HIGHLIGHTER=(cat)
    log_warn "tailspin/tspin not found; fallback to plain output"
  fi
}

validate_monitor_scripts() {
  if [[ "$OPENCLAW_MONITOR_LOG" == "1" ]] && [[ ! -f "$LOG_MONITOR_AWK" ]]; then
    log_error "log monitor parser not found: $LOG_MONITOR_AWK"
    return 1
  fi
  if [[ "$OPENCLAW_MONITOR_CACHE_TRACE" == "1" ]] && [[ ! -f "$CACHE_MONITOR_NODE" ]]; then
    log_error "cache monitor parser not found: $CACHE_MONITOR_NODE"
    return 1
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
      log_info "mirrored openclaw logs to: $OPENCLAW_LOG_DIR"
      log_info "syncing $DEFAULT_OPENCLAW_LOG_SOURCE_VM -> $OPENCLAW_LOG_DIR every ${OPENCLAW_SYNC_INTERVAL_SEC}s"
    else
      log_warn "unable to mirror logs from VM source: $DEFAULT_OPENCLAW_LOG_SOURCE_VM (host=$OPENCLAW_SYNC_SSH_HOST)"
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
      log_warn "fallback to legacy mac tmp path: $OPENCLAW_LOG_DIR"
    else
      log_error "openclaw log directory not found: $OPENCLAW_LOG_DIR"
      return 1
    fi
  fi

  LATEST_OPENCLAW_LOG="$(latest_file_in_dir "$OPENCLAW_LOG_DIR" "*.log")"
  if [[ -z "$LATEST_OPENCLAW_LOG" ]]; then
    log_error "no openclaw .log files found in: $OPENCLAW_LOG_DIR"
    return 1
  fi

  LATEST_SUMMARY_AUDIT_LOG="$(latest_file_in_dir "$OPENCLAW_LOG_DIR" "ephemeral-summary-*.log")"
  LATEST_LM_STUDIO_LOG="$(latest_file_from_glob "$LM_STUDIO_LOG_GLOB")"

  if [[ -n "$LATEST_SUMMARY_AUDIT_LOG" ]]; then
    SUMMARY_LOG_INPUT="$LATEST_SUMMARY_AUDIT_LOG"
    log_info "monitoring summary audit log: $LATEST_SUMMARY_AUDIT_LOG"
  else
    SUMMARY_LOG_INPUT="$LATEST_OPENCLAW_LOG"
    log_warn "summary audit log not found; fallback to openclaw log: $LATEST_OPENCLAW_LOG"
  fi

  if [[ -n "$LATEST_LM_STUDIO_LOG" ]]; then
    log_info "monitoring lm-studio log: $LATEST_LM_STUDIO_LOG"
  else
    log_warn "lm-studio logs not found via glob: $LM_STUDIO_LOG_GLOB"
  fi

  log_info "filters: LLM message count + ephemeral summary status (new lines only)"
}

pick_default_cache_trace_file() {
  if [[ -d "$(dirname "$DEFAULT_CACHE_TRACE_VM")" ]]; then
    echo "$DEFAULT_CACHE_TRACE_VM"
  elif [[ -d "$(dirname "$DEFAULT_CACHE_TRACE_MAC")" ]]; then
    echo "$DEFAULT_CACHE_TRACE_MAC"
  elif [[ -f "$LEGACY_CACHE_TRACE_VM" ]]; then
    echo "$LEGACY_CACHE_TRACE_VM"
  elif [[ -f "$LEGACY_CACHE_TRACE_MAC" ]]; then
    echo "$LEGACY_CACHE_TRACE_MAC"
  elif [[ -d "$(dirname "$LEGACY_CACHE_TRACE_VM")" ]]; then
    echo "$LEGACY_CACHE_TRACE_VM"
  else
    echo "$LEGACY_CACHE_TRACE_MAC"
  fi
}

setup_cache_monitor() {
  if [[ -n "$CACHE_TRACE_FILE_ARG" ]]; then
    CACHE_TRACE_FILE="$CACHE_TRACE_FILE_ARG"
  else
    CACHE_TRACE_FILE="$(resolve_cache_trace_from_config || true)"
    if [[ -z "$CACHE_TRACE_FILE" ]]; then
      CACHE_TRACE_FILE="$(pick_default_cache_trace_file)"
    fi
  fi

  if [[ -n "$LASTONE_JSON_FILE_ARG" ]]; then
    LASTONE_JSON_FILE="$LASTONE_JSON_FILE_ARG"
  else
    LASTONE_JSON_FILE="$(dirname "$CACHE_TRACE_FILE")/lastone.json"
  fi

  if ! mkdir -p "$(dirname "$CACHE_TRACE_FILE")"; then
    log_warn "cannot create cache trace directory: $(dirname "$CACHE_TRACE_FILE")"
  fi
  if [[ ! -f "$CACHE_TRACE_FILE" ]] && ! touch "$CACHE_TRACE_FILE"; then
    log_warn "cannot initialize cache trace file: $CACHE_TRACE_FILE"
  fi
  if [[ ! -r "$CACHE_TRACE_FILE" ]]; then
    log_error "cache trace file is not readable: $CACHE_TRACE_FILE"
    return 1
  fi
  if ! mkdir -p "$(dirname "$LASTONE_JSON_FILE")" || ! touch "$LASTONE_JSON_FILE"; then
    log_warn "cannot initialize lastone output file: $LASTONE_JSON_FILE"
  fi

  log_info "monitoring cache trace: $CACHE_TRACE_FILE"
  log_info "filter: stage=stream:context (outbound model payload)"
  log_info "writing latest stream:context event to: $LASTONE_JSON_FILE"
}

run_log_monitor() {
  local -a tail_input
  if [[ -n "$LATEST_LM_STUDIO_LOG" ]]; then
    tail_input=(tail -n 0 -F "$SUMMARY_LOG_INPUT" "$LATEST_LM_STUDIO_LOG")
  else
    tail_input=(tail -n 0 -F "$SUMMARY_LOG_INPUT")
  fi

  "${tail_input[@]}" | awk -v summary_input="$SUMMARY_LOG_INPUT" -f "$LOG_MONITOR_AWK"
}

run_cache_monitor() {
  tail -n +1 -F "$CACHE_TRACE_FILE" | LASTONE_JSON_FILE="$LASTONE_JSON_FILE" node "$CACHE_MONITOR_NODE"
}

setup_merge_pipe() {
  PIPE_DIR="$(mktemp -d /tmp/openclaw-tailspin.XXXXXX)"
  MERGE_PIPE="$PIPE_DIR/stream.pipe"
  mkfifo "$MERGE_PIPE"

  "${HIGHLIGHTER[@]}" <"$MERGE_PIPE" &
  HIGHLIGHTER_PID="$!"
}

start_monitors() {
  if [[ "$OPENCLAW_MONITOR_LOG" == "1" ]]; then
    run_log_monitor >"$MERGE_PIPE" 2>&1 &
    LOG_MONITOR_PID="$!"
  fi
  if [[ "$OPENCLAW_MONITOR_CACHE_TRACE" == "1" ]]; then
    run_cache_monitor >"$MERGE_PIPE" 2>&1 &
    CACHE_MONITOR_PID="$!"
  fi
}

wait_for_monitors() {
  while true; do
    if [[ -n "$LOG_MONITOR_PID" ]] && ! kill -0 "$LOG_MONITOR_PID" 2>/dev/null; then
      break
    fi
    if [[ -n "$CACHE_MONITOR_PID" ]] && ! kill -0 "$CACHE_MONITOR_PID" 2>/dev/null; then
      break
    fi
    sleep 1
  done
}

main() {
  if [[ "$OPENCLAW_MONITOR_LOG" != "1" && "$OPENCLAW_MONITOR_CACHE_TRACE" != "1" ]]; then
    log_error "both monitors are disabled (OPENCLAW_MONITOR_LOG=0 and OPENCLAW_MONITOR_CACHE_TRACE=0)."
    exit 1
  fi

  trap cleanup EXIT INT TERM
  validate_monitor_scripts

  if [[ "$OPENCLAW_MONITOR_LOG" == "1" ]]; then
    setup_log_monitor
  fi
  if [[ "$OPENCLAW_MONITOR_CACHE_TRACE" == "1" ]]; then
    setup_cache_monitor
  fi

  select_highlighter
  setup_merge_pipe
  start_monitors
  wait_for_monitors
}

main "$@"
