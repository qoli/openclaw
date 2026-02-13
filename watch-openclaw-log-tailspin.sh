#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_LOG_DIR="${1:-/Users/ronnie/OrbStack/debian/mnt/linux/tmp/openclaw}"
LM_STUDIO_LOG_GLOB="${2:-/Users/ronnie/.cache/lm-studio/server-logs/*/*.log}"

if [[ ! -d "$OPENCLAW_LOG_DIR" ]]; then
  echo "ERROR: openclaw log directory not found: $OPENCLAW_LOG_DIR" >&2
  exit 1
fi

LATEST_OPENCLAW_LOG="$(ls -1t "$OPENCLAW_LOG_DIR"/*.log 2>/dev/null | head -n 1 || true)"
if [[ -z "$LATEST_OPENCLAW_LOG" ]]; then
  echo "ERROR: no openclaw .log files found in: $OPENCLAW_LOG_DIR" >&2
  exit 1
fi

LATEST_SUMMARY_AUDIT_LOG="$(ls -1t "$OPENCLAW_LOG_DIR"/ephemeral-summary-*.log 2>/dev/null | head -n 1 || true)"
LATEST_LM_STUDIO_LOG="$(ls -1t $LM_STUDIO_LOG_GLOB 2>/dev/null | head -n 1 || true)"

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

if [[ -n "$LATEST_LM_STUDIO_LOG" ]]; then
  TAIL_INPUT=(tail -n 0 -F "$SUMMARY_LOG_INPUT" "$LATEST_LM_STUDIO_LOG")
else
  TAIL_INPUT=(tail -n 0 -F "$SUMMARY_LOG_INPUT")
fi

"${TAIL_INPUT[@]}" | awk -v summary_input="$SUMMARY_LOG_INPUT" '
BEGIN {
  req = 0;
  total = 0;
  summary_ok = 0;
  summary_fail = 0;
  current = summary_input;
}

function extract_num(line, key,    pat, value) {
  pat = "\"" key "\":[0-9]+";
  if (match(line, pat)) {
    value = substr(line, RSTART, RLENGTH);
    sub("^\"" key "\":", "", value);
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
  printf("INFO LLM req=%d messages=%d avg_messages=%.1f src=%s\n", req, (n + 0), avg, current);
  fflush();
  next;
}

/\"type\":\"summary_updated\"/ {
  summary_ok += 1;
  compressed = extract_num($0, "compressedRounds");
  remaining = extract_num($0, "remainingMessages");
  printf("INFO SUMMARY_OK count=%d compressedRounds=%s remainingMessages=%s src=%s\n", summary_ok, compressed, remaining, current);
  fflush();
  next;
}

/\"type\":\"summary_failed\"/ {
  summary_fail += 1;
  pending = extract_num($0, "pendingRounds");
  printf("WARN SUMMARY_FAIL count=%d pendingRounds=%s src=%s\n", summary_fail, pending, current);
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
  printf("INFO SUMMARY_OK count=%d compressedRounds=%s remainingMessages=%s src=%s\n", summary_ok, compressed, remaining, current);
  fflush();
  next;
}

/ephemeral tool context: summary update failed/ {
  summary_fail += 1;
  printf("WARN SUMMARY_FAIL count=%d src=%s\n", summary_fail, current);
  fflush();
  next;
}
' | "${HIGHLIGHTER[@]}"
