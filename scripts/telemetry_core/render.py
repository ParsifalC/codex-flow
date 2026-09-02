"""Terminal presentation and summary card formatting for task runs and project aggregations."""

from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Any

from .app_server import enrich_run_metadata, usage_group_identities
from .common import (
    compact_text,
    display_width,
    fmt_duration_ms,
    fmt_local_timestamp,
    fmt_percent,
    fmt_tokens,
    numeric_ms,
    pad_display,
    text_value,
    truncate_display,
    window_label,
)

try:
    from localization import resolve_language, tr
except ImportError:
    from scripts.localization import resolve_language, tr  # type: ignore

LANG = resolve_language(Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")) / "codex-flow.toml")


def T(en: str, zh: str) -> str:
    return tr(en, zh, lang=LANG)


def aggregate_usage_value(usages: list[dict[str, Any] | None], key: str) -> int | None:
    values: list[int] = []
    for usage in usages:
        if not isinstance(usage, dict):
            return None
        value = usage.get(key)
        if not isinstance(value, (int, float)):
            return None
        values.append(int(value))
    return sum(values) if values else None


def participant_runtime_label(participant: dict[str, Any], usage: dict[str, Any] | None) -> str:
    model = text_value(participant.get("model"))
    effort = text_value(participant.get("reasoning_effort"))
    identities = usage_group_identities(usage)
    if not model:
        models = {item_model for item_model, _ in identities if item_model}
        if len(models) == 1:
            model = next(iter(models))
    if not effort:
        efforts = {item_effort for _, item_effort in identities if item_effort}
        if len(efforts) == 1:
            effort = next(iter(efforts))
    model = compact_text(model, 32) or T("unknown", "未知")
    effort = compact_text(effort, 16) or T("effort n/a", "推理强度未知")
    return f"{model} ({effort})"


def run_context(run: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    thread = run.get("thread") if isinstance(run.get("thread"), dict) else {}
    session = compact_text(thread.get("name") or thread.get("preview") or run.get("session_id"))
    cwd = thread.get("cwd") or run.get("cwd")
    project = None
    if cwd:
        try:
            project = Path(str(cwd)).name or str(cwd)
        except (OSError, ValueError):
            project = str(cwd)
    git_info = thread.get("gitInfo")
    branch = git_info.get("branch") if isinstance(git_info, dict) else None
    return session, compact_text(project), compact_text(branch)


def render_summary(run: dict[str, Any]) -> str:
    enrich_run_metadata(run)
    workers = list((run.get("workers") or {}).values())
    parent = run.get("parent") or {}
    parent_usage = parent.get("usage_delta") if isinstance(parent, dict) else None
    participant_usages = [parent_usage]
    participant_usages.extend(worker.get("usage") if isinstance(worker, dict) else None for worker in workers)

    p_count = T(
        f"1 parent + {len(workers)} worker{'s' if len(workers) != 1 else ''}",
        f"1 个 parent + {len(workers)} 个 worker",
    )
    p_runtime = participant_runtime_label(parent, parent_usage)
    p_tokens = f"{fmt_tokens(parent_usage.get('total_tokens') if isinstance(parent_usage, dict) else None)} tokens"
    total_tokens = aggregate_usage_value(participant_usages, "total_tokens")
    credits = aggregate_usage_value(participant_usages, "estimated_credits_micros")
    attr_tokens = f"{fmt_tokens(total_tokens)} tokens"
    attr_credits = f" · {credits / 1_000_000:.3f} credits" if credits is not None else ""

    def pad_line(content: str, width: int = 68) -> str:
        pad = max(0, width - display_width(content))
        return f"  │  {content}{' ' * pad} │"

    def append_wrapped_line(content: str, continuation: str = "                 ") -> None:
        remaining = content
        first = True
        while remaining:
            prefix = "" if first else continuation
            available = max(1, 68 - len(prefix))
            if len(remaining) <= available:
                lines.append(pad_line(prefix + remaining))
                return
            split_at = remaining.rfind(" ", 0, available + 1)
            if split_at <= 0:
                split_at = available
            lines.append(pad_line(prefix + remaining[:split_at].rstrip()))
            remaining = remaining[split_at:].lstrip()
            first = False

    lines = ["", T("📊 FlowPilot Telemetry Summary", "📊 FlowPilot 遥测摘要"), ""]
    lines.append(T(
        "  ╭─ Run Overview ────────────────────────────────────────────────────╮",
        "  ╭─ 任务概览 ───────────────────────────────────────────────────────╮",
    ))

    session, project, branch = run_context(run)
    if session:
        lines.append(pad_line(T(f"• Session:        {session}", f"• 会话:           {session}")))
    if project:
        project_text = f"{project} · {branch}" if branch else project
        lines.append(pad_line(T(f"• Project:        {project_text}", f"• 项目:           {project_text}")))

    started = fmt_local_timestamp(run.get("started_at_ms"), milliseconds=True)
    finished = fmt_local_timestamp(run.get("finished_at_ms"), milliseconds=True)
    if started:
        lines.append(pad_line(T(f"• Started:        {started}", f"• 开始时间:       {started}")))
    if finished:
        lines.append(pad_line(T(f"• Finished:       {finished}", f"• 完成时间:       {finished}")))
    started_ms = run.get("started_at_ms")
    finished_ms = run.get("finished_at_ms")
    if isinstance(started_ms, (int, float)) and isinstance(finished_ms, (int, float)):
        duration = fmt_duration_ms(finished_ms - started_ms)
        if duration:
            lines.append(pad_line(T(f"• Duration:       {duration}", f"• 持续时间:       {duration}")))

    lines.append(pad_line(T(f"• Participants:   {p_count}", f"• 参与者:         {p_count}")))
    lines.append(pad_line(T(f"• Parent:         {p_runtime} · {p_tokens}", f"• Parent:         {p_runtime} · {p_tokens}")))
    for worker in workers:
        usage = worker.get("usage") or {}
        state = worker.get("status") or "observed"
        state_label = {
            "completed": T("completed", "已完成"),
            "observed": T("observed", "已观测"),
            "running": T("running", "运行中"),
        }.get(str(state), str(state))
        w_type = worker.get("agent_type") or "worker"
        w_runtime = participant_runtime_label(worker, usage)
        w_tokens = f"{fmt_tokens(usage.get('total_tokens'))} tokens ({state_label})"
        label = f"• Worker [{w_type}]:"
        worker_line = f"{label} {w_runtime} · {w_tokens}"
        if display_width(worker_line) <= 68:
            lines.append(pad_line(worker_line))
        else:
            lines.append(pad_line(f"{label} {w_runtime}"))
            lines.append(pad_line(f"                 ↳ {w_tokens}"))
        worker_conclusion = compact_text(worker.get("conclusion"), 240)
        if worker_conclusion:
            append_wrapped_line(
                T(
                    f"  ↳ Result:       {worker_conclusion}",
                    f"  ↳ 结果:         {worker_conclusion}",
                ),
                continuation="                 ",
            )
    lines.append(pad_line(T(f"• Attributed:     {attr_tokens}{attr_credits}", f"• 归因用量:       {attr_tokens}{attr_credits}")))

    windows = run.get("quota_change_during_run") or []
    if windows:
        pieces: list[str] = []
        reset_pieces: list[str] = []
        for window in windows:
            before_match = next((item for item in run.get("quota_before", []) if item.get("window_duration_mins") == window.get("window_duration_mins")), None)
            old = before_match.get("used_percent") if before_match else None
            new = window.get("used_percent")
            delta = window.get("delta_percentage_points")
            label = window_label(window.get("window_duration_mins"))
            if old is not None and new is not None:
                old_text = fmt_percent(old) or "n/a"
                new_text = fmt_percent(new) or "n/a"
                if delta is None:
                    delta_text = "n/a"
                elif delta == 0:
                    delta_text = T("no change", "无变化")
                else:
                    delta_text = f"{delta:+g} pp"
                remaining_pct = fmt_percent(max(0, 100 - new)) if isinstance(new, (int, float)) and not isinstance(new, bool) else None
                if LANG == "zh":
                    remaining = f"；剩余 {remaining_pct}%" if remaining_pct is not None else ""
                    pieces.append(f"{label} 已用 {old_text}% → {new_text}%（{delta_text}{remaining}）")
                else:
                    remaining = f"; {remaining_pct}% remaining" if remaining_pct is not None else ""
                    pieces.append(f"{label} used {old_text}% → {new_text}% ({delta_text}{remaining})")
            elif new is not None:
                new_text = fmt_percent(new) or "n/a"
                remaining_pct = fmt_percent(max(0, 100 - new)) if isinstance(new, (int, float)) and not isinstance(new, bool) else None
                if LANG == "zh":
                    suffix = f"（剩余 {remaining_pct}%）" if remaining_pct is not None else ""
                    pieces.append(f"{label} 已用 {new_text}%{suffix}")
                else:
                    suffix = f" ({remaining_pct}% remaining)" if remaining_pct is not None else ""
                    pieces.append(f"{label} used {new_text}%{suffix}")
            reset = fmt_local_timestamp(window.get("resets_at"))
            if reset:
                reset_pieces.append(f"{label} {reset}")
        if pieces:
            lines.append(T(
                "  ├─ Quota & Windows ─────────────────────────────────────────────────┤",
                "  ├─ 额度与时间窗 ───────────────────────────────────────────────────┤",
            ))
            append_wrapped_line(T(f"• Account Quota:  {' | '.join(pieces)}", f"• 账户额度:       {' | '.join(pieces)}"))
            if reset_pieces:
                append_wrapped_line(T(f"• Resets:         {' | '.join(reset_pieces)}", f"• 重置时间:       {' | '.join(reset_pieces)}"))

    skills = run.get("skills_used") or []
    tools = run.get("tools_used") or []
    summary_info = run.get("summary_info") or {}

    if skills or tools or summary_info.get("conclusion"):
        lines.append(T(
            "  ├─ Insights & Trajectory ───────────────────────────────────────────┤",
            "  ├─ 执行详情与技能洞察 ──────────────────────────────────────────────┤",
        ))
        if skills:
            skills_str = ", ".join(f"{s.get('name')} (×{s.get('count', 1)})" for s in skills)
            append_wrapped_line(T(f"• Skills Used:    {skills_str}", f"• 调用技能:       {skills_str}"))
        if tools:
            tools_str = ", ".join(f"{t.get('name')} (×{t.get('count', 1)})" for t in tools)
            append_wrapped_line(T(f"• Tools / MCP:    {tools_str}", f"• 工具 / MCP:     {tools_str}"))
        if summary_info.get("conclusion"):
            conc = " ".join(summary_info["conclusion"].split())
            if len(conc) > 100:
                conc = conc[:97] + "..."
            append_wrapped_line(T(f"• Conclusion:     {conc}", f"• 交付结论:       {conc}"))

    lines.append("  ╰───────────────────────────────────────────────────────────────────╯")
    lines.append(T(
        "  ℹ  Note: Times use the local timezone; quota delta is account-wide; attributed usage is thread-based.",
        "  ℹ  说明：时间使用本地时区；额度变化为账户级；归因用量基于 thread 计算。",
    ))
    lines.append(T(
        "  💡 Tip: Run `codex-flow usage last` to review or `codex-flow doctor` to verify hooks.\n",
        "  💡 提示：运行 `codex-flow usage last` 可再次查看，运行 `codex-flow doctor` 可检查 hooks。\n",
    ))
    return "\n".join(lines)


def render_run_list(runs: list[dict[str, Any]], project: str | None = None, today: bool = False) -> str:
    if not runs:
        if LANG == "zh":
            msg = "未找到 FlowPilot 遥测任务记录"
            if project:
                msg += f"（项目：{project}）"
            if today:
                msg += "（今天）"
        else:
            msg = "No FlowPilot telemetry runs found"
            if project:
                msg += f" for project '{project}'"
            if today:
                msg += " today"
        return f"{msg}.\n"

    count = len(runs)
    lines = ["", T(
        f"📜 FlowPilot Task Telemetry History (Showing {count} task{'s' if count != 1 else ''})",
        f"📜 FlowPilot 任务遥测历史（显示 {count} 个任务）",
    ), ""]
    if LANG == "zh":
        hdr = f"  {'#':<4} {'时间':<17} {'项目':<18} {'会话':<20} {'WORKERS':<9} {'TOKENS':<10} {'状态':<12}"
    else:
        hdr = f"  {'#':<4} {'TIME':<17} {'PROJECT':<18} {'SESSION':<20} {'WORKERS':<9} {'TOKENS':<10} {'STATUS':<12}"
    lines.append(hdr)
    lines.append("  " + "─" * 94)

    for i, run in enumerate(runs, 1):
        enrich_run_metadata(run)
        session, proj, branch = run_context(run)
        idx_badge = f"{i}*" if i == 1 else str(i)
        started_ms = numeric_ms(run.get("started_at_ms"))
        finished_ms = numeric_ms(run.get("finished_at_ms"))
        if started_ms:
            lt = time.localtime(started_ms / 1000)
            time_str = f"{lt.tm_mon:02d}-{lt.tm_mday:02d} {lt.tm_hour:02d}:{lt.tm_min:02d}"
        else:
            time_str = T("unknown", "未知")
        dur_str = ""
        if started_ms and finished_ms and finished_ms >= started_ms:
            dur_str = f" ({fmt_duration_ms(finished_ms - started_ms)})"
        time_text = truncate_display(time_str + dur_str, 17)

        proj_text = ""
        if proj:
            proj_text = f"{proj} · {branch}" if branch else proj
        elif run.get("cwd"):
            try:
                proj_text = Path(str(run.get("cwd"))).name or str(run.get("cwd"))
            except Exception:
                proj_text = str(run.get("cwd"))
        proj_text = truncate_display(proj_text, 18)
        session_text = truncate_display(session or run.get("session_id") or T("unknown", "未知"), 20)

        workers = list((run.get("workers") or {}).values())
        w_count = len(workers)
        if w_count == 0:
            w_text = "0"
        else:
            completed = sum(1 for w in workers if w.get("status") == "completed")
            if LANG == "zh":
                w_text = f"{w_count} (完成)" if completed == w_count else f"{w_count} (观测)"
            else:
                w_text = f"{w_count} (cmp)" if completed == w_count else f"{w_count} (obs)"
        w_text = truncate_display(w_text, 9)

        parent = run.get("parent") or {}
        parent_usage = parent.get("usage_delta") if isinstance(parent, dict) else None
        usages = [parent_usage]
        usages.extend(w.get("usage") if isinstance(w, dict) else None for w in workers)
        tot_tok = aggregate_usage_value(usages, "total_tokens")
        tok_text = truncate_display(fmt_tokens(tot_tok) or "0", 10)
        status_text = T("● completed", "● 已完成") if finished_ms else T("○ running", "○ 运行中")
        row = (
            f"  {pad_display(idx_badge, 4)} "
            f"{pad_display(time_text, 17)} "
            f"{pad_display(proj_text, 18)} "
            f"{pad_display(session_text, 20)} "
            f"{pad_display(w_text, 9)} "
            f"{pad_display(tok_text, 10)} "
            f"{pad_display(status_text, 12)}"
        )
        lines.append(row)
    lines.append("")
    lines.append(T(
        "  💡 Tip: Run `codex-flow usage show <#>` to view details of any task.",
        "  💡 提示：运行 `codex-flow usage show <#>` 可查看任意任务详情。",
    ))
    lines.append("")
    return "\n".join(lines)


def render_project_stats(stats: dict[str, Any]) -> str:
    total_runs = stats.get("total_runs", 0)
    days = stats.get("days", 30)
    filter_proj = stats.get("project_filter")
    if total_runs == 0:
        if LANG == "zh":
            msg = f"最近 {days} 天没有遥测数据"
            if filter_proj:
                msg += f"（项目：{filter_proj}）"
        else:
            msg = f"No telemetry data recorded in the last {days} days"
            if filter_proj:
                msg += f" for project '{filter_proj}'"
        return f"{msg}.\n"

    def pad_line(content: str, width: int = 68) -> str:
        pad = max(0, width - display_width(content))
        return f"  │  {content}{' ' * pad} │"

    lines = [""]
    title = T(
        f"📊 FlowPilot Telemetry Aggregation (Last {days} Days)",
        f"📊 FlowPilot 遥测聚合统计（最近 {days} 天）",
    )
    if filter_proj:
        title = T(
            f"📊 FlowPilot Telemetry Aggregation: {filter_proj} (Last {days} Days)",
            f"📊 FlowPilot 遥测聚合统计：{filter_proj}（最近 {days} 天）",
        )
    lines += [title, "", T(
        "  ╭─ Overview ────────────────────────────────────────────────────────╮",
        "  ╭─ 概览 ───────────────────────────────────────────────────────────╮",
    )]

    delegated = stats.get("delegated_runs", 0)
    direct = stats.get("direct_runs", 0)
    lines.append(pad_line(T(
        f"• Total Tasks:     {total_runs} ({delegated} delegated, {direct} direct)",
        f"• 任务总数:       {total_runs}（{delegated} 个委派，{direct} 个直跑）",
    )))
    dur_str = fmt_duration_ms(stats.get("total_duration_ms")) or "0s"
    lines.append(pad_line(T(f"• Total Duration:  {dur_str} active time", f"• 总持续时间:     {dur_str} 活跃时间")))
    tot_tokens = stats.get("total_tokens", 0)
    credits_micros = stats.get("estimated_credits_micros")
    cred_str = f" · {credits_micros / 1_000_000:.3f} credits" if credits_micros is not None else ""
    lines.append(pad_line(T(f"• Attributed:      {fmt_tokens(tot_tokens)} tokens{cred_str}", f"• 归因用量:       {fmt_tokens(tot_tokens)} tokens{cred_str}")))
    p_tokens = stats.get("parent_tokens", 0)
    w_tokens = stats.get("worker_tokens", 0)
    p_pct = (p_tokens / tot_tokens * 100) if tot_tokens > 0 else 0.0
    w_pct = (w_tokens / tot_tokens * 100) if tot_tokens > 0 else 0.0
    lines.append(pad_line(T(f"• Parent Tokens:   {fmt_tokens(p_tokens)} tokens ({p_pct:.1f}%)", f"• Parent Tokens:   {fmt_tokens(p_tokens)} tokens ({p_pct:.1f}%)")))
    lines.append(pad_line(T(f"• Worker Tokens:   {fmt_tokens(w_tokens)} tokens ({w_pct:.1f}%)", f"• Worker Tokens:   {fmt_tokens(w_tokens)} tokens ({w_pct:.1f}%)")))

    lines.append(T(
        "  ├─ Cache & Efficiency ──────────────────────────────────────────────┤",
        "  ├─ 缓存与效率 ─────────────────────────────────────────────────────┤",
    ))
    cache_ratio = stats.get("cache_ratio", 0.0)
    cached_in = stats.get("cached_input_tokens", 0)
    lines.append(pad_line(T(
        f"• Cache Ratio:     {cache_ratio:.1f}% ({fmt_tokens(cached_in)} cached input tokens)",
        f"• 缓存比例:       {cache_ratio:.1f}%（{fmt_tokens(cached_in)} cached input tokens）",
    )))
    offload = stats.get("worker_offload_ratio", 0.0)
    lines.append(pad_line(T(
        f"• Worker Offload:  {offload:.1f}% compute offloaded to worker",
        f"• Worker 分流:     {offload:.1f}% 计算量下放给 worker",
    )))

    models = stats.get("models") or {}
    if models:
        lines.append(T(
            "  ├─ Model Breakdown ─────────────────────────────────────────────────┤",
            "  ├─ 模型分布 ───────────────────────────────────────────────────────┤",
        ))
        sorted_models = sorted(models.items(), key=lambda item: item[1].get("tokens", 0), reverse=True)
        for model_name, info in sorted_models:
            m_tok = info.get("tokens", 0)
            m_pct = (m_tok / tot_tokens * 100) if tot_tokens > 0 else 0.0
            m_calls = info.get("calls", 0)
            roles = "/".join(info.get("roles", []))
            call_label = T("calls", "次调用")
            lines.append(pad_line(f"• {pad_display(model_name, 16)} {pad_display(fmt_tokens(m_tok), 7, align='right')} tokens ({m_pct:>4.1f}% | {m_calls} {call_label} · {roles})"))

    projects = stats.get("projects") or {}
    if len(projects) > 1 and not filter_proj:
        lines.append(T(
            "  ├─ Projects Distribution ───────────────────────────────────────────┤",
            "  ├─ 项目分布 ───────────────────────────────────────────────────────┤",
        ))
        sorted_projs = sorted(projects.items(), key=lambda item: item[1].get("tokens", 0), reverse=True)
        for p_name, p_info in sorted_projs:
            p_r = p_info.get("runs", 0)
            p_tok = p_info.get("tokens", 0)
            p_dur = fmt_duration_ms(p_info.get("duration_ms")) or "0s"
            task_label = T("tasks", "个任务")
            lines.append(pad_line(f"• {pad_display(p_name, 16)} {p_r:>2} {task_label} · {pad_display(fmt_tokens(p_tok), 7, align='right')} tokens · {p_dur}"))

    lines.append("  ╰───────────────────────────────────────────────────────────────────╯")
    lines.append("")
    return "\n".join(lines)
