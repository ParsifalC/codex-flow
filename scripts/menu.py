#!/usr/bin/env python3
"""Moyu-style interactive management console for codex-flow."""

from __future__ import annotations

import os
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import Any

# Import telemetry helpers
try:
    from . import telemetry
except ImportError:
    import telemetry  # type: ignore


ROOT_DIR = Path(__file__).resolve().parents[1]
CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
STATE_DIR = CODEX_HOME / "codex-flow"


class ConsoleStyle:
    """Terminal styling with ANSI fallback."""

    def __init__(self) -> None:
        self.enabled = (
            sys.stdout.isatty()
            and os.environ.get("NO_COLOR") != "1"
            and os.environ.get("TERM") != "dumb"
        )
        if self.enabled:
            self.BOLD = "\033[1m"
            self.DIM = "\033[2m"
            self.CYAN = "\033[36m"
            self.GREEN = "\033[32m"
            self.YELLOW = "\033[33m"
            self.RED = "\033[31m"
            self.MAGENTA = "\033[35m"
            self.RESET = "\033[0m"
        else:
            self.BOLD = ""
            self.DIM = ""
            self.CYAN = ""
            self.GREEN = ""
            self.YELLOW = ""
            self.RED = ""
            self.MAGENTA = ""
            self.RESET = ""


style = ConsoleStyle()


def display_width(s: str) -> int:
    """Calculate terminal display width considering fullwidth/CJK characters."""
    width = 0
    for ch in s:
        if unicodedata.east_asian_width(ch) in ("W", "F"):
            width += 2
        else:
            width += 1
    return width


def truncate_display(s: str, max_width: int) -> str:
    """Truncate a string to fit max_width visual columns."""
    cur = 0
    res: list[str] = []
    for ch in s:
        w = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if cur + w > max_width:
            break
        res.append(ch)
        cur += w
    return "".join(res)


def pad_display(s: str, target_width: int, align: str = "left") -> str:
    """Pad string to target display width."""
    w = display_width(s)
    pad = max(0, target_width - w)
    if align == "right":
        return (" " * pad) + s
    return s + (" " * pad)


def print_banner(version: str = "1.0.0") -> None:
    print(f"\n{style.DIM}╭────────────────────────────────────────────────────────────────────╮{style.RESET}")
    title = f"🚀 codex-flow 控制台 (v{version})"
    pad_len = max(0, 66 - display_width(title))
    left_pad = pad_len // 2
    right_pad = pad_len - left_pad
    print(f"{style.DIM}│{style.RESET}{' ' * left_pad}{style.BOLD}{style.CYAN}{title}{style.RESET}{' ' * right_pad}{style.DIM}│{style.RESET}")
    sub = "FlowPilot 智能编排 · 确定性任务遥测 · 本地 Benchmark 验证"
    sub_pad = max(0, 66 - display_width(sub))
    sub_l = sub_pad // 2
    sub_r = sub_pad - sub_l
    print(f"{style.DIM}│{style.RESET}{' ' * sub_l}{style.DIM}{sub}{style.RESET}{' ' * sub_r}{style.DIM}│{style.RESET}")
    print(f"{style.DIM}╰────────────────────────────────────────────────────────────────────╯{style.RESET}\n")


def get_version() -> str:
    ver_file = ROOT_DIR / "VERSION"
    if ver_file.exists():
        try:
            return ver_file.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    ver_state = STATE_DIR / "version"
    if ver_state.exists():
        try:
            return ver_state.read_text(encoding="utf-8").strip()
        except OSError:
            pass
    return "1.0.0"


def pause_prompt(prompt: str = "按 Enter 键返回...") -> None:
    try:
        input(f"\n{style.DIM}{prompt}{style.RESET}")
    except (KeyboardInterrupt, EOFError):
        pass


def handle_show_last() -> None:
    print(f"\n{style.BOLD}📊 最新任务遥测摘要:{style.RESET}")
    ret = telemetry.show_last(as_json=False)
    if ret == 0:
        pause_prompt()


def handle_show_history() -> None:
    limit = 10
    project: str | None = None
    today = False

    while True:
        runs = telemetry.list_runs(limit=limit, project=project, today=today)
        print(telemetry.render_run_list(runs, project=project, today=today))

        print(f"{style.BOLD}快捷操作:{style.RESET}")
        if runs:
            max_idx = len(runs)
            print(f"  [{style.CYAN}1-{max_idx}{style.RESET}] 查看对应序号的任务卡片详情")
        print(f"  [{style.CYAN}p{style.RESET}] 按项目名称过滤 (当前: {project or '全部'})")
        print(f"  [{style.CYAN}t{style.RESET}] 切换仅看今天 (当前: {'是' if today else '否'})")
        print(f"  [{style.CYAN}s{style.RESET}] 查看项目聚合统计 (Stats)")
        print(f"  [{style.CYAN}r{style.RESET}] 刷新列表")
        print(f"  [{style.CYAN}0{style.RESET}] 返回主菜单")

        try:
            choice = input(f"\n{style.CYAN}请输入选项: {style.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            break

        if choice in ("0", "q", "exit", "back"):
            break
        elif choice == "r":
            continue
        elif choice == "t":
            today = not today
            continue
        elif choice == "p":
            try:
                p_in = input(f"{style.CYAN}请输入项目名称 (留空清除过滤): {style.RESET}").strip()
                project = p_in if p_in else None
            except (KeyboardInterrupt, EOFError):
                pass
            continue
        elif choice == "s":
            handle_show_stats(project)
            continue
        elif choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(runs):
                selected = runs[idx - 1]
                telemetry.enrich_run_metadata(selected)
                print(telemetry.render_summary(selected))
                pause_prompt("按 Enter 键返回历史列表...")
            else:
                print(f"{style.RED}❌ 序号超出范围 [1-{len(runs)}]{style.RESET}")
                pause_prompt()
        else:
            print(f"{style.RED}❌ 无效选项: {choice}{style.RESET}")


def handle_show_stats(default_project: str | None = None) -> None:
    target_project = default_project
    if target_project is None:
        try:
            p_in = input(f"{style.CYAN}请输入要统计的项目名称 (直接回车统计全量): {style.RESET}").strip()
            target_project = p_in if p_in else None
        except (KeyboardInterrupt, EOFError):
            return

    stats = telemetry.aggregate_project_stats(project=target_project, days=30)
    print(telemetry.render_project_stats(stats))
    pause_prompt()


def handle_show_status() -> None:
    print(f"\n{style.BOLD}🎯 当前 FlowPilot 策略状态:{style.RESET}\n")
    if os.name != "nt":
        bin_script = ROOT_DIR / "bin" / "codex-flow"
        if bin_script.exists():
            subprocess.run(["bash", str(bin_script), "status"])
        else:
            subprocess.run(["codex-flow", "status"])
    else:
        subprocess.run(["codex-flow.cmd", "status"], shell=True)
    pause_prompt()


def handle_run_doctor() -> None:
    print(f"\n{style.BOLD}🩺 正在运行系统诊断检查...{style.RESET}\n")
    if os.name != "nt":
        doc_script = ROOT_DIR / "scripts" / "doctor"
        if doc_script.exists():
            subprocess.run(["bash", str(doc_script)])
        else:
            subprocess.run(["codex-flow", "doctor"])
    else:
        subprocess.run(["codex-flow.cmd", "doctor"], shell=True)
    pause_prompt()


def handle_run_benchmark() -> None:
    print(f"\n{style.BOLD}⚡ 本地快速 Benchmark 评测:{style.RESET}")
    print(f"{style.DIM}将调用本地登录的 Codex 执行 6 个典型任务以测量当前模型与编排效果。{style.RESET}")
    try:
        confirm = input(f"{style.YELLOW}确定开始执行吗？[y/N]: {style.RESET}").strip().lower()
    except (KeyboardInterrupt, EOFError):
        return
    if confirm in ("y", "yes"):
        bench_script = ROOT_DIR / "scripts" / "benchmark-local.py"
        if bench_script.exists():
            subprocess.run([sys.executable, str(bench_script), "quick"])
        else:
            subprocess.run(["codex-flow", "benchmark-local", "quick"])
        pause_prompt()


def handle_update() -> None:
    print(f"\n{style.BOLD}🔄 正在检查并更新 codex-flow...{style.RESET}\n")
    if os.name != "nt":
        bin_script = ROOT_DIR / "bin" / "codex-flow"
        if bin_script.exists():
            subprocess.run(["bash", str(bin_script), "update"])
        else:
            subprocess.run(["codex-flow", "update"])
    else:
        subprocess.run(["codex-flow.cmd", "update"], shell=True)
    pause_prompt()


def main_menu() -> int:
    version = get_version()
    while True:
        print_banner(version)
        print(f"  [{style.CYAN}1{style.RESET}] 📊 查看最新任务卡片 {style.DIM}(usage last){style.RESET}")
        print(f"  [{style.CYAN}2{style.RESET}] 📜 浏览历史任务列表 {style.DIM}(usage list){style.RESET}")
        print(f"  [{style.CYAN}3{style.RESET}] 📈 项目聚合统计分析 {style.DIM}(usage stats){style.RESET}")
        print(f"  [{style.CYAN}4{style.RESET}] 🎯 查看生效策略配置 {style.DIM}(status){style.RESET}")
        print(f"  [{style.CYAN}5{style.RESET}] 🩺 运行系统诊断检查 {style.DIM}(doctor){style.RESET}")
        print(f"  [{style.CYAN}6{style.RESET}] ⚡ 本地快速 Benchmark {style.DIM}(benchmark-local quick){style.RESET}")
        print(f"  [{style.CYAN}7{style.RESET}] 🔄 检查与拉取更新   {style.DIM}(update){style.RESET}")
        print(f"  [{style.CYAN}0{style.RESET}] 🚪 退出\n")

        try:
            choice = input(f"{style.CYAN}请输入选项 [0-7]: {style.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            print("\n👋 已退出 codex-flow 控制台。")
            return 0

        if choice in ("0", "q", "exit"):
            print("👋 已退出 codex-flow 控制台。")
            return 0
        elif choice == "1":
            handle_show_last()
        elif choice == "2":
            handle_show_history()
        elif choice == "3":
            handle_show_stats()
        elif choice == "4":
            handle_show_status()
        elif choice == "5":
            handle_run_doctor()
        elif choice == "6":
            handle_run_benchmark()
        elif choice == "7":
            handle_update()
        else:
            print(f"{style.RED}❌ 无效选项，请输入 0-7{style.RESET}")
            pause_prompt()

    return 0


if __name__ == "__main__":
    raise SystemExit(main_menu())
