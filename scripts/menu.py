#!/usr/bin/env python3
"""Interactive management console for codex-flow."""

from __future__ import annotations

import os
import subprocess
import sys
import unicodedata
from pathlib import Path
from typing import Any

try:
    from . import telemetry
except ImportError:
    import telemetry  # type: ignore

try:
    from localization import resolve_language, tr
except ImportError:
    from scripts.localization import resolve_language, tr  # type: ignore

ROOT_DIR = Path(__file__).resolve().parents[1]
CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
STATE_DIR = CODEX_HOME / "codex-flow"
LANG = resolve_language(CODEX_HOME / "codex-flow.toml")


def T(en: str, zh: str) -> str:
    return tr(en, zh, lang=LANG)


class ConsoleStyle:
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
            self.BOLD = self.DIM = self.CYAN = self.GREEN = ""
            self.YELLOW = self.RED = self.MAGENTA = self.RESET = ""


style = ConsoleStyle()


def display_width(s: str) -> int:
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in s)


def truncate_display(s: str, max_width: int) -> str:
    cur = 0
    res: list[str] = []
    for ch in s:
        width = 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1
        if cur + width > max_width:
            break
        res.append(ch)
        cur += width
    return "".join(res)


def pad_display(s: str, target_width: int, align: str = "left") -> str:
    pad = max(0, target_width - display_width(s))
    return (" " * pad + s) if align == "right" else (s + " " * pad)


def print_banner(version: str = "1.0.0") -> None:
    print(f"\n{style.DIM}╭────────────────────────────────────────────────────────────────────╮{style.RESET}")
    title = T(f"🚀 codex-flow Console (v{version})", f"🚀 codex-flow 控制台 (v{version})")
    pad_len = max(0, 66 - display_width(title))
    left_pad = pad_len // 2
    right_pad = pad_len - left_pad
    print(f"{style.DIM}│{style.RESET}{' ' * left_pad}{style.BOLD}{style.CYAN}{title}{style.RESET}{' ' * right_pad}{style.DIM}│{style.RESET}")
    sub = T(
        "FlowPilot orchestration · deterministic telemetry · local benchmark validation",
        "FlowPilot 智能编排 · 确定性任务遥测 · 本地 Benchmark 验证",
    )
    sub_pad = max(0, 66 - display_width(sub))
    sub_l = sub_pad // 2
    sub_r = sub_pad - sub_l
    print(f"{style.DIM}│{style.RESET}{' ' * sub_l}{style.DIM}{sub}{style.RESET}{' ' * sub_r}{style.DIM}│{style.RESET}")
    print(f"{style.DIM}╰────────────────────────────────────────────────────────────────────╯{style.RESET}\n")


def get_version() -> str:
    for ver_file in (ROOT_DIR / "VERSION", STATE_DIR / "version"):
        if ver_file.exists():
            try:
                return ver_file.read_text(encoding="utf-8").strip()
            except OSError:
                pass
    return "1.0.0"


def pause_prompt(prompt: str | None = None) -> None:
    prompt = prompt or T("Press Enter to return...", "按 Enter 键返回...")
    try:
        input(f"\n{style.DIM}{prompt}{style.RESET}")
    except (KeyboardInterrupt, EOFError):
        pass


def handle_show_last() -> None:
    print(f"\n{style.BOLD}{T('📊 Latest task telemetry summary:', '📊 最新任务遥测摘要:')}{style.RESET}")
    ret = telemetry.show_last(as_json=False)
    if ret == 0:
        pause_prompt()


def select_project_interactive(
    title: str | None = None,
    allow_all: bool = True,
    all_label: str | None = None,
    limit: int = 10,
) -> str | None | False:
    title = title or T("Select a project to analyze", "请选择要统计的项目")
    all_label = all_label or T("All projects (full statistics)", "全部项目 (全量统计)")
    try:
        all_stats = telemetry.aggregate_project_stats(days=30)
    except Exception:
        all_stats = {}

    projects = all_stats.get("projects") or {}
    total_count = len(projects)
    sorted_projs = sorted(
        projects.items(),
        key=lambda item: (item[1].get("tokens", 0), item[1].get("runs", 0)),
        reverse=True,
    )
    if limit and len(sorted_projs) > limit:
        sorted_projs = sorted_projs[:limit]

    if not sorted_projs:
        print(f"\n{style.DIM}{T('📁 No project history yet', '📁 暂无历史项目记录')}{style.RESET}")
        try:
            prompt = T("Enter project name (Enter for all): ", "请输入项目名称 (直接回车统计全量): ")
            p_in = input(f"{style.CYAN}{prompt}{style.RESET}").strip()
            return p_in if p_in else None
        except (KeyboardInterrupt, EOFError):
            return False

    title_suffix = T(f" (top {len(sorted_projs)})", f" (前 {len(sorted_projs)} 个)") if total_count > len(sorted_projs) else ""
    print(f"\n{style.BOLD}📁 {title}{title_suffix}:{style.RESET}")
    if allow_all:
        default = T("(Enter by default)", "(直接回车默认)")
        print(f"  [{style.CYAN}0{style.RESET}] 🌐 {all_label} {style.DIM}{default}{style.RESET}")
    for idx, (p_name, p_info) in enumerate(sorted_projs, 1):
        runs_cnt = p_info.get("runs", 0)
        tok_cnt = telemetry.fmt_tokens(p_info.get("tokens", 0)) or "0"
        unit = T("tasks", "个任务")
        print(f"  [{style.CYAN}{idx}{style.RESET}] {p_name} {style.DIM}({runs_cnt} {unit} · {tok_cnt} tokens){style.RESET}")
    if total_count > len(sorted_projs):
        text = T(f"✍️  Enter another project name ({total_count} total)", f"✍️  手动输入其他项目名称 (共 {total_count} 个项目)")
    else:
        text = T("✍️  Enter project name manually", "✍️  手动输入项目名称")
    print(f"  [{style.CYAN}m{style.RESET}] {text}")
    print(f"  [{style.CYAN}q{style.RESET}] 🔙 {T('Back', '返回')}")

    try:
        prompt_hint = f"0-{len(sorted_projs)}/m/q" if allow_all else f"1-{len(sorted_projs)}/m/q"
        choice = input(f"\n{style.CYAN}{T('Select', '请选择')} [{prompt_hint}]: {style.RESET}").strip()
    except (KeyboardInterrupt, EOFError):
        return False

    if choice == "":
        return None if allow_all else False
    if choice.lower() in ("0", "all") and allow_all:
        return None
    if choice.lower() in ("q", "back", "exit"):
        return False
    if choice.lower() in ("m", "manual"):
        try:
            prompt = T("Enter project name (Enter for all): ", "请输入项目名称 (直接回车为全量): ")
            p_in = input(f"{style.CYAN}{prompt}{style.RESET}").strip()
            return p_in if p_in else None
        except (KeyboardInterrupt, EOFError):
            return False
    if choice.isdigit():
        idx = int(choice)
        if idx == 0 and allow_all:
            return None
        if 1 <= idx <= len(sorted_projs):
            return sorted_projs[idx - 1][0]
        print(f"{style.RED}❌ {T(f'Index out of range [1-{len(sorted_projs)}]', f'序号超出范围 [1-{len(sorted_projs)}]')}{style.RESET}")
        pause_prompt()
        return False
    return choice


def handle_show_history() -> None:
    limit = 10
    project: str | None = None
    today = False
    while True:
        runs = telemetry.list_runs(limit=limit, project=project, today=today)
        print(telemetry.render_run_list(runs, project=project, today=today))
        print(f"{style.BOLD}{T('Quick actions:', '快捷操作:')}{style.RESET}")
        if runs:
            print(f"  [{style.CYAN}1-{len(runs)}{style.RESET}] {T('View task card details', '查看对应序号的任务卡片详情')}")
        current_project = project or T("All", "全部")
        print(f"  [{style.CYAN}p{style.RESET}] {T('Filter by project', '按项目名称过滤')} ({T('current', '当前')}: {current_project})")
        print(f"  [{style.CYAN}t{style.RESET}] {T('Toggle today only', '切换仅看今天')} ({T('current', '当前')}: {T('yes', '是') if today else T('no', '否')})")
        print(f"  [{style.CYAN}s{style.RESET}] {T('Project aggregate stats', '查看项目聚合统计')} (Stats)")
        print(f"  [{style.CYAN}r{style.RESET}] {T('Refresh', '刷新列表')}")
        print(f"  [{style.CYAN}0{style.RESET}] {T('Back to main menu', '返回主菜单')}")
        try:
            choice = input(f"\n{style.CYAN}{T('Enter option', '请输入选项')}: {style.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            break
        if choice in ("0", "q", "exit", "back"):
            break
        if choice == "r":
            continue
        if choice == "t":
            today = not today
            continue
        if choice == "p":
            selected = select_project_interactive(
                title=T("Select a project to filter", "请选择要过滤的项目"),
                allow_all=True,
                all_label=T("All projects (clear filter)", "全部项目 (清除过滤)"),
            )
            if selected is not False:
                project = selected
            continue
        if choice == "s":
            handle_show_stats(project)
            continue
        if choice.isdigit():
            idx = int(choice)
            if 1 <= idx <= len(runs):
                selected = runs[idx - 1]
                telemetry.enrich_run_metadata(selected)
                print(telemetry.render_summary(selected))
                pause_prompt(T("Press Enter to return to history...", "按 Enter 键返回历史列表..."))
            else:
                print(f"{style.RED}❌ {T(f'Index out of range [1-{len(runs)}]', f'序号超出范围 [1-{len(runs)}]')}{style.RESET}")
                pause_prompt()
        else:
            print(f"{style.RED}❌ {T('Invalid option', '无效选项')}: {choice}{style.RESET}")


def handle_show_stats(default_project: str | None = None) -> None:
    target_project = default_project
    if target_project is None:
        selected = select_project_interactive()
        if selected is False:
            return
        target_project = selected
    stats = telemetry.aggregate_project_stats(project=target_project, days=30)
    print(telemetry.render_project_stats(stats))
    pause_prompt()


def handle_show_status() -> None:
    print(f"\n{style.BOLD}{T('🎯 Effective FlowPilot policy:', '🎯 当前 FlowPilot 策略状态:')}{style.RESET}\n")
    if os.name != "nt":
        bin_script = ROOT_DIR / "bin" / "codex-flow"
        subprocess.run(["bash", str(bin_script), "status"] if bin_script.exists() else ["codex-flow", "status"])
    else:
        subprocess.run(["codex-flow.cmd", "status"], shell=True)
    pause_prompt()


def handle_run_doctor() -> None:
    print(f"\n{style.BOLD}{T('🩺 Running diagnostics...', '🩺 正在运行系统诊断检查...')}{style.RESET}\n")
    if os.name != "nt":
        doc_script = ROOT_DIR / "scripts" / "doctor"
        subprocess.run(["bash", str(doc_script)] if doc_script.exists() else ["codex-flow", "doctor"])
    else:
        subprocess.run(["codex-flow.cmd", "doctor"], shell=True)
    pause_prompt()


def handle_run_benchmark() -> None:
    print(f"\n{style.BOLD}{T('⚡ Local quick benchmark:', '⚡ 本地快速 Benchmark 评测:')}{style.RESET}")
    print(style.DIM + T(
        "Runs 6 representative tasks with the locally authenticated Codex to evaluate routing and model behavior.",
        "将调用本地登录的 Codex 执行 6 个典型任务以测量当前模型与编排效果。",
    ) + style.RESET)
    try:
        confirm = input(f"{style.YELLOW}{T('Start now? [y/N]: ', '确定开始执行吗？[y/N]: ')}{style.RESET}").strip().lower()
    except (KeyboardInterrupt, EOFError):
        return
    if confirm in ("y", "yes", "是"):
        bench_script = ROOT_DIR / "scripts" / "benchmark-local.py"
        subprocess.run([sys.executable, str(bench_script), "quick"] if bench_script.exists() else ["codex-flow", "benchmark-local", "quick"])
        pause_prompt()


def handle_update() -> None:
    print(f"\n{style.BOLD}{T('🔄 Checking for codex-flow updates...', '🔄 正在检查并更新 codex-flow...')}{style.RESET}\n")
    if os.name != "nt":
        bin_script = ROOT_DIR / "bin" / "codex-flow"
        subprocess.run(["bash", str(bin_script), "update"] if bin_script.exists() else ["codex-flow", "update"])
    else:
        subprocess.run(["codex-flow.cmd", "update"], shell=True)
    pause_prompt()


def get_source_dir() -> Path:
    source_file = STATE_DIR / "source"
    if source_file.exists():
        try:
            p = Path(source_file.read_text(encoding="utf-8").strip())
            if p.exists():
                return p
        except OSError:
            pass
    return ROOT_DIR


def get_overlay_bin() -> Path | None:
    src = get_source_dir()
    candidates = [
        STATE_DIR / "bin" / "FlowPilot",
        STATE_DIR / "bin" / "codex-flow-overlay",
        src / "apps" / "macos-overlay" / "bin" / "FlowPilot",
        src / "apps" / "macos-overlay" / "bin" / "codex-flow-overlay",
    ]
    return next((c for c in candidates if c.exists() and os.access(str(c), os.X_OK)), None)


def handle_manage_overlay() -> None:
    if sys.platform != "darwin":
        print(f"\n{style.YELLOW}⚠️ {T('The native FlowPilot floating window is available only on macOS.', 'FlowPilot 原生悬浮窗仅支持 macOS 系统。')}{style.RESET}")
        pause_prompt()
        return
    overlay_bin = get_overlay_bin()
    if overlay_bin is None or not overlay_bin.exists():
        src = get_source_dir()
        print(f"\n{style.YELLOW}💡 {T('The native FlowPilot floating window has not been built yet.', 'FlowPilot 原生悬浮窗尚未编译。')}{style.RESET}")
        print(f"{style.DIM}{T('To enable it, run', '如需启用，请在终端执行')}: bash {src}/apps/macos-overlay/build.sh{style.RESET}\n")
        pause_prompt()
        return

    while True:
        try:
            status_res = subprocess.run([str(overlay_bin), "status"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            is_running = status_res.returncode == 0
        except Exception:
            is_running = False
        print(f"\n{style.BOLD}🪟 {T('macOS Native Floating Widget:', 'macOS 原生悬浮窗管理 (Native Floating Widget):')}{style.RESET}")
        if is_running:
            print(f"  {T('Status', '当前状态')}: {style.GREEN}● {T('running (hover 0.4s to expand Summary)', '正在运行 (Hover 0.4s 展开 Summary)')}{style.RESET}")
        else:
            print(f"  {T('Status', '当前状态')}: {style.DIM}○ {T('stopped', '未运行')}{style.RESET}")
        print(f"\n  [{style.CYAN}1{style.RESET}] {T('⏹ Stop widget', '⏹ 停止浮窗') if is_running else T('🚀 Start widget', '🚀 启动浮窗')}")
        if is_running:
            print(f"  [{style.CYAN}2{style.RESET}] {T('🔄 Toggle expanded / collapsed', '🔄 切换展开 / 折叠 (Toggle)')}")
            print(f"  [{style.CYAN}3{style.RESET}] {T('⚡ Push latest data and expand', '⚡️ 发送最新数据并展开 (Push Last Summary)')}")
        print(f"  [{style.CYAN}4{style.RESET}] {T('🔨 Rebuild', '🔨 重新编译构建 (Rebuild)')}")
        print(f"  [{style.CYAN}0{style.RESET}] 🔙 {T('Back to main menu', '返回主菜单')}\n")
        try:
            choice = input(f"{style.CYAN}{T('Select action', '请选择操作')}: {style.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            break
        if choice in ("0", "q", "exit", "back"):
            break
        if choice == "1":
            if is_running:
                try:
                    subprocess.run([str(overlay_bin), "stop"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception:
                    pass
                print(f"{style.YELLOW}{T('Widget stopped.', '浮窗已停止。')}{style.RESET}")
            else:
                try:
                    subprocess.Popen([str(overlay_bin), "start"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    print(f"{style.GREEN}{T('Widget started. It appears near the top-right and expands after a 0.4s hover.', '浮窗已启动！默认在屏幕右上角圆形悬浮，光标停留 0.4 秒展开。')}{style.RESET}")
                except Exception as exc:
                    print(f"{style.RED}{T('Start failed', '启动失败')}: {exc}{style.RESET}")
            pause_prompt()
        elif choice == "2" and is_running:
            try:
                subprocess.run([str(overlay_bin), "toggle"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
        elif choice == "3" and is_running:
            try:
                subprocess.run([str(overlay_bin), "update"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                print(f"{style.GREEN}{T('Latest Summary pushed and expanded.', '已向浮窗推送最新 Summary 并展开。')}{style.RESET}")
            except Exception as exc:
                print(f"{style.RED}{T('Push failed', '推送失败')}: {exc}{style.RESET}")
            pause_prompt()
        elif choice == "4":
            build_script = get_source_dir() / "apps" / "macos-overlay" / "build.sh"
            if build_script.exists():
                subprocess.run(["bash", str(build_script)])
                overlay_bin = get_overlay_bin()
            pause_prompt()


def main_menu() -> int:
    version = get_version()
    while True:
        print_banner(version)
        items = [
            ("1", T("📊 Latest task card", "📊 查看最新任务卡片"), "usage last"),
            ("2", T("📜 Task history", "📜 浏览历史任务列表"), "usage list"),
            ("3", T("📈 Project aggregate statistics", "📈 项目聚合统计分析"), "usage stats"),
            ("4", T("🎯 Effective policy", "🎯 查看生效策略配置"), "status"),
            ("5", T("🩺 Diagnostics", "🩺 运行系统诊断检查"), "doctor"),
            ("6", T("⚡ Local quick Benchmark", "⚡ 本地快速 Benchmark"), "benchmark-local quick"),
            ("7", T("🔄 Check and pull updates", "🔄 检查与拉取更新"), "update"),
            ("8", T("🪟 macOS native floating widget", "🪟 macOS 原生悬浮窗"), "overlay widget"),
        ]
        for key, label, command in items:
            print(f"  [{style.CYAN}{key}{style.RESET}] {label} {style.DIM}({command}){style.RESET}")
        print(f"  [{style.CYAN}0{style.RESET}] 🚪 {T('Exit', '退出')}\n")
        try:
            choice = input(f"{style.CYAN}{T('Enter option [0-8]', '请输入选项 [0-8]')}: {style.RESET}").strip()
        except (KeyboardInterrupt, EOFError):
            print("\n" + T("👋 Exited codex-flow console.", "👋 已退出 codex-flow 控制台。"))
            return 0
        if choice in ("0", "q", "exit"):
            print(T("👋 Exited codex-flow console.", "👋 已退出 codex-flow 控制台。"))
            return 0
        handlers = {
            "1": handle_show_last,
            "2": handle_show_history,
            "3": handle_show_stats,
            "4": handle_show_status,
            "5": handle_run_doctor,
            "6": handle_run_benchmark,
            "7": handle_update,
            "8": handle_manage_overlay,
        }
        handler = handlers.get(choice)
        if handler:
            handler()
        else:
            print(f"{style.RED}❌ {T('Invalid option; enter 0-8', '无效选项，请输入 0-8')}{style.RESET}")
            pause_prompt()
    return 0


if __name__ == "__main__":
    raise SystemExit(main_menu())
