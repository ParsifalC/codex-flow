import SwiftUI
import AppKit

/// Main expanded FlowPilot surface.
///
/// The Account surface is intentionally a UI-level fourth tab instead of a
/// persisted `OverlayTab` enum case so older IPC clients that only know
/// inspector/history/analytics remain wire-compatible.
public struct SummaryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false

    @State private var showingAccount = false
    @State private var copiedSummary = false

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
    }

    private var currentRun: TaskRun? {
        state.inspectedRun ?? state.latestRun
    }

    public var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().background(Color.white.opacity(0.07))
            tabBar
            Divider().background(Color.white.opacity(0.06))

            Group {
                if showingAccount {
                    AccountView(state: state, isFullHeight: isFullHeight)
                } else {
                    switch state.activeTab {
                    case .inspector:
                        inspectorSurface
                    case .history:
                        HistoryView(state: state, isFullHeight: isFullHeight)
                    case .analytics:
                        AnalyticsView(state: state, isFullHeight: isFullHeight)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
        )
        .onChange(of: state.activeTab) { _ in
            // An IPC tab command should take precedence over the local Account tab.
            if showingAccount {
                showingAccount = false
            }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 7) {
            FlowPilotLogoView(size: 29, showGlow: true, withBolt: false, text: "FP")
                .frame(width: 29, height: 29)

            VStack(alignment: .leading, spacing: 0) {
                Text("FlowPilot")
                    .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text(statusText)
                    .font(.system(size: 7.8, weight: .medium, design: .rounded))
                    .foregroundColor(statusColor.opacity(0.85))
            }

            Spacer()

            chromeButton(
                icon: state.isPrivacyMode ? "eye.slash.fill" : "eye.fill",
                tint: state.isPrivacyMode ? .orange : .white.opacity(0.55),
                help: L("Privacy mode", "隐私模式")
            ) {
                state.isPrivacyMode.toggle()
            }

            chromeButton(
                icon: state.isPinned ? "pin.fill" : "pin",
                tint: state.isPinned ? .cyan : .white.opacity(0.55),
                help: L("Pin window", "置顶窗口")
            ) {
                state.isPinned.toggle()
            }

            chromeButton(
                icon: "chevron.down",
                tint: .white.opacity(0.55),
                help: L("Collapse", "收起")
            ) {
                state.collapse()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private func chromeButton(icon: String, tint: Color, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 23, height: 23)
                .background(Circle().fill(Color.white.opacity(0.045)))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(OverlayTab.allCases) { tab in
                tabButton(
                    title: tab.localizedTitle,
                    icon: tab.iconName,
                    selected: !showingAccount && state.activeTab == tab
                ) {
                    showingAccount = false
                    state.selectTab(tab)
                }
            }

            tabButton(
                title: L("Account", "账户"),
                icon: "person.crop.circle.fill",
                selected: showingAccount
            ) {
                showingAccount = true
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.12))
    }

    private func tabButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 7.8, weight: .semibold))
                Text(title)
                    .font(.system(size: 8.4, weight: selected ? .bold : .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundColor(selected ? .white : .white.opacity(0.48))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.cyan.opacity(0.22) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(selected ? Color.cyan.opacity(0.32) : Color.clear, lineWidth: 0.6)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.055, green: 0.062, blue: 0.085).opacity(0.98),
                        Color(red: 0.035, green: 0.041, blue: 0.058).opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorSurface: some View {
        if let run = currentRun {
            let content = VStack(spacing: 8) {
                if state.inspectedRun != nil {
                    historicalBanner
                }
                projectHeader(run)
                metricsGrid(run)

                if !run.effectiveQuotaWindows.isEmpty {
                    QuotaWindowsView(windows: run.effectiveQuotaWindows)
                }

                taskNarrativeCard(run)
                participantsCard(run)
                TokenUsageBreakdownView(usage: run.aggregatedUsage)

                if run.allWorkers.contains(where: { !($0.conclusion ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    workerOutcomesCard(run)
                }

                if run.hasTrajectory {
                    trajectoryCard(run)
                }

                if run.hasLogs {
                    logsCard(run)
                }

                actionFooter(run)
            }
            .padding(.top, 8)

            if isFullHeight {
                content
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                }
                .frame(maxHeight: 440)
            }
        } else {
            idleInspector
        }
    }

    private var historicalBanner: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 8.5))
                .foregroundColor(.cyan)
            Text(L("Viewing historical task", "正在查看历史任务"))
                .font(.system(size: 8.8, weight: .semibold))
                .foregroundColor(.cyan)
            Spacer()
            Button {
                state.jumpToLive()
            } label: {
                Text(L("Live", "当前任务"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.cyan.opacity(0.3)))
            }
            .buttonStyle(.plain)
        }
        .padding(7)
        .background(cardBackground(tint: .cyan))
    }

    private func projectHeader(_ run: TaskRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.48))

                HoverRevealText(
                    run.projectName,
                    font: .system(size: 10, weight: .bold, design: .rounded),
                    foregroundColor: .white.opacity(0.94),
                    lineLimit: 1,
                    privacyBlur: state.isPrivacyMode,
                    popoverWidth: 300
                )

                if let branch = run.gitBranch, !branch.isEmpty {
                    Text("·")
                        .foregroundColor(.white.opacity(0.25))
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 7))
                        .foregroundColor(.cyan.opacity(0.85))
                    HoverRevealText(
                        branch,
                        font: .system(size: 8.8, weight: .medium, design: .monospaced),
                        foregroundColor: .cyan.opacity(0.88),
                        lineLimit: 1,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 320
                    )
                }

                Spacer(minLength: 2)
                statusBadge(run)
            }

            let preview = run.thread?.preview ?? run.summary ?? run.sessionTitle
            HoverRevealText(
                preview,
                font: .system(size: 9.4),
                foregroundColor: .white.opacity(0.63),
                lineLimit: 1,
                privacyBlur: state.isPrivacyMode,
                popoverWidth: 380
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(cardBackground())
    }

    private func metricsGrid(_ run: TaskRun) -> some View {
        let usage = run.aggregatedUsage
        return HStack(spacing: 6) {
            InspectorMetricView(
                title: L("Time", "耗时"),
                value: run.formattedDuration,
                detail: L("wall time", "任务时长"),
                icon: "timer",
                accent: .cyan,
                progress: min(1, run.durationSeconds / 600.0)
            )

            InspectorMetricView(
                title: L("Tokens", "Token"),
                value: run.formattedCompactTokens,
                detail: L("total", "总用量"),
                icon: "circle.grid.cross.fill",
                accent: Color(red: 0.95, green: 0.35, blue: 0.8),
                progress: min(1, Double(usage.totalTokens ?? 0) / 100_000.0)
            )

            // This intentionally replaces the old "Cost" ring. Credits are not
            // monetary USD and are often unavailable, so presenting them as cost
            // was both ambiguous and commonly blank.
            InspectorMetricView(
                title: L("Output", "输出"),
                value: TaskRun.formatTokenCount(usage.effectiveOutputTokens),
                detail: L("tokens", "Token"),
                icon: "arrow.up.circle.fill",
                accent: Color(red: 0.25, green: 0.88, blue: 0.58),
                progress: outputShare(usage)
            )
        }
    }

    private func outputShare(_ usage: TokenUsage) -> Double {
        let total = max(1, usage.totalTokens ?? 0)
        return min(1, Double(usage.effectiveOutputTokens) / Double(total))
    }

    private func taskNarrativeCard(_ run: TaskRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader(icon: "sparkles.rectangle.stack.fill", title: L("Task Objective & Summary", "任务目标与概要说明"), tint: .cyan)

            if let goal = run.effectiveGoal, !goal.isEmpty {
                narrativeBlock(
                    label: L("Objective", "目标"),
                    icon: "target",
                    text: goal,
                    tint: .cyan,
                    lineLimit: 3
                )
            }

            if let conclusion = run.effectiveConclusion, !conclusion.isEmpty {
                narrativeBlock(
                    label: L("Outcome / Conclusion", "交付结论"),
                    icon: "checkmark.seal.fill",
                    text: conclusion,
                    tint: Color(red: 0.25, green: 0.88, blue: 0.58),
                    lineLimit: 4
                )
            }
        }
        .padding(8)
        .background(cardBackground())
    }

    private func narrativeBlock(label: String, icon: String, text: String, tint: Color, lineLimit: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 7.5))
                Text(label)
                    .font(.system(size: 8.2, weight: .bold))
            }
            .foregroundColor(tint.opacity(0.9))

            HoverRevealText(
                text,
                font: .system(size: 9.3),
                foregroundColor: .white.opacity(0.88),
                lineLimit: lineLimit,
                privacyBlur: state.isPrivacyMode,
                popoverWidth: 390
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.07)))
    }

    private func participantsCard(_ run: TaskRun) -> some View {
        HStack(spacing: 6) {
            participantBlock(
                icon: "brain.head.profile",
                title: L("Parent", "父 Agent"),
                name: run.parent?.displayModel ?? L("Direct CLI", "直接 CLI"),
                subtitle: participantSubtitle(run.parent),
                tint: .indigo
            )

            let workerSummary: String
            if run.allWorkers.isEmpty {
                workerSummary = L("Direct execution", "直接执行")
            } else if run.allWorkers.count == 1 {
                workerSummary = run.allWorkers[0].name ?? run.allWorkers[0].displayModel
            } else {
                workerSummary = L("\(run.allWorkers.count) workers", "\(run.allWorkers.count) 个 Worker")
            }

            participantBlock(
                icon: "person.2.fill",
                title: L("Workers", "Worker"),
                name: workerSummary,
                subtitle: L("\(run.allWorkers.count) subagents", "\(run.allWorkers.count) 个子 Agent"),
                tint: .teal
            )
        }
    }

    private func participantBlock(icon: String, title: String, name: String, subtitle: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundColor(tint.opacity(0.9))
                Text(title)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.58))
            }

            HoverRevealText(
                name,
                font: .system(size: 9.8, weight: .bold, design: .rounded),
                foregroundColor: .white.opacity(0.9),
                lineLimit: 1,
                privacyBlur: false,
                popoverWidth: 280
            )

            Text(subtitle)
                .font(.system(size: 7.8))
                .foregroundColor(.white.opacity(0.4))
                .lineLimit(1)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground())
    }

    private func participantSubtitle(_ participant: ParticipantInfo?) -> String {
        guard let participant else { return L("No usage data", "暂无用量数据") }
        let tokens = participant.effectiveUsage?.totalTokens ?? 0
        if let effort = participant.displayEffort {
            return "\(effort) · \(TaskRun.formatTokenCount(tokens)) tokens"
        }
        return "\(TaskRun.formatTokenCount(tokens)) tokens"
    }

    private func workerOutcomesCard(_ run: TaskRun) -> some View {
        let workers = run.allWorkers.filter {
            !($0.conclusion ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return VStack(alignment: .leading, spacing: 5) {
            sectionHeader(icon: "checkmark.bubble.fill", title: L("Worker Outcomes", "Worker 执行结果"), tint: .teal)

            ForEach(workers) { worker in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        HoverRevealText(
                            worker.agentType ?? worker.name ?? L("Worker", "Worker"),
                            font: .system(size: 8.7, weight: .semibold, design: .rounded),
                            foregroundColor: .white.opacity(0.88),
                            lineLimit: 1,
                            popoverWidth: 300
                        )
                        Spacer(minLength: 4)
                        HoverRevealText(
                            worker.displayModel,
                            font: .system(size: 7.7, weight: .medium, design: .monospaced),
                            foregroundColor: .teal.opacity(0.78),
                            lineLimit: 1,
                            popoverWidth: 280
                        )
                    }

                    HoverRevealText(
                        worker.conclusion ?? "",
                        font: .system(size: 8.8),
                        foregroundColor: .white.opacity(0.64),
                        lineLimit: 3,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 390
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.025)))
            }
        }
        .padding(8)
        .background(cardBackground())
    }

    private func trajectoryCard(_ run: TaskRun) -> some View {
        let steps = run.trajectory ?? []
        return VStack(alignment: .leading, spacing: 5) {
            sectionHeader(icon: "point.filled.topleft.down.curvedto.point.bottomright.up", title: L("Execution Trajectory", "执行步骤轨迹"), tint: .indigo)

            ForEach(Array(steps.prefix(8))) { step in
                HStack(alignment: .top, spacing: 5) {
                    Circle()
                        .fill(step.status == "error" ? Color.orange : Color.cyan)
                        .frame(width: 4.5, height: 4.5)
                        .padding(.top, 4)

                    VStack(alignment: .leading, spacing: 1) {
                        HoverRevealText(
                            step.title ?? step.name ?? "Step",
                            font: .system(size: 8.7, weight: .semibold),
                            foregroundColor: .white.opacity(0.82),
                            lineLimit: 1,
                            popoverWidth: 360
                        )
                        if let detail = step.detail, !detail.isEmpty {
                            HoverRevealText(
                                detail,
                                font: .system(size: 7.8, design: .monospaced),
                                foregroundColor: .white.opacity(0.5),
                                lineLimit: 1,
                                privacyBlur: state.isPrivacyMode,
                                popoverWidth: 410
                            )
                        }
                    }
                }
            }

            if steps.count > 8 {
                Text(L("+\(steps.count - 8) more steps", "还有 \(steps.count - 8) 个步骤"))
                    .font(.system(size: 7.8))
                    .foregroundColor(.white.opacity(0.38))
            }
        }
        .padding(8)
        .background(cardBackground())
    }

    private func logsCard(_ run: TaskRun) -> some View {
        let logs = Array((run.logs ?? []).suffix(6))
        return VStack(alignment: .leading, spacing: 4) {
            sectionHeader(icon: "doc.text.magnifyingglass", title: L("Execution Logs", "执行日志流"), tint: .teal)

            ForEach(logs) { entry in
                HStack(alignment: .top, spacing: 4) {
                    Circle()
                        .fill(entry.level == "error" ? Color.orange : Color.green)
                        .frame(width: 4, height: 4)
                        .padding(.top, 4)
                    HoverRevealText(
                        entry.message ?? "",
                        font: .system(size: 7.8, design: .monospaced),
                        foregroundColor: entry.level == "error" ? .orange.opacity(0.85) : .white.opacity(0.65),
                        lineLimit: 2,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 420
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.28)).overlay(
            RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.06), lineWidth: 0.6)
        ))
    }

    private func actionFooter(_ run: TaskRun) -> some View {
        HStack(spacing: 6) {
            Button {
                copySummary(run)
            } label: {
                Label(copiedSummary ? L("Copied", "已复制") : L("Copy summary", "复制摘要"), systemImage: copiedSummary ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 8.6, weight: .semibold))
                    .foregroundColor(copiedSummary ? .green : .white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)

            Button {
                openConsole()
            } label: {
                Label(L("Console", "控制台"), systemImage: "terminal.fill")
                    .font(.system(size: 8.6, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(run.localizedFormattedDate)
                .font(.system(size: 7.8))
                .foregroundColor(.white.opacity(0.35))
        }
    }

    private var idleInspector: some View {
        VStack(spacing: 10) {
            FlowPilotLogoView(size: 58, showGlow: true, withBolt: true, text: "FlowPilot")
                .frame(width: 58, height: 58)
                .padding(.top, 20)
            Text(L("FlowPilot is Ready", "FlowPilot 已就绪"))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(L("Listening for live task and usage telemetry", "正在监听任务与用量遥测"))
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.48))
            Button {
                showingAccount = true
            } label: {
                Label(L("View Account Limits", "查看账户额度"), systemImage: "person.crop.circle")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.cyan.opacity(0.12)))
            }
            .buttonStyle(.plain)
            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }

    // MARK: - Helpers

    private func statusBadge(_ run: TaskRun) -> some View {
        HStack(spacing: 3) {
            Circle().fill(runStatusColor(run)).frame(width: 4.5, height: 4.5)
            Text(runStatusText(run))
                .font(.system(size: 7.4, weight: .bold, design: .rounded))
        }
        .foregroundColor(runStatusColor(run))
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(runStatusColor(run).opacity(0.12)))
    }

    private func runStatusColor(_ run: TaskRun) -> Color {
        if run.isRunning { return .cyan }
        if run.isError { return .orange }
        return Color(red: 0.25, green: 0.88, blue: 0.58)
    }

    private func runStatusText(_ run: TaskRun) -> String {
        if run.isRunning { return L("RUNNING", "运行中") }
        if run.isError { return L("FAILED", "失败") }
        return L("COMPLETED", "已完成")
    }

    private var statusText: String {
        guard let run = currentRun else { return L("READY", "就绪") }
        return runStatusText(run)
    }

    private var statusColor: Color {
        guard let run = currentRun else { return Color(red: 0.25, green: 0.88, blue: 0.58) }
        return runStatusColor(run)
    }

    private func sectionHeader(icon: String, title: String, tint: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8))
                .foregroundColor(tint)
            Text(title)
                .font(.system(size: 8.8, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
        }
    }

    private func cardBackground(tint: Color? = nil) -> some View {
        RoundedRectangle(cornerRadius: 9)
            .fill((tint ?? .white).opacity(tint == nil ? 0.04 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke((tint ?? .white).opacity(tint == nil ? 0.075 : 0.18), lineWidth: 0.7)
            )
    }

    private func copySummary(_ run: TaskRun) {
        let usage = run.aggregatedUsage
        let text = L(
            """
            FlowPilot Task Summary
            Project: \(run.projectName) (\(run.gitBranch ?? "main"))
            Duration: \(run.formattedDuration)
            Total tokens: \(run.formattedTotalTokens)
            Input tokens: \(TaskRun.formatTokenCount(usage.effectivePromptTokens))
            Output tokens: \(TaskRun.formatTokenCount(usage.effectiveOutputTokens))
            Cached input: \(TaskRun.formatTokenCount(usage.effectiveCachedTokens))
            Parent: \(run.parent?.displayModel ?? "unknown")
            Workers: \(run.allWorkers.count)
            Summary: \(run.summary ?? run.sessionTitle)
            """,
            """
            FlowPilot 任务摘要
            项目：\(run.projectName)（\(run.gitBranch ?? "main")）
            耗时：\(run.formattedDuration)
            总 Token：\(run.formattedTotalTokens)
            输入 Token：\(TaskRun.formatTokenCount(usage.effectivePromptTokens))
            输出 Token：\(TaskRun.formatTokenCount(usage.effectiveOutputTokens))
            缓存输入：\(TaskRun.formatTokenCount(usage.effectiveCachedTokens))
            父 Agent：\(run.parent?.displayModel ?? "unknown")
            Worker：\(run.allWorkers.count)
            摘要：\(run.summary ?? run.sessionTitle)
            """
        )

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedSummary = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copiedSummary = false
        }
    }

    private func openConsole() {
        let script = """
        tell application "Terminal"
            activate
            do script "codex-flow"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }
}

// MARK: - Inspector Metric

public struct InspectorMetricView: View {
    public let title: String
    public let value: String
    public let detail: String
    public let icon: String
    public let accent: Color
    public let progress: Double

    public var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.07), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.015, min(1, progress))))
                    .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: icon)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(accent)
            }
            .frame(width: 29, height: 29)

            Text(title)
                .font(.system(size: 7.6, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.48))
                .textCase(.uppercase)

            Text(value)
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(detail)
                .font(.system(size: 6.9))
                .foregroundColor(.white.opacity(0.32))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 0.7))
        )
    }
}

// MARK: - Quota Windows

public struct QuotaWindowsView: View {
    public let windows: [QuotaWindow]

    public init(windows: [QuotaWindow]) {
        self.windows = windows
    }

    private var orderedWindows: [QuotaWindow] {
        windows.sorted { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("Quota remaining", "额度剩余"), systemImage: "gauge.with.needle.fill")
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                if let reset = orderedWindows.first?.localizedFormattedResetsAt {
                    Text(reset)
                        .font(.system(size: 7.4, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            ForEach(orderedWindows) { window in
                quotaRow(window)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 0.7))
        )
    }

    private func quotaRow(_ window: QuotaWindow) -> some View {
        let used = max(0, min(100, window.usedPercent ?? 0))
        let remaining = window.remainingPercent
        let tint: Color = used >= 85 ? .orange : (used >= 60 ? .yellow : .cyan)
        return VStack(spacing: 3) {
            HStack {
                Text(window.label)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundColor(tint)
                    .frame(width: 34, alignment: .leading)
                Text(String(format: L("%.0f%% left", "剩余 %.0f%%"), remaining))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))
                Spacer()
                if let reset = window.localizedFormattedResetsAt {
                    Text(reset)
                        .font(.system(size: 7.3, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.42))
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.075))
                    Capsule()
                        .fill(tint)
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, remaining / 100.0))))
                }
            }
            .frame(height: 4)
        }
    }
}

// MARK: - Token Usage Breakdown

public struct TokenUsageBreakdownView: View {
    public let usage: TokenUsage

    public init(usage: TokenUsage) {
        self.usage = usage
    }

    public var body: some View {
        let input = usage.effectivePromptTokens
        let output = usage.effectiveOutputTokens
        let cached = usage.effectiveCachedTokens
        let reasoning = usage.effectiveReasoningTokens
        let total = max(1, input + output + cached + reasoning)

        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Token usage", "Token 用量"))
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(TaskRun.formatTokenCount(usage.totalTokens ?? 0))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
            }

            GeometryReader { proxy in
                HStack(spacing: 1) {
                    usageSegment(width: proxy.size.width, value: input, total: total, color: .cyan)
                    usageSegment(width: proxy.size.width, value: output, total: total, color: .green)
                    usageSegment(width: proxy.size.width, value: cached, total: total, color: .indigo)
                    usageSegment(width: proxy.size.width, value: reasoning, total: total, color: .purple)
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())

            HStack(spacing: 8) {
                legend(L("Input", "输入"), input, .cyan)
                legend(L("Output", "输出"), output, .green)
                legend(L("Cached", "缓存"), cached, .indigo)
                if reasoning > 0 {
                    legend(L("Reasoning", "推理"), reasoning, .purple)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.07), lineWidth: 0.7))
        )
    }

    private func usageSegment(width: CGFloat, value: Int, total: Int, color: Color) -> some View {
        color.frame(width: max(0, width * CGFloat(Double(value) / Double(total))))
    }

    private func legend(_ title: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 2.5) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text("\(title) \(TaskRun.formatTokenCount(value))")
                .font(.system(size: 7.1, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
        }
    }
}
