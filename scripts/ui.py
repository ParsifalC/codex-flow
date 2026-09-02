#!/usr/bin/env python3
"""Localized user-facing CLI surfaces for codex-flow."""
from __future__ import annotations

import argparse
import os
import re
from pathlib import Path

from localization import (
    configured_language,
    detect_system_language,
    resolve_language,
    set_configured_language,
    tr,
)

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
STATE_DIR = CODEX_HOME / "codex-flow"
POLICY = CODEX_HOME / "codex-flow.toml"


def T(en: str, zh: str, lang: str) -> str:
    return tr(en, zh, lang=lang)


def display_width(text: str) -> int:
    import unicodedata
    return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)


def policy_value(section: str, key: str, default: str = "") -> str:
    try:
        text = POLICY.read_text(encoding="utf-8")
    except OSError:
        return default
    m = re.search(rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)", text)
    if not m:
        return default
    k = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", m.group(1))
    if not k:
        return default
    value = re.sub(r"\s+#.*$", "", k.group(1)).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value or default


def source_dir() -> Path | None:
    try:
        path = Path((STATE_DIR / "source").read_text(encoding="utf-8").strip())
        return path if path.exists() else None
    except OSError:
        return None


def compact_path(path: Path) -> str:
    try:
        home = str(Path.home())
        text = str(path)
        return "~" + text[len(home):] if text.startswith(home) else text
    except Exception:
        return str(path)


def box_line(content: str, width: int = 68) -> str:
    return f"  │  {content}{' ' * max(0, width - display_width(content))} │"


def status(lang: str) -> int:
    src = source_dir()
    installed = "unknown"
    available = "unknown"
    try:
        installed = (STATE_DIR / "version").read_text(encoding="utf-8").strip() or installed
    except OSError:
        pass
    if src:
        try:
            available = (src / "VERSION").read_text(encoding="utf-8").strip() or available
        except OSError:
            pass

    print(f"\n📦 {T('codex-flow status', 'codex-flow 状态', lang)}\n")
    print("  ╭─ " + T("Version & Paths", "版本与路径", lang) + " " + "─" * (51 if lang == "en" else 55) + "╮")
    print(box_line(f"• {T('Installed', '已安装', lang)}:   v{installed}"))
    if src:
        print(box_line(f"• {T('Checkout', '源码目录', lang)}:    {compact_path(src)} (v{available})"))
    else:
        print(box_line(f"• {T('Checkout', '源码目录', lang)}:    {T('unavailable', '不可用', lang)}"))
    print(box_line(f"• {T('Skill', 'Skill', lang)}:       FlowPilot (flow-pilot)"))
    if POLICY.exists():
        print("  ├─ " + T("Model Routing", "模型路由", lang) + " " + "─" * (52 if lang == "en" else 56) + "┤")
        p_policy = policy_value("parent", "model_policy", "unknown")
        p_effort = policy_value("parent", "min_reasoning_effort", "unknown")
        w_model = policy_value("worker", "resolved_model", "unknown")
        w_effort = policy_value("worker", "min_reasoning_effort", "unknown")
        t_enabled = policy_value("telemetry", "enabled", "true")
        t_notify = policy_value("telemetry", "notifications", "true")
        retention = policy_value("telemetry", "retention_days", "30")
        configured = configured_language(POLICY)
        effective = resolve_language(POLICY)
        print(box_line(f"• {T('Parent', '父 Agent', lang)}:      {p_policy} ({T('min effort', '最低推理', lang)}: {p_effort})"))
        print(box_line(f"• {T('Worker', '子 Agent', lang)}:      {w_model} ({T('min effort', '最低推理', lang)}: {w_effort})"))
        print(box_line(f"• {T('Telemetry', '遥测', lang)}:   {'● ' + T('enabled','已启用',lang) if t_enabled == 'true' else '○ ' + T('disabled','已禁用',lang)}"))
        print(box_line(f"• {T('Notify', '通知', lang)}:      {'● ' + T('system notification','系统通知',lang) if t_notify == 'true' else '○ ' + T('disabled','已禁用',lang)}"))
        print(box_line(f"• {T('Retention', '保留周期', lang)}:   {retention} {T('days per-run data', '天（单次任务数据）', lang)}"))
        print(box_line(f"• {T('Language', '语言', lang)}:    {configured} ({T('effective', '当前生效', lang)}: {effective})"))
    print("  ╰" + "─" * 69 + "╯\n")
    return 0


def language(args: list[str], lang: str) -> int:
    if not args:
        configured = configured_language(POLICY)
        system = detect_system_language()
        effective = resolve_language(POLICY)
        print(T(
            f"Language: configured={configured}, system={system}, effective={effective}",
            f"语言：配置={configured}，系统={system}，当前生效={effective}",
            lang,
        ))
        print(T(
            "Set with: codex-flow language auto|zh|en",
            "设置方式：codex-flow language auto|zh|en",
            lang,
        ))
        return 0
    if len(args) != 1:
        print(T("Usage: codex-flow language auto|zh|en", "用法：codex-flow language auto|zh|en", lang))
        return 2
    try:
        configured = set_configured_language(args[0], POLICY)
    except ValueError:
        print(T("Language must be auto, zh, or en.", "语言必须是 auto、zh 或 en。", lang))
        return 2
    effective = resolve_language(POLICY)
    out_lang = effective
    print(T(
        f"Language set to {configured} (effective: {effective}).",
        f"语言已设置为 {configured}（当前生效：{effective}）。",
        out_lang,
    ))
    return 0


def help_text(lang: str) -> int:
    if lang == "zh":
        print("""
用法: codex-flow <命令> [选项]

  交互控制台
    codex-flow                  启动交互式管理控制台（TTY 下无参数）

  核心命令
    status                      查看版本与当前生效的 FlowPilot 策略
    language [auto|zh|en]       查看或设置界面语言（默认 auto 跟随系统）
    update                      拉取源码、保留策略并刷新安装
    doctor                      检查安装、路由和遥测链路
    overlay [start|stop|toggle] macOS 原生悬浮窗
    usage last [--json]         查看最近一次任务遥测摘要
    usage list [选项]           浏览任务历史（-n N、--project P、--today、--json）
    usage show <#|id> [选项]    查看指定任务遥测摘要
    usage stats [选项]          查看聚合遥测统计（--project P、--days N）

  Benchmark 命令
    benchmark-local             使用本地 Codex 会话运行内置 Benchmark
    benchmark-corpus            仅物化测试语料，不调用模型
    benchmark                   运行可复现的 Codex Benchmark manifest
    benchmark-analyze           分析 Benchmark JSONL

  维护
    uninstall                   移除 codex-flow 管理的文件与 hooks

  提示:
    运行 `codex-flow` 进入交互控制台；语言默认跟随系统，也可用
    `codex-flow language zh` 或 `codex-flow language en` 固定语言。
""")
    else:
        print("""
Usage: codex-flow <command> [options]

  Interactive Console
    codex-flow                  Launch the interactive management console (no args in TTY)

  Core Commands
    status                      Show installed version and effective FlowPilot policy
    language [auto|zh|en]       Show or set UI language (auto follows the system)
    update                      Pull checkout, preserve policy, refresh installation
    doctor                      Verify installation, routing, and telemetry wiring
    overlay [start|stop|toggle] Native macOS floating widget
    usage last [--json]         Show the last task telemetry summary
    usage list [options]        List task history (-n N, --project P, --today, --json)
    usage show <#|id> [opt]     Show specific task telemetry summary
    usage stats [options]       Show aggregated telemetry stats (--project P, --days N)

  Benchmark Commands
    benchmark-local             Run built-in benchmark via local Codex session
    benchmark-corpus            Materialize corpus without calling any model
    benchmark                   Run a reproducible Codex benchmark manifest
    benchmark-analyze           Analyze benchmark JSONL

  Maintenance
    uninstall                   Remove codex-flow-managed files and hooks

  Tip:
    Run `codex-flow` to enter the interactive console. Language follows the system by
    default; pin it with `codex-flow language zh` or `codex-flow language en`.
""")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("command", nargs="?", default="help")
    parser.add_argument("rest", nargs="*")
    ns = parser.parse_args()
    lang = resolve_language(POLICY)
    if ns.command == "status":
        return status(lang)
    if ns.command == "language":
        return language(ns.rest, lang)
    return help_text(lang)


if __name__ == "__main__":
    raise SystemExit(main())
