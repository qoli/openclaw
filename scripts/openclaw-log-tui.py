#!/usr/bin/env python3
"""Structured TUI viewer for watch-openclaw-log-tailspin.sh output."""

from __future__ import annotations

import argparse
import curses
import queue
import re
import subprocess
import sys
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Deque


LLM_RE = re.compile(r"^INFO LLM req=(\d+) messages=(\d+) avg_messages=([0-9.]+) src=(.+)$")
SUMMARY_OK_RE = re.compile(
    r"^INFO SUMMARY_OK count=(\d+) compressedRounds=([^ ]+) remainingMessages=([^ ]+) src=(.+)$",
)
SUMMARY_FAIL_RE = re.compile(r"^WARN SUMMARY_FAIL count=(\d+)(?: pendingRounds=([^ ]+))? src=(.+)$")
CACHE_RE = re.compile(
    r"^INFO CACHE_TRACE req=(\d+) messages=(\d+) toolResult=(\d+) reqToolResultPct=([0-9.]+)% "
    r"totalMessages=(\d+) totalToolResult=(\d+) totalToolResultPct=([0-9.]+)% "
    r"provider=([^ ]+) model=([^ ]+) session=([^ ]+) ts=(.+)$",
)
ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
RECENT_PER_GROUP = 12


@dataclass
class Counters:
    llm_req: int = 0
    llm_messages: int = 0
    llm_avg: float = 0.0
    summary_ok: int = 0
    summary_fail: int = 0
    cache_req: int = 0
    cache_messages: int = 0
    cache_tool_result: int = 0
    cache_req_pct: float = 0.0
    cache_total_messages: int = 0
    cache_total_tool_result: int = 0
    cache_total_pct: float = 0.0
    cache_provider: str = "-"
    cache_model: str = "-"
    cache_session: str = "-"
    cache_ts: str = "-"


class TuiState:
    def __init__(self, max_events: int):
        self.counters = Counters()
        self.lm_events: Deque[str] = deque(maxlen=max_events)
        self.openclaw_events: Deque[str] = deque(maxlen=max_events)
        self.warnings: Deque[str] = deque(maxlen=max_events)
        self.raw: Deque[str] = deque(maxlen=max_events)
        self.total_lines = 0
        self.parsed_lines = 0
        self.started_at = time.time()
        self.source_closed = False
        self.source_mode = "command"
        self.source_desc = ""

    def push_raw(self, line: str) -> None:
        self.total_lines += 1
        self.raw.append(line)

    def push_event(self, group: str, line: str) -> None:
        self.parsed_lines += 1
        if group == "lm":
            self.lm_events.append(line)
            return
        self.openclaw_events.append(line)

    def push_warning(self, line: str) -> None:
        self.warnings.append(line)


def shorten(text: str, width: int) -> str:
    if width <= 0:
        return ""
    if len(text) <= width:
        return text
    if width <= 3:
        return text[:width]
    return f"{text[:width - 3]}..."


def safe_add(stdscr: curses.window, y: int, x: int, text: str, color: int = 0) -> None:
    h, w = stdscr.getmaxyx()
    if y < 0 or y >= h or x >= w:
        return
    clipped = shorten(text, w - x)
    if not clipped:
        return
    try:
        stdscr.addstr(y, x, clipped, color)
    except curses.error:
        return


def classify_group(src_hint: str, line: str) -> str:
    text = f"{src_hint} {line}".lower()
    if "lm-studio" in text or "lm studio" in text:
        return "lm"
    return "openclaw"


def event_color(item: str, colors: dict[str, int]) -> int:
    if item.startswith("[SUM-]") or item.startswith("[LOG] ERROR"):
        return colors["error"]
    if item.startswith("[LOG] WARN"):
        return colors["warn"]
    if item.startswith("[RAW]"):
        return colors["muted"]
    return colors["ok"]


def parse_line(state: TuiState, line: str) -> None:
    clean = ANSI_RE.sub("", line).strip()
    if not clean:
        return

    state.push_raw(clean)

    llm = LLM_RE.match(clean)
    if llm:
        req, messages, avg, src = llm.groups()
        state.counters.llm_req = int(req)
        state.counters.llm_messages = int(messages)
        state.counters.llm_avg = float(avg)
        group = classify_group(src, clean)
        state.push_event(group, f"[LLM] req={req} messages={messages} avg={avg} src={src}")
        return

    summary_ok = SUMMARY_OK_RE.match(clean)
    if summary_ok:
        count, compressed, remaining, src = summary_ok.groups()
        state.counters.summary_ok = int(count)
        group = classify_group(src, clean)
        state.push_event(group, f"[SUM+] count={count} compressed={compressed} remaining={remaining} src={src}")
        return

    summary_fail = SUMMARY_FAIL_RE.match(clean)
    if summary_fail:
        count, pending, src = summary_fail.groups()
        state.counters.summary_fail = int(count)
        pending_part = pending if pending is not None else "-"
        msg = f"[SUM-] count={count} pending={pending_part} src={src}"
        group = classify_group(src, clean)
        state.push_event(group, msg)
        state.push_warning(msg)
        return

    cache = CACHE_RE.match(clean)
    if cache:
        (
            req,
            messages,
            tool_result,
            req_pct,
            total_messages,
            total_tool_result,
            total_pct,
            provider,
            model,
            session,
            ts,
        ) = cache.groups()
        ctr = state.counters
        ctr.cache_req = int(req)
        ctr.cache_messages = int(messages)
        ctr.cache_tool_result = int(tool_result)
        ctr.cache_req_pct = float(req_pct)
        ctr.cache_total_messages = int(total_messages)
        ctr.cache_total_tool_result = int(total_tool_result)
        ctr.cache_total_pct = float(total_pct)
        ctr.cache_provider = provider
        ctr.cache_model = model
        ctr.cache_session = session
        ctr.cache_ts = ts
        state.push_event(
            "openclaw",
            "[CACHE] "
            f"req={req} msg={messages} tool={tool_result} reqPct={req_pct}% "
            f"total={total_tool_result}/{total_messages} totalPct={total_pct}% model={model}",
        )
        return

    if clean.startswith("WARN") or clean.startswith("ERROR"):
        group = classify_group("", clean)
        state.push_warning(clean)
        state.push_event(group, f"[LOG] {clean}")
        return

    group = classify_group("", clean)
    state.push_event(group, f"[RAW] {clean}")


def read_stream(stream, out_queue: queue.Queue[str | None], stop_event: threading.Event) -> None:
    while not stop_event.is_set():
        line = stream.readline()
        if not line:
            break
        out_queue.put(line.rstrip("\n"))
    out_queue.put(None)


def init_colors() -> dict[str, int]:
    if not curses.has_colors():
        return {
            "header": curses.A_BOLD,
            "ok": curses.A_NORMAL,
            "warn": curses.A_BOLD,
            "error": curses.A_BOLD,
            "muted": curses.A_DIM,
        }

    curses.start_color()
    curses.use_default_colors()
    curses.init_pair(1, curses.COLOR_CYAN, -1)
    curses.init_pair(2, curses.COLOR_GREEN, -1)
    curses.init_pair(3, curses.COLOR_YELLOW, -1)
    curses.init_pair(4, curses.COLOR_RED, -1)
    curses.init_pair(5, curses.COLOR_WHITE, -1)
    return {
        "header": curses.color_pair(1) | curses.A_BOLD,
        "ok": curses.color_pair(2),
        "warn": curses.color_pair(3) | curses.A_BOLD,
        "error": curses.color_pair(4) | curses.A_BOLD,
        "muted": curses.color_pair(5) | curses.A_DIM,
    }


def draw(stdscr: curses.window, state: TuiState, colors: dict[str, int]) -> None:
    stdscr.erase()
    h, w = stdscr.getmaxyx()

    header = "OpenClaw Log TUI  |  q: quit  r: clear  p: pause/resume parsing"
    safe_add(stdscr, 0, 0, shorten(header, w), colors["header"])

    runtime = int(time.time() - state.started_at)
    mode = state.source_mode
    status = "closed" if state.source_closed else "streaming"
    src_text = f"{mode}={state.source_desc}"
    line1 = (
        f"status={status} lines={state.total_lines} parsed={state.parsed_lines} "
        f"runtime={runtime}s {src_text}"
    )
    safe_add(stdscr, 1, 0, shorten(line1, w), colors["muted"])

    safe_add(stdscr, 3, 0, "Summary", colors["header"])
    ctr = state.counters
    summary1 = (
        f"LLM req={ctr.llm_req} lastMessages={ctr.llm_messages} avgMessages={ctr.llm_avg:.1f}  "
        f"Summary ok={ctr.summary_ok} fail={ctr.summary_fail}"
    )
    safe_add(stdscr, 4, 0, shorten(summary1, w), colors["ok"])
    summary2 = (
        f"Cache req={ctr.cache_req} msg={ctr.cache_messages} tool={ctr.cache_tool_result} reqPct={ctr.cache_req_pct:.1f}%  "
        f"totalTool={ctr.cache_total_tool_result}/{ctr.cache_total_messages} totalPct={ctr.cache_total_pct:.1f}%"
    )
    safe_add(stdscr, 5, 0, shorten(summary2, w), colors["ok"])
    summary3 = (
        f"Cache provider={ctr.cache_provider} model={ctr.cache_model} session={ctr.cache_session} ts={ctr.cache_ts}"
    )
    safe_add(stdscr, 6, 0, shorten(summary3, w), colors["muted"])

    lm_top = 8
    safe_add(stdscr, lm_top, 0, f"LM Studio (latest {RECENT_PER_GROUP})", colors["header"])
    lm_lines = list(state.lm_events)[-RECENT_PER_GROUP:]
    for idx, item in enumerate(lm_lines):
        safe_add(stdscr, lm_top + 1 + idx, 0, shorten(item, w), event_color(item, colors))

    oc_top = lm_top + RECENT_PER_GROUP + 2
    safe_add(stdscr, oc_top, 0, f"OpenClaw (latest {RECENT_PER_GROUP})", colors["header"])
    oc_lines = list(state.openclaw_events)[-RECENT_PER_GROUP:]
    for idx, item in enumerate(oc_lines):
        safe_add(stdscr, oc_top + 1 + idx, 0, shorten(item, w), event_color(item, colors))

    footer = (
        f"LM events={len(state.lm_events)}  OpenClaw events={len(state.openclaw_events)}  "
        f"Warnings={len(state.warnings)}"
    )
    safe_add(stdscr, h - 1, 0, shorten(footer, w), colors["muted"])

    stdscr.refresh()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Structured TUI for OpenClaw logs generated by watch-openclaw-log-tailspin.sh",
    )
    parser.add_argument(
        "--watch-cmd",
        default="./watch-openclaw-log-tailspin.sh",
        help="Command to run for log streaming (default: ./watch-openclaw-log-tailspin.sh)",
    )
    parser.add_argument(
        "--max-events",
        type=int,
        default=400,
        help="Maximum retained events per group and warning/raw buffers in memory",
    )
    parser.add_argument(
        "watch_args",
        nargs=argparse.REMAINDER,
        help="Arguments passed to watch command after '--'",
    )
    args = parser.parse_args()
    if args.watch_args and args.watch_args[0] == "--":
        args.watch_args = args.watch_args[1:]
    return args


def run_tui(stdscr: curses.window, state: TuiState, line_queue: queue.Queue[str | None]) -> None:
    colors = init_colors()
    paused = False
    stdscr.nodelay(True)
    try:
        curses.curs_set(0)
    except curses.error:
        pass

    while True:
        drained = 0
        while drained < 200:
            try:
                line = line_queue.get_nowait()
            except queue.Empty:
                break

            if line is None:
                state.source_closed = True
                break

            if not paused:
                parse_line(state, line)
            drained += 1

        draw(stdscr, state, colors)

        ch = stdscr.getch()
        if ch in (ord("q"), ord("Q")):
            return
        if ch in (ord("r"), ord("R")):
            state.lm_events.clear()
            state.openclaw_events.clear()
            state.warnings.clear()
            state.raw.clear()
        if ch in (ord("p"), ord("P")):
            paused = not paused

        time.sleep(0.08)


def main() -> int:
    args = parse_args()
    state = TuiState(max_events=max(50, args.max_events))
    line_queue: queue.Queue[str | None] = queue.Queue()
    stop_event = threading.Event()

    proc: subprocess.Popen[str] | None = None
    try:
        cmd = [args.watch_cmd, *args.watch_args]
        state.source_mode = "command"
        state.source_desc = " ".join(cmd)
        proc = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        if proc.stdout is None:
            raise RuntimeError("failed to open subprocess stdout")
        reader = threading.Thread(
            target=read_stream,
            args=(proc.stdout, line_queue, stop_event),
            daemon=True,
        )
        reader.start()

        curses.wrapper(run_tui, state, line_queue)
    except KeyboardInterrupt:
        pass
    except OSError as exc:
        print(f"ERROR failed to start watch command: {exc}", file=sys.stderr, flush=True)
        return 1
    finally:
        stop_event.set()
        if proc is not None and proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
        if proc is not None and proc.stdout is not None:
            proc.stdout.close()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
