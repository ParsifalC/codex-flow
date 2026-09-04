#!/usr/bin/env python3
"""Cross-platform localized diagnostics for codex-flow."""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

from localization import configured_language, resolve_language, tr

CODEX_HOME = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex"))
CONFIG = CODEX_HOME / "config.toml"
POLICY = CODEX_HOME / "codex-flow.toml"
HOOKS = CODEX_HOME / "hooks.json"
STATE_DIR = CODEX_HOME / "codex-flow"
LANG = resolve_language(POLICY)
FAILED = False
CODEX_AVAILABLE = True
HOOKS_ACTION_REQUIRED = False


def T(en: str, zh: str) -> str:
    return tr(en, zh, lang=LANG)


def policy_value(section: str, key: str, default: str = "") -> str:
    try:
        text = POLICY.read_text(encoding="utf-8-sig")
    except OSError:
        return default
    match = re.search(rf"(?ms)^\[{re.escape(section)}\]\s*\n(.*?)(?=^\[[^\n]+\]\s*$|\Z)", text)
    if not match:
        return default
    key_match = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", match.group(1))
    if not key_match:
        return default
    value = re.sub(r"\s+#.*$", "", key_match.group(1)).strip()
    if len(value) >= 2 and value[0] == value[-1] == '"':
        value = value[1:-1]
    return value or default


def root_value(key: str, default: str = "") -> str:
    try:
        text = POLICY.read_text(encoding="utf-8-sig")
    except OSError:
        return default
    root = text.split("[", 1)[0]
    m = re.search(rf"(?m)^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", root)
    return re.sub(r"\s+#.*$", "", m.group(1)).strip().strip('"') if m else default


def ok(msg: str) -> None:
    print(f"  ✔ {msg}")


def warn(msg: str) -> None:
    print(f"  ▲ {msg}")


def fail(msg: str) -> None:
    global FAILED
    FAILED = True
    print(f"  ✖ {msg}")


def section(en: str, zh: str) -> None:
    print(f"\n  {T(en, zh)}")


def codex_thread_usage_capable(version: str) -> bool | None:
    match = re.search(r"(\d+)\.(\d+)", version)
    if not match:
        return None
    major, minor = int(match.group(1)), int(match.group(2))
    return major > 0 or (major == 0 and minor >= 151)


def run_capture(args: list[str]) -> tuple[int, str]:
    try:
        command = args
        if os.name == "nt" and args and Path(args[0]).suffix.lower() in {".cmd", ".bat"}:
            command = [os.environ.get("COMSPEC", "cmd.exe"), "/d", "/c", *args]
        proc = subprocess.run(command, capture_output=True, text=True, timeout=8, check=False)
        text = (proc.stdout or proc.stderr or "").strip()
        return proc.returncode, text
    except (OSError, subprocess.SubprocessError):
        return 127, ""


def _check_effort(label_en: str, label_zh: str, value: str) -> None:
    if value in {"high", "xhigh", "max"}:
        ok(T(f"{label_en}: {value}", f"{label_zh}：{value}"))
    else:
        fail(T(f"invalid {label_en}: {value or 'missing'}", f"无效{label_zh}：{value or 'missing'}"))


def _hook_action_hint() -> str:
    if CODEX_AVAILABLE:
        return T(
            "Open the Codex CLI using the same CODEX_HOME, run /hooks, then review and trust/enable the FlowPilot hooks.",
            "请使用同一 CODEX_HOME 打开 Codex CLI，运行 /hooks，然后 review 并信任/启用 FlowPilot hooks。",
        )
    return T(
        "Hook review is required, but Codex CLI is not in PATH. Install/open Codex CLI once with the same CODEX_HOME, run /hooks, approve FlowPilot, then you may continue using ChatGPT Desktop without keeping the CLI running.",
        "Hooks 需要 review，但当前 PATH 中没有 Codex CLI。请使用同一 CODEX_HOME 安装/打开一次 Codex CLI，运行 /hooks 批准 FlowPilot；完成授权后无需让 CLI 常驻，可继续使用 ChatGPT Desktop。",
    )


def main() -> int:
    global CODEX_AVAILABLE, HOOKS_ACTION_REQUIRED
    print(f"\n🩺 {T('codex-flow doctor', 'codex-flow 系统诊断')}")

    section("Environment & Tools", "环境与工具")
    codex = shutil.which("codex")
    if codex:
        _, version = run_capture([codex, "--version"])
        ok(T(f"Codex CLI found{': ' + version if version else ''}", f"已找到 Codex CLI{('：' + version) if version else ''}"))
        capable = codex_thread_usage_capable(version)
        if capable is False:
            warn(T(
                f"Codex CLI {version} is below the known 0.151 support baseline; thread-attributed telemetry may be unavailable; upgrade to 0.151+ recommended",
                f"Codex CLI {version} 低于已知的 0.151 支持基线；按线程归属的遥测可能不可用，建议升级到 0.151+",
            ))
    else:
        CODEX_AVAILABLE = False
        warn(T(
            "Codex CLI not found in PATH; core routing remains usable, telemetry quota reads and real local benchmark execution are unavailable",
            "PATH 中未找到 Codex CLI；核心路由仍可使用，但遥测额度读取和真实本地 Benchmark 不可用",
        ))
        print("    " + T("(Install via: npm install -g @openai/codex  or  brew install codex)", "（可通过 npm install -g @openai/codex 或 brew install codex 安装）"))

    ok(T("config.toml found", "已找到 config.toml")) if CONFIG.is_file() else fail(T(f"missing {CONFIG}", f"缺少 {CONFIG}"))
    ok(T("codex-flow policy found", "已找到 codex-flow 策略文件")) if POLICY.is_file() else fail(T(f"missing {POLICY}", f"缺少 {POLICY}"))

    section("Strategy Runtime & Skills", "策略运行时与 Skills")
    checks = [
        (CODEX_HOME / "agents/worker-explorer.toml", "worker-explorer"),
        (CODEX_HOME / "agents/worker-implementer.toml", "worker-implementer"),
        (CODEX_HOME / "agents/worker-reviewer.toml", "worker-reviewer"),
        (CODEX_HOME / "skills/flow-pilot/SKILL.md", "FlowPilot skill"),
        (STATE_DIR / "strategy_runtime.py", "strategy runtime helper"),
        (STATE_DIR / "strategies/__init__.py", "built-in strategy registry"),
        (STATE_DIR / "strategies/task_budget_runtime.py", "task budget runtime helper"),
        (STATE_DIR / "defaults.toml", "release policy defaults"),
        (STATE_DIR / "updater.py", "OTA updater"),
        (STATE_DIR / "update_runtime_config.py", "runtime config reconciler"),
    ]
    for path, label in checks:
        ok(T(f"{label} installed", f"{label} 已安装")) if path.is_file() else fail(T(f"{label} missing", f"缺少 {label}"))

    if POLICY.is_file():
        schema = root_value("schema_version")
        if schema == "4":
            ok(T("policy schema v4", "策略 schema v4"))
        elif schema == "3":
            warn(T("policy schema v3 is backward compatible; reinstall/update recommended to enable persistent multi-strategy configuration", "策略 schema v3 可向后兼容；建议重新安装/更新以启用持久化多策略配置"))
        else:
            warn(T(f"policy schema is {schema or 'unknown'}; reinstall recommended", f"策略 schema 为 {schema or 'unknown'}；建议重新安装"))

        strategy_enabled = policy_value("strategy", "enabled", "true")
        strategy = policy_value("strategy", "profile", "efficient")
        routing = policy_value("routing", "mode", "adaptive")
        review = policy_value("modifiers", "review", "auto")
        fanout = policy_value("modifiers", "fanout", "auto")
        if strategy_enabled == "true":
            ok(T("strategy dispatch: enabled", "策略分发：已启用"))
        elif strategy_enabled == "false":
            ok(T("strategy dispatch: disabled by policy", "策略分发：已由策略禁用"))
        else:
            fail(T(f"invalid strategy dispatch switch: {strategy_enabled or 'missing'}", f"无效策略分发开关：{strategy_enabled or 'missing'}"))
        if strategy in {"efficient", "balanced", "quality", "speed"}:
            ok(T(f"strategy profile: {strategy}", f"执行策略：{strategy}"))
        else:
            fail(T(f"invalid strategy profile: {strategy}", f"无效执行策略：{strategy}"))
        if routing in {"adaptive", "direct", "delegate"}:
            ok(T(f"routing mode: {routing}", f"路由模式：{routing}"))
        else:
            fail(T(f"invalid routing mode: {routing}", f"无效路由模式：{routing}"))
        if review in {"auto", "standard", "strict"}:
            ok(T(f"review modifier: {review}", f"Review 修饰策略：{review}"))
        else:
            fail(T(f"invalid review modifier: {review or 'missing'}", f"无效 Review 修饰策略：{review or 'missing'}"))
        if fanout in {"auto", "conservative", "aggressive"}:
            ok(T(f"fanout modifier: {fanout}", f"Fan-out 修饰策略：{fanout}"))
        else:
            fail(T(f"invalid fanout modifier: {fanout or 'missing'}", f"无效 Fan-out 修饰策略：{fanout or 'missing'}"))

        parent_effort = policy_value("parent", "min_reasoning_effort")
        worker_effort = policy_value("worker", "min_reasoning_effort")
        _check_effort("parent minimum reasoning", "父 Agent 最低推理强度", parent_effort)
        _check_effort("worker minimum reasoning", "子 Agent 最低推理强度", worker_effort)
        for role, role_zh in (("parent", "父 Agent"), ("worker", "子 Agent")):
            for key, label in (
                ("routine_effort", "routine reasoning"),
                ("complex_effort", "complex reasoning"),
                ("critical_effort", "critical reasoning"),
            ):
                _check_effort(f"{role} {label}", f"{role_zh} {label}", policy_value(role, key))

        parent_reasoning = policy_value("parent", "reasoning_policy")
        worker_reasoning = policy_value("worker", "reasoning_policy")
        if parent_reasoning == "adaptive":
            ok(T("parent reasoning policy: adaptive", "父 Agent 推理策略：adaptive"))
        else:
            warn(T(f"parent reasoning policy: {parent_reasoning or 'unknown'}", f"父 Agent 推理策略：{parent_reasoning or 'unknown'}"))
        if worker_reasoning == "adaptive":
            ok(T("worker reasoning policy: adaptive", "子 Agent 推理策略：adaptive"))
        else:
            warn(T(f"worker reasoning policy: {worker_reasoning or 'unknown'}", f"子 Agent 推理策略：{worker_reasoning or 'unknown'}"))

        max_threads = policy_value("runtime", "max_concurrent_threads")
        max_repairs = policy_value("runtime", "max_repair_cycles")
        if re.fullmatch(r"[1-9]\d*", max_threads or ""):
            ok(T(f"runtime thread ceiling: {max_threads}", f"运行时线程上限：{max_threads}"))
        else:
            fail(T(f"invalid runtime thread ceiling: {max_threads or 'missing'}", f"无效运行时线程上限：{max_threads or 'missing'}"))
        if re.fullmatch(r"\d+", max_repairs or ""):
            ok(T(f"runtime repair ceiling: {max_repairs}", f"运行时修复轮次上限：{max_repairs}"))
        else:
            fail(T(f"invalid runtime repair ceiling: {max_repairs or 'missing'}", f"无效运行时修复轮次上限：{max_repairs or 'missing'}"))

        parent_policy = policy_value("parent", "model_policy", "unknown")
        parent_min_model = policy_value("parent", "min_model", "unknown")
        worker_policy = policy_value("worker", "model_policy", "unknown")
        worker_requested = policy_value("worker", "model", "unknown")
        worker_model = policy_value("worker", "resolved_model", "unknown")
        ok(T(
            f"parent model policy: {parent_policy} (floor: {parent_min_model})",
            f"父 Agent 模型策略：{parent_policy}（下限：{parent_min_model}）",
        ))
        ok(T(
            f"worker model policy: {worker_policy} (requested: {worker_requested}, resolved: {worker_model})",
            f"子 Agent 模型策略：{worker_policy}（请求：{worker_requested}，解析：{worker_model}）",
        ))

        configured = configured_language(POLICY)
        effective = resolve_language(POLICY)
        if configured in {"auto", "zh", "en"}:
            ok(T(f"UI language: {configured} (effective: {effective})", f"界面语言：{configured}（当前生效：{effective}）"))
        else:
            fail(T(f"invalid UI language: {configured}", f"无效界面语言：{configured}"))

        notifications = policy_value("telemetry", "notifications", "true")
        retention = policy_value("telemetry", "retention_days", "30")
        if notifications == "true":
            ok(T("system notifications: enabled (macOS)", "系统通知：已启用（macOS）"))
        elif notifications == "false":
            ok(T("system notifications: disabled by policy", "系统通知：已由策略禁用"))
        else:
            fail(T(f"invalid system notifications policy: {notifications or 'missing'}", f"无效系统通知策略：{notifications or 'missing'}"))
        if re.fullmatch(r"[1-9]\d*", retention or ""):
            ok(T(f"per-run telemetry retention: {retention} days", f"单次任务遥测保留：{retention} 天"))
        else:
            fail(T(f"invalid per-run telemetry retention: {retention or 'missing'}", f"无效单次任务遥测保留配置：{retention or 'missing'}"))

        section("Hooks & Telemetry", "Hooks 与遥测")
        enabled = policy_value("telemetry", "enabled", "true")
        if enabled == "true":
            collector = STATE_DIR / "telemetry.py"
            manager = STATE_DIR / "manage-hooks.py"
            ok(T("FlowPilot telemetry collector installed", "FlowPilot 遥测采集器已安装")) if collector.is_file() else fail(T("FlowPilot telemetry collector missing", "缺少 FlowPilot 遥测采集器"))
            ok(T("FlowPilot hook manager installed", "FlowPilot hook 管理器已安装")) if manager.is_file() else fail(T("FlowPilot hook manager missing", "缺少 FlowPilot hook 管理器"))
            if manager.is_file():
                code, _ = run_capture([sys.executable, str(manager), "check", "--hooks", str(HOOKS)])
                if code == 0:
                    ok(T("FlowPilot lifecycle hooks installed", "FlowPilot 生命周期 hooks 已安装"))
                    _, trust_output = run_capture([
                        sys.executable,
                        str(manager),
                        "status",
                        "--hooks",
                        str(HOOKS),
                        "--config",
                        str(CONFIG),
                        "--json",
                    ])
                    try:
                        trust = json.loads(trust_output)
                    except (json.JSONDecodeError, TypeError):
                        trust = {"status": "unknown", "error": trust_output or "no trust report"}
                    status = str(trust.get("status") or "unknown")
                    total = int(trust.get("total") or 0)
                    trusted = int(trust.get("trusted") or 0)
                    if status == "trusted":
                        ok(T(
                            f"FlowPilot hook authorization: trusted ({trusted}/{total})",
                            f"FlowPilot hooks 授权：已信任（{trusted}/{total}）",
                        ))
                    elif status == "modified":
                        HOOKS_ACTION_REQUIRED = True
                        warn(T(
                            "FlowPilot hook authorization: definitions changed since approval; re-authorization required",
                            "FlowPilot hooks 授权：hook 定义在上次批准后已变化，需要重新授权",
                        ))
                        print("    " + _hook_action_hint())
                    elif status == "untrusted":
                        HOOKS_ACTION_REQUIRED = True
                        warn(T(
                            "FlowPilot hook authorization: approval required before hook-backed features can run",
                            "FlowPilot hooks 授权：需要批准后，依赖 hooks 的功能才能运行",
                        ))
                        print("    " + _hook_action_hint())
                    elif status == "disabled":
                        HOOKS_ACTION_REQUIRED = True
                        warn(T(
                            "FlowPilot hook authorization: one or more lifecycle hooks are disabled",
                            "FlowPilot hooks 授权：一个或多个生命周期 hook 已被禁用",
                        ))
                        print("    " + _hook_action_hint())
                    else:
                        HOOKS_ACTION_REQUIRED = True
                        detail = str(trust.get("error") or "trust state unavailable")
                        warn(T(
                            f"FlowPilot hook authorization could not be verified: {detail}",
                            f"无法验证 FlowPilot hooks 授权状态：{detail}",
                        ))
                        print("    " + _hook_action_hint())
                else:
                    fail(T(f"FlowPilot lifecycle hooks missing from {HOOKS}", f"{HOOKS} 中缺少 FlowPilot 生命周期 hooks"))
        elif enabled == "false":
            ok(T("FlowPilot telemetry disabled by policy", "FlowPilot 遥测已由策略禁用"))
        else:
            fail(T(f"invalid telemetry enabled policy: {enabled or 'missing'}", f"无效遥测启用配置：{enabled or 'missing'}"))

        if CONFIG.is_file() and worker_model and worker_model != "unknown":
            try:
                cfg = CONFIG.read_text(encoding="utf-8-sig")
            except OSError:
                cfg = ""
            if f'default_subagent_model = "{worker_model}"' in cfg:
                ok(T("Codex worker baseline model matches resolved policy", "Codex 子 Agent 基线模型与解析后的策略一致"))
            else:
                fail(T("Codex default_subagent_model does not match resolved policy", "Codex default_subagent_model 与解析后的策略不一致"))
            if f'default_subagent_reasoning_effort = "{worker_effort}"' in cfg:
                ok(T("Codex worker baseline effort matches policy floor", "Codex 子 Agent 基线推理强度与策略下限一致"))
            else:
                fail(T("Codex default_subagent_reasoning_effort does not match worker floor", "Codex default_subagent_reasoning_effort 与子 Agent 下限不一致"))

    print("\n  " + "─" * 69)
    if not FAILED:
        if HOOKS_ACTION_REQUIRED:
            print("  ⚠ " + T(
                "Installed with action required: FlowPilot hook-backed features are inactive until hook review is completed.",
                "安装正常，但仍需操作：在完成 hook review 前，FlowPilot 依赖 hooks 的功能不会生效。",
            ))
        elif CODEX_AVAILABLE:
            print("  ✨ " + T("Ready. FlowPilot strategy runtime and deterministic telemetry are installed.", "就绪。FlowPilot 策略运行时与确定性遥测均已安装。"))
        else:
            print("  ✨ " + T("Ready. Core FlowPilot strategy runtime is installed and healthy; Codex CLI-dependent telemetry quota reads and benchmark execution are unavailable in this shell.", "就绪。FlowPilot 核心策略运行时安装正常；当前 shell 中依赖 Codex CLI 的遥测额度读取和 Benchmark 执行不可用。"))
        print("  " + T("Note: per-spawn model/effort overrides depend on the active Codex build; the installed baseline remains valid when overrides are unavailable.", "注意：每次 spawn 的模型/推理强度覆盖取决于当前 Codex 版本；即使覆盖不可用，已安装的基线配置仍然有效。") + "\n")
        return 0

    print("  ✖ " + T("One or more required core checks failed. Re-run the installer, then restart Codex.", "一个或多个核心检查失败。请重新运行安装器，然后重启 Codex。") + "\n")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
