#!/usr/bin/env python3
"""Command line entry point for the conversation-analysis preview backend."""
from __future__ import annotations

import argparse
import json
import signal
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Sequence

SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from analysis_core.service import AnalysisError, AnalysisService


def _base(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--state-dir", required=True, type=Path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Independent conversation analysis preview")
    commands = parser.add_subparsers(dest="command", required=True)

    configure = commands.add_parser("configure")
    _base(configure)
    configure.add_argument("--transcript", required=True, type=Path)
    configure.add_argument("--session-id", required=True)
    configure.add_argument("--model", required=True)
    configure.add_argument("--auth-home", type=Path)
    configure.add_argument("--codex-bin", default="codex")
    configure.add_argument("--timeout", type=float, default=90.0)
    configure.add_argument("--max-attempts", type=int, default=2)
    configure.add_argument("--max-context-chars", type=int, default=32000)

    for name in ("sync", "status", "disable"):
        command = commands.add_parser(name)
        _base(command)

    work = commands.add_parser("work")
    _base(work)
    work.add_argument("--once", action="store_true")

    watch = commands.add_parser("watch")
    _base(watch)
    watch.add_argument("--poll-seconds", type=float, default=0.5)
    watch.add_argument("--max-cycles", type=int)

    skill = commands.add_parser("extract-skill")
    _base(skill)
    skill.add_argument("--turn-id", required=True)

    analyze = commands.add_parser("analyze-turn")
    _base(analyze)
    analyze.add_argument("--turn-id", required=True)

    retry = commands.add_parser("retry")
    _base(retry)
    retry.add_argument("--job-id", required=True)

    return parser


def _emit(value: Any) -> None:
    print(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))


def run(args: argparse.Namespace) -> Dict[str, Any]:
    if args.command == "configure":
        service = AnalysisService.configure(
            args.state_dir,
            args.transcript,
            args.session_id,
            args.model,
            auth_home=args.auth_home,
            codex_bin=args.codex_bin,
            timeout=args.timeout,
            max_attempts=args.max_attempts,
            max_context_chars=args.max_context_chars,
        )
    else:
        service = AnalysisService(args.state_dir)
    try:
        if args.command == "configure":
            return service.store.snapshot()
        if args.command == "sync":
            return service.sync()
        if args.command == "status":
            return service.store.snapshot()
        if args.command == "disable":
            return service.disable()
        if args.command == "work":
            service.work(once=args.once)
            return service.store.snapshot()
        if args.command == "watch":
            return service.watch(poll_seconds=max(0.01, args.poll_seconds), max_cycles=args.max_cycles)
        if args.command == "extract-skill":
            return service.extract_skill(args.turn_id)
        if args.command == "analyze-turn":
            return service.analyze_turn(args.turn_id)
        if args.command == "retry":
            return service.retry(args.job_id)
        raise AnalysisError("unknown_command")
    finally:
        service.close()


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    previous_handlers = {}
    def interrupt_handler(_signum, _frame):
        raise KeyboardInterrupt()

    for signal_name in ("SIGINT", "SIGTERM"):
        signal_value = getattr(signal, signal_name, None)
        if signal_value is not None:
            previous_handlers[signal_value] = signal.getsignal(signal_value)
            signal.signal(signal_value, interrupt_handler)
    try:
        args = parser.parse_args(argv)
        _emit(run(args))
        return 0
    except (AnalysisError, ValueError, OSError) as error:
        code = getattr(error, "code", None) or str(error) or "analysis_error"
        print(json.dumps({"ok": False, "error": code}, ensure_ascii=False), file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130
    finally:
        for signal_value, handler in previous_handlers.items():
            signal.signal(signal_value, handler)


if __name__ == "__main__":
    raise SystemExit(main())
