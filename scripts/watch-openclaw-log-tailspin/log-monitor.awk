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
