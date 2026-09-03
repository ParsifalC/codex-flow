import SwiftUI
import AppKit

/// Main expanded FlowPilot surface. Account remains a UI-only fourth tab so
/// existing Inspector/History/Analytics IPC commands stay backward compatible.
public struct SummaryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var updateService = FlowPilotUpdateService.shared
    public var isFullHeight: Bool = false

    @State private var showingAccount = false
    @State private var copiedSummary = false
    @State private var showUpdatePopover = false
    @State private var executionDetailsExpanded = false

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
    }

    private var currentRun: TaskRun? { state.inspectedRun ?? state.latestRun }

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
        .onChange(of: state.activeTab) { _, _ in
            if showingAccount { showingAccount = false }
        }
        .onChange(of: currentRun?.id) { _, _ in
            executionDetailsExpanded = false
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

            Button {
                showUpdatePopover.toggle()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: updateService.isRestartRequired ? "arrow.clockwise.circle" : "arrow.down.circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(updateService.hasUpdateBadge ? .cyan : .white.opacity(0.55))
                        .frame(width: 23, height: 23)
                        .background(Circle().fill(Color.white.opacity(0.045)))

                    if updateService.hasUpdateBadge {
                        Circle()
                            .fill(updateService.isRestartRequired ? Color.orange : Color.red)
                            .frame(width: 6.5, height: 6.5)
                            .overlay(Circle().stroke(Color.black.opacity(0.65), lineWidth: 1))
                            .offset(x: 1.5, y: -1.5)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(L("Software Update", "软件更新"))
            .popover(isPresented: $showUpdatePopover, arrowEdge: .top) {
                FlowPilotUpdateView()
            }

            chromeButton(
                state.isPrivacyMode ? "eye.slash.fill" : "eye.fill",
                state.isPrivacyMode ? .orange : .white.opacity(0.55),
                L("Privacy mode", "隐私模式")
            ) { state.isPrivacyMode.toggle() }

            chromeButton(
                state.isPinned ? "pin.fill" : "pin",
                state.isPinned ? .cyan : .white.opacity(0.55),
                L("Pin window", "置顶窗口")
            ) { state.isPinned.toggle() }

            chromeButton("chevron.down", .white.opacity(0.55), L("Collapse", "收起")) {
                state.collapse()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
    }

    private func chromeButton(_ icon: String, _ tint: Color, _ help: String, action: @escaping () -> Void) -> some View {
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
        HStack(spacing: 4) {
            ForEach(OverlayTab.allCases) { tab in
                TabButtonView(
                    title: tab.localizedTitle,
                    icon: tab.iconName,
                    selected: !showingAccount && state.activeTab == tab
                ) {
                    showingAccount = false
                    state.selectTab(tab)
                }
            }

            TabButtonView(
                title: L("Account", "账户"),
                icon: "person.crop.circle.fill",
                selected: showingAccount
            ) {
                showingAccount = true
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.14))
    }

    private struct TabButtonView: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 8.8, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.2, weight: selected ? .bold : .medium, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundColor(selected ? .white : (isHovered ? .white.opacity(0.85) : .white.opacity(0.52)))
            .frame(maxWidth: .infinity, minHeight: 26)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.cyan.opacity(0.22) : (isHovered ? Color.white.opacity(0.06) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(selected ? Color.cyan.opacity(0.32) : (isHovered ? Color.white.opacity(0.1) : Color.clear), lineWidth: 0.6)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
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
            if isFullHeight {
                inspectorContent(run)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    inspectorContent(run)
                }
                .frame(maxHeight: 440)
            }
        } else {
            idleInspector
        }
    }

    private func inspectorContent(_ run: TaskRun) -> some View {
        VStack(spacing: 8) {
            if state.inspectedRun != nil { historicalBanner }
            projectHeader(run)
            metricsGrid(run)

            if !run.effectiveQuotaWindows.isEmpty {
                QuotaWindowsView(windows: run.effectiveQuotaWindows)
            }

            taskNarrativeCard(run)
            participantsCard(run)
            TokenUsageBreakdownView(usage: run.aggregatedUsage)

            if run.hasSkillsOrTools {
                InspectorSkillsToolsView(run: run)
            }

            if !run.allWorkers.isEmpty {
                workerOutcomesCard(run)
            }

            if run.hasTrajectory || run.hasLogs {
                executionDetailCard(run)
            }

            actionFooter(run)
        }
        .padding(.top, 8)
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
            recentTaskMenu
            Button(L("Live", "当前任务")) { state.jumpToLive() }
                .buttonStyle(.plain)
                .font(.system(size: 8, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.cyan.opacity(0.3)))
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
                    Text("·").foregroundColor(.white.opacity(0.25))
                    HoverRevealText(
                        branch,
                        font: .system(size: 8.8, weight: .medium, design: .monospaced),
                        foregroundColor: .cyan.opacity(0.88),
                        lineLimit: 1,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 320
                    )
                }

                if !state.isPrivacyMode && !isFullHeight {
                    recentTaskMenu
                }

                Spacer(minLength: 2)
                statusBadge(run)
            }

            HoverRevealText(
                run.thread?.preview ?? run.summary ?? run.sessionTitle,
                font: .system(size: 9.4),
                foregroundColor: .white.opacity(0.63),
                lineLimit: 1,
                privacyBlur: state.isPrivacyMode,
                popoverWidth: 390
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .background(cardBackground())
    }

    private var recentTaskMenu: some View {
        Menu {
            if let latest = state.latestRun {
                Section(L("Live Session", "当前会话")) {
                    Button {
                        state.jumpToLive()
                    } label: {
                        Text(L("⚡ Live · \(latest.projectName) · \(latest.localizedFormattedDate)", "⚡ 当前 · \(latest.projectName) · \(latest.localizedFormattedDate)"))
                    }
                }
            }

            if !state.recentChats.isEmpty {
                Section(L("Recent Chats & Tasks", "最近对话任务")) {
                    ForEach(Array(state.recentChats.prefix(10).enumerated()), id: \.element.id) { index, chat in
                        if let latest = chat.latestRun {
                            Button {
                                if latest.id == state.latestRun?.id {
                                    state.jumpToLive()
                                } else {
                                    state.inspect(run: latest)
                                }
                            } label: {
                                Text("#\(index + 1) \(chat.projectName) · \(chat.localizedFormattedDate) · \(shortMenuText(chat.title))")
                            }
                        }
                    }
                }
            }

            Divider()

            Button {
                state.selectTab(.history)
            } label: {
                Label(L("Browse All History", "浏览全部历史"), systemImage: "clock.arrow.circlepath")
            }
        } label: {
            Image(systemName: "chevron.down.circle.fill")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.42))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L("Switch task", "切换任务"))
    }

    private func shortMenuText(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 34 ? String(cleaned.prefix(34)) + "…" : cleaned
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

            // The old Cost ring treated optional credit telemetry like USD and was
            // frequently empty. Output tokens are deterministic and unambiguous.
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
        Double(usage.effectiveOutputTokens) / Double(max(1, usage.totalTokens ?? 0))
    }

    private func taskNarrativeCard(_ run: TaskRun) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("sparkles.rectangle.stack.fill", L("Task Objective & Summary", "任务目标与概要说明"), .cyan)

            if let goal = run.effectiveGoal, !goal.isEmpty {
                narrativeBlock(L("Objective", "目标"), "target", goal, .cyan, 3)
            }

            if let conclusion = run.effectiveConclusion, !conclusion.isEmpty {
                narrativeBlock(L("Outcome / Conclusion", "交付结论"), "checkmark.seal.fill", conclusion, .green, 4)
            }
        }
        .padding(8)
        .background(cardBackground())
    }

    private func narrativeBlock(_ label: String, _ icon: String, _ text: String, _ tint: Color, _ lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: icon)
                .font(.system(size: 8.2, weight: .bold))
                .foregroundColor(tint.opacity(0.9))

            HoverRevealText(
                text,
                font: .system(size: 9.3),
                foregroundColor: .white.opacity(0.88),
                lineLimit: lines,
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
                "brain.head.profile",
                L("Parent", "父 Agent"),
                run.parent?.displayModel ?? L("Direct CLI", "直接 CLI"),
                participantSubtitle(run.parent),
                .indigo
            )

            participantBlock(
                "person.2.fill",
                L("Workers", "Worker"),
                workerSummaryText(run),
                L("\(run.allWorkers.count) subagents", "\(run.allWorkers.count) 个子 Agent"),
                .teal
            )
        }
    }

    private func workerSummaryText(_ run: TaskRun) -> String {
        if run.allWorkers.isEmpty { return L("Direct execution", "直接执行") }
        if run.allWorkers.count == 1 { return run.allWorkers[0].name ?? run.allWorkers[0].displayModel }
        return L("\(run.allWorkers.count) workers", "\(run.allWorkers.count) 个 Worker")
    }

    private func participantBlock(_ icon: String, _ title: String, _ name: String, _ subtitle: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(tint.opacity(0.9))

            HoverRevealText(
                name,
                font: .system(size: 9.8, weight: .bold, design: .rounded),
                foregroundColor: .white.opacity(0.9),
                lineLimit: 1,
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
        VStack(alignment: .leading, spacing: 5) {
            sectionHeader("checkmark.bubble.fill", L("Worker Outcomes", "Worker 执行结果"), .teal)

            ForEach(run.allWorkers) { worker in
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

                    if let conclusion = worker.conclusion, !conclusion.isEmpty {
                        HoverRevealText(
                            conclusion,
                            font: .system(size: 8.8),
                            foregroundColor: .white.opacity(0.64),
                            lineLimit: 3,
                            privacyBlur: state.isPrivacyMode,
                            popoverWidth: 390
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.025)))
            }
        }
        .padding(8)
        .background(cardBackground())
    }

    private func executionDetailCard(_ run: TaskRun) -> some View {
        let stepCount = run.trajectory?.count ?? 0
        let logCount = run.logs?.count ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    executionDetailsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "point.filled.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 8))
                        .foregroundColor(.indigo)
                    Text(L("Execution Details", "执行详情"))
                        .font(.system(size: 8.8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(L("\(stepCount) steps · \(logCount) logs", "\(stepCount) 步 · \(logCount) 条日志"))
                        .font(.system(size: 7.3, weight: .medium))
                        .foregroundColor(.white.opacity(0.38))
                    Image(systemName: executionDetailsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if executionDetailsExpanded {
                ForEach(Array((run.trajectory ?? []).prefix(6))) { step in
                    HStack(alignment: .top, spacing: 5) {
                        Circle()
                            .fill(step.status == "error" ? Color.orange : Color.cyan)
                            .frame(width: 4.5, height: 4.5)
                            .padding(.top, 4)

                        VStack(alignment: .leading, spacing: 1) {
                            HoverRevealText(
                                step.title ?? step.name ?? "Step",
                                font: .system(size: 8.6, weight: .semibold),
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

                ForEach(Array((run.logs ?? []).suffix(4))) { entry in
                    HStack(alignment: .top, spacing: 5) {
                        Circle()
                            .fill(entry.level == "error" ? Color.orange : Color.green)
                            .frame(width: 4, height: 4)
                            .padding(.top, 4)

                        HoverRevealText(
                            entry.message ?? "",
                            font: .system(size: 7.7, design: .monospaced),
                            foregroundColor: entry.level == "error" ? .orange.opacity(0.85) : .white.opacity(0.58),
                            lineLimit: 2,
                            privacyBlur: state.isPrivacyMode,
                            popoverWidth: 420
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(8)
        .background(cardBackground())
    }

    private func actionFooter(_ run: TaskRun) -> some View {
        HStack(spacing: 6) {
            Button {
                copySummary(run)
            } label: {
                Label(
                    copiedSummary ? L("Copied", "已复制") : L("Copy summary", "复制摘要"),
                    systemImage: copiedSummary ? "checkmark" : "doc.on.doc"
                )
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

            HStack(spacing: 7) {
                Button { showingAccount = true } label: {
                    Label(L("Account Limits", "账户额度"), systemImage: "person.crop.circle")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))
                }
                .buttonStyle(.plain)

                Button { openConsole() } label: {
                    Label(L("Console", "控制台"), systemImage: "terminal.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }

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
        run.isRunning ? .cyan : (run.isError ? .orange : .green)
    }

    private func runStatusText(_ run: TaskRun) -> String {
        run.isRunning
            ? L("RUNNING", "运行中")
            : (run.isError ? L("FAILED", "失败") : L("COMPLETED", "已完成"))
    }

    private var statusText: String { currentRun.map(runStatusText) ?? L("READY", "就绪") }
    private var statusColor: Color { currentRun.map(runStatusColor) ?? .green }

    private func sectionHeader(_ icon: String, _ title: String, _ tint: Color) -> some View {
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
        let base = tint ?? Color.white
        return RoundedRectangle(cornerRadius: 9)
            .fill(base.opacity(tint == nil ? 0.04 : 0.07))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(base.opacity(tint == nil ? 0.075 : 0.18), lineWidth: 0.7)
            )
    }

    private func copySummary(_ run: TaskRun) {
        let usage = run.aggregatedUsage
        let text = L(
            "FlowPilot Task Summary\nProject: \(run.projectName)\nDuration: \(run.formattedDuration)\nTotal tokens: \(run.formattedTotalTokens)\nInput tokens: \(TaskRun.formatTokenCount(usage.effectivePromptTokens))\nOutput tokens: \(TaskRun.formatTokenCount(usage.effectiveOutputTokens))\nWorkers: \(run.allWorkers.count)\nSummary: \(run.summary ?? run.sessionTitle)",
            "FlowPilot 任务摘要\n项目：\(run.projectName)\n耗时：\(run.formattedDuration)\n总 Token：\(run.formattedTotalTokens)\n输入 Token：\(TaskRun.formatTokenCount(usage.effectivePromptTokens))\n输出 Token：\(TaskRun.formatTokenCount(usage.effectiveOutputTokens))\nWorker：\(run.allWorkers.count)\n摘要：\(run.summary ?? run.sessionTitle)"
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
                Circle().stroke(Color.white.opacity(0.07), lineWidth: 3)
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

    private var ordered: [QuotaWindow] {
        windows.sorted { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(L("Quota remaining at task completion", "任务结束额度剩余"), systemImage: "gauge.with.needle.fill")
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
            }

            ForEach(ordered) { quotaRow($0) }
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
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(window.label)
                    .font(.system(size: 8, weight: .heavy, design: .monospaced))
                    .foregroundColor(tint)
                    .frame(width: 34, alignment: .leading)

                Text(String(format: L("%.0f%% left", "剩余 %.0f%%"), remaining))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.72))

                Spacer(minLength: 2)

                if let reset = window.localizedFormattedResetsAt {
                    Text(reset)
                        .font(.system(size: 7.3, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.42))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .allowsTightening(true)
                        .truncationMode(.tail)
                        .frame(maxWidth: 132, alignment: .trailing)
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

// MARK: - Token Usage

public struct TokenUsageBreakdownView: View {
    public let usage: TokenUsage

    public init(usage: TokenUsage) {
        self.usage = usage
    }

    public var body: some View {
        // `inputTokens` includes cached input and `outputTokens` can include
        // reasoning output. Make the rendered segments mutually exclusive so
        // the bar and legend do not double-count those subsets.
        let input = usage.effectivePromptTokens
        let output = usage.effectiveOutputTokens
        let cached = min(max(0, usage.effectiveCachedTokens), max(0, input))
        let reasoning = min(max(0, usage.effectiveReasoningTokens), max(0, output))
        let newInput = max(0, input - cached)
        let visibleOutput = max(0, output - reasoning)
        let segmentedTotal = newInput + cached + visibleOutput + reasoning
        let total = max(1, segmentedTotal)
        let reportedTotal = usage.totalTokens ?? segmentedTotal

        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L("Token usage", "Token 用量"))
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                Spacer()
                Text(TaskRun.formatTokenCount(reportedTotal))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
            }

            GeometryReader { proxy in
                HStack(spacing: 1) {
                    segment(proxy.size.width, newInput, total, .cyan)
                    segment(proxy.size.width, cached, total, .indigo)
                    segment(proxy.size.width, visibleOutput, total, .green)
                    segment(proxy.size.width, reasoning, total, .purple)
                }
            }
            .frame(height: 5)
            .clipShape(Capsule())

            HStack(spacing: 8) {
                legend(L("New input", "新输入"), newInput, .cyan)
                if cached > 0 {
                    legend(L("Cached", "缓存"), cached, .indigo)
                }
                legend(L("Output", "输出"), visibleOutput, .green)
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

    private func segment(_ width: CGFloat, _ value: Int, _ total: Int, _ color: Color) -> some View {
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
