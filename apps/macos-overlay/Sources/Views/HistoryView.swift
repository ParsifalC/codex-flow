import SwiftUI

public struct HistoryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false

    @State private var availableProjects: [String] = []
    @State private var detailRun: TaskRun?
    @State private var detailHoverGeneration = 0
    @State private var searchGeneration = 0

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            historySurface
            detailOverlay
        }
        .onAppear(perform: loadInitialHistory)
    }

    private var historySurface: some View {
        VStack(spacing: 8) {
            filterBar
            if state.historyChats.isEmpty && state.historyRuns.isEmpty {
                emptyState
            } else {
                historyList
            }
        }
    }

    @ViewBuilder
    private var detailOverlay: some View {
        if let run = detailRun {
            HistoryTaskDetailOverlay(
                run: run,
                isPrivacyMode: state.isPrivacyMode,
                onClose: closeDetail
            )
            .frame(width: 350)
            .padding(.top, 34)
            .padding(.trailing, 2)
            .zIndex(20)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
            .onHover { inside in
                inside ? cancelScheduledClose() : scheduleDetailClose()
            }
        }
    }

    // MARK: - Filters

    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                scopeControls
                projectMenu
                Spacer()
                refreshButton
            }
            searchField
        }
        .padding(.top, 7)
    }

    private var scopeControls: some View {
        HStack(spacing: 2) {
            scopeButton(title: L("All", "全部"), selected: !state.isTodayOnly) {
                state.isTodayOnly = false
                state.loadHistory()
            }
            scopeButton(title: L("Today", "今天"), selected: state.isTodayOnly) {
                state.isTodayOnly = true
                state.loadHistory()
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder
    private var projectMenu: some View {
        if availableProjects.count > 2 {
            Menu {
                ForEach(availableProjects, id: \.self) { project in
                    Button(project == "All" ? L("All Projects", "全部项目") : project) {
                        state.selectedProject = project == "All" ? nil : project
                        state.loadHistory()
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "folder")
                        .font(.system(size: 8))
                        .foregroundColor(.cyan.opacity(0.85))
                    HoverRevealText(
                        state.selectedProject ?? L("All Projects", "全部项目"),
                        font: .system(size: 8.5, weight: .medium),
                        foregroundColor: .white.opacity(0.72),
                        lineLimit: 1,
                        privacyBlur: state.isPrivacyMode && state.selectedProject != nil,
                        popoverWidth: 320
                    )
                    .frame(maxWidth: 118, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.05)))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var refreshButton: some View {
        Button {
            state.loadHistory()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.white.opacity(0.05)))
        }
        .buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.4))

            TextField(L("Search chat or session…", "搜索对话或任务…"), text: $state.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 9.2))
                .foregroundColor(.white)
                .onChange(of: state.searchQuery) { _, _ in scheduleSearchReload() }

            if !state.searchQuery.isEmpty {
                Button {
                    state.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.white.opacity(0.035))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.075), lineWidth: 0.6))
        )
    }

    private func scopeButton(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8.2, weight: selected ? .bold : .medium, design: .rounded))
                .foregroundColor(selected ? .white : .white.opacity(0.46))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(selected ? Color.cyan.opacity(0.28) : Color.clear))
        }
        .buttonStyle(.plain)
    }

    // MARK: - History List

    private var historyList: some View {
        Group {
            if isFullHeight {
                historyContent
            } else {
                ScrollView(.vertical, showsIndicators: true) { historyContent }
                    .frame(maxHeight: 355)
            }
        }
    }

    private var historyContent: some View {
        LazyVStack(spacing: 7) {
            if !state.historyChats.isEmpty {
                ForEach(Array(state.historyChats.enumerated()), id: \.element.id) { index, chat in
                    HistoryChatRow(
                        index: index + 1,
                        chat: chat,
                        expanded: state.isChatExpanded(chat.sessionId),
                        selectedRunId: detailRun?.id,
                        isPrivacyMode: state.isPrivacyMode,
                        onToggle: { state.toggleChatExpansion(chat.sessionId) },
                        onSelectRun: showDetail
                    )
                }
            } else {
                ForEach(Array(state.historyRuns.enumerated()), id: \.element.id) { index, run in
                    HistoryStandaloneRunRow(
                        index: index + 1,
                        run: run,
                        selected: detailRun?.id == run.id,
                        isPrivacyMode: state.isPrivacyMode,
                        onSelect: { showDetail(run) }
                    )
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: state.searchQuery.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 23))
                .foregroundColor(.white.opacity(0.28))
                .padding(.top, 28)

            Text(state.searchQuery.isEmpty ? L("No telemetry history yet", "尚无遥测历史") : L("No matching tasks", "没有匹配的任务"))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.72))

            if !state.searchQuery.isEmpty {
                Button(L("Clear Search", "清除搜索")) { state.searchQuery = "" }
                    .buttonStyle(.plain)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.cyan)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230)
    }

    // MARK: - Local task detail overlay

    private func showDetail(_ run: TaskRun) {
        cancelScheduledClose()
        withAnimation(.easeOut(duration: 0.15)) { detailRun = run }

        if run.trajectory == nil || run.skillsUsed == nil || run.toolsUsed == nil || run.logs == nil {
            var enriched = run
            DispatchQueue.global(qos: .userInitiated).async {
                TelemetryQueryEngine.shared.enrichRunIfNeeded(&enriched)
                DispatchQueue.main.async {
                    guard detailRun?.id == enriched.id else { return }
                    detailRun = enriched
                }
            }
        }
    }

    private func loadInitialHistory() {
        availableProjects = ["All"] + TelemetryQueryEngine.shared.allProjects()
        if state.historyChats.isEmpty && state.historyRuns.isEmpty { state.loadHistory() }
    }

    private func closeDetail() {
        cancelScheduledClose()
        withAnimation(.easeIn(duration: 0.12)) { detailRun = nil }
    }

    private func cancelScheduledClose() { detailHoverGeneration += 1 }

    private func scheduleDetailClose() {
        detailHoverGeneration += 1
        let generation = detailHoverGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard generation == detailHoverGeneration else { return }
            withAnimation(.easeIn(duration: 0.12)) { detailRun = nil }
        }
    }

    private func scheduleSearchReload() {
        searchGeneration += 1
        let generation = searchGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard generation == searchGeneration else { return }
            state.loadHistory()
        }
    }
}

// MARK: - Chat accordion

public struct HistoryChatRow: View {
    public let index: Int
    public let chat: ChatSession
    public let expanded: Bool
    public let selectedRunId: String?
    public let isPrivacyMode: Bool
    public let onToggle: () -> Void
    public let onSelectRun: (TaskRun) -> Void

    @State private var hovered = false

    public var body: some View {
        VStack(spacing: 0) {
            headerButton
            if expanded { expandedTurns }
        }
        .background(rowBackground)
        .overlay(rowBorder)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var headerButton: some View {
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 7) {
                indexColumn
                chatSummary
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var indexColumn: some View {
        VStack(spacing: 4) {
            Text("#\(index)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(index == 1 ? .cyan : .white.opacity(0.45))
            Image(systemName: "chevron.right")
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
                .rotationEffect(.degrees(expanded ? 90 : 0))
        }
        .frame(width: 25)
    }

    private var chatSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            projectRow
            HoverRevealText(
                chat.title,
                font: .system(size: 9.3),
                foregroundColor: .white.opacity(0.78),
                lineLimit: 1,
                privacyBlur: isPrivacyMode,
                popoverWidth: 400
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            metadataRow
        }
    }

    private var projectRow: some View {
        HStack(spacing: 4) {
            HoverRevealText(
                chat.projectName,
                font: .system(size: 9.8, weight: .bold, design: .rounded),
                foregroundColor: .white.opacity(0.92),
                lineLimit: 1,
                privacyBlur: isPrivacyMode,
                popoverWidth: 300
            )

            if let branch = chat.gitBranch, !branch.isEmpty {
                HoverRevealText(
                    "(\(branch))",
                    font: .system(size: 8, weight: .medium, design: .monospaced),
                    foregroundColor: .cyan.opacity(0.78),
                    lineLimit: 1,
                    privacyBlur: isPrivacyMode,
                    popoverWidth: 300
                )
            }

            Spacer(minLength: 4)
            Text(chat.localizedFormattedDate)
                .font(.system(size: 7.8))
                .foregroundColor(.white.opacity(0.38))
        }
    }

    private var metadataRow: some View {
        HStack(spacing: 6) {
            Label(chat.localizedRunsSummary, systemImage: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 7.8, weight: .semibold))
                .foregroundColor(.cyan.opacity(0.8))

            Text(chat.formattedDuration)
                .font(.system(size: 7.8, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))

            workerCount
            Spacer()
            quotaDelta

            Text(chat.formattedTotalTokens)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))

            Circle()
                .fill(statusColor)
                .frame(width: 4.5, height: 4.5)
        }
    }

    @ViewBuilder
    private var workerCount: some View {
        if chat.maxWorkerCount > 0 {
            Label("\(chat.maxWorkerCount)w", systemImage: "person.2.fill")
                .font(.system(size: 7.6, weight: .medium))
                .foregroundColor(.teal.opacity(0.8))
        }
    }

    @ViewBuilder
    private var quotaDelta: some View {
        if let delta = chat.totalQuotaDelta, abs(delta) >= 0.1 {
            let formatted = abs(delta) < 0.95
                ? String(format: "%+.1f%%", -delta)
                : String(format: "%+.0f%%", -delta)
            let deltaMagnitude = abs(delta) < 0.95
                ? String(format: "%.1f%%", abs(delta))
                : String(format: "%.0f%%", abs(delta))
            Text(formatted)
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(delta > 0 ? .orange : .green)
                .help(delta > 0
                    ? String(format: L("Quota consumed: %@", "配额消耗：%@"), deltaMagnitude)
                    : String(format: L("Quota restored: %@", "配额恢复：%@"), deltaMagnitude)
                )
        }
    }

    private var statusColor: Color {
        if chat.isRunning { return .cyan }
        if chat.isError { return .orange }
        return .green
    }

    private var expandedTurns: some View {
        VStack(spacing: 0) {
            Divider().background(Color.white.opacity(0.07))
            VStack(spacing: 3) {
                turnsHeader
                turnsList
            }
            .padding(.horizontal, 5)
            .padding(.bottom, 5)
            .background(Color.black.opacity(0.16))
        }
    }

    private var turnsHeader: some View {
        HStack {
            Text(L("Session Turns", "执行轮次"))
                .font(.system(size: 7.8, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.42))
            Spacer()
            if let latest = chat.latestRun {
                Button { onSelectRun(latest) } label: {
                    Label(L("Details", "详情"), systemImage: "rectangle.inset.filled.and.person.filled")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundColor(.cyan)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 5)
    }

    private var turnsList: some View {
        ForEach(Array(chat.runs.enumerated()), id: \.element.id) { offset, run in
            HistoryRunRow(
                turnNumber: chat.runs.count - offset,
                run: run,
                selected: selectedRunId == run.id,
                isPrivacyMode: isPrivacyMode,
                onSelect: { onSelectRun(run) }
            )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(hovered ? Color.white.opacity(0.055) : Color.white.opacity(0.03))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 9)
            .stroke(expanded ? Color.cyan.opacity(0.22) : Color.white.opacity(hovered ? 0.12 : 0.065), lineWidth: 0.7)
    }
}

public struct HistoryRunRow: View {
    public let turnNumber: Int
    public let run: TaskRun
    public let selected: Bool
    public let isPrivacyMode: Bool
    public let onSelect: () -> Void

    @State private var hovered = false

    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                selectionBar
                turnLabel
                runSummary
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 4)
            .background(rowBackground)
            .overlay(rowBorder)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var selectionBar: some View {
        Capsule()
            .fill(selected ? Color.cyan : Color.white.opacity(hovered ? 0.35 : 0.12))
            .frame(width: 2.5, height: 24)
    }

    private var turnLabel: some View {
        Text("#\(turnNumber)")
            .font(.system(size: 7.8, weight: .bold, design: .monospaced))
            .foregroundColor(selected ? .cyan : .white.opacity(0.45))
            .frame(width: 22, alignment: .leading)
    }

    private var runSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            runMetadata
            let preview = run.turnPreview
            if !preview.isEmpty {
                HoverRevealText(
                    preview,
                    font: .system(size: 8.2),
                    foregroundColor: .white.opacity(0.6),
                    lineLimit: 1,
                    privacyBlur: isPrivacyMode,
                    popoverWidth: 400
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var runMetadata: some View {
        HStack(spacing: 4) {
            Text(run.localizedFormattedDate)
                .font(.system(size: 7.4))
                .foregroundColor(.white.opacity(0.38))
            Text("·").foregroundColor(.white.opacity(0.2))
            Text(run.formattedDuration)
                .font(.system(size: 7.4, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            if !run.allWorkers.isEmpty {
                Text("\(run.allWorkers.count)w")
                    .font(.system(size: 7.2, weight: .semibold))
                    .foregroundColor(.teal.opacity(0.8))
            }
            quotaDelta
            Text(run.formattedTotalTokens)
                .font(.system(size: 7.8, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
        }
    }

    @ViewBuilder
    private var quotaDelta: some View {
        let deltaValue = run.canonicalQuotaDelta ?? run.shortWindowQuotaDelta ?? run.effectiveQuotaWindows.first(where: { $0.deltaPercentagePoints != nil })?.deltaPercentagePoints
        if let delta = deltaValue, abs(delta) >= 0.1 {
            let formatted = abs(delta) < 0.95
                ? String(format: "%+.1f%%", -delta)
                : String(format: "%+.0f%%", -delta)
            let deltaMagnitude = abs(delta) < 0.95
                ? String(format: "%.1f%%", abs(delta))
                : String(format: "%.0f%%", abs(delta))
            Text(formatted)
                .font(.system(size: 7.2, weight: .bold))
                .foregroundColor(delta > 0 ? .orange : .green)
                .help(delta > 0
                    ? String(format: L("Quota consumed: %@", "配额消耗：%@"), deltaMagnitude)
                    : String(format: L("Quota restored: %@", "配额恢复：%@"), deltaMagnitude)
                )
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(selected ? Color.cyan.opacity(0.14) : (hovered ? Color.white.opacity(0.06) : Color.white.opacity(0.018)))
    }

    private var rowBorder: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? Color.cyan.opacity(0.42) : Color.clear, lineWidth: 0.7)
    }
}

public struct HistoryStandaloneRunRow: View {
    public let index: Int
    public let run: TaskRun
    public let selected: Bool
    public let isPrivacyMode: Bool
    public let onSelect: () -> Void

    public var body: some View {
        HistoryRunRow(
            turnNumber: index,
            run: run,
            selected: selected,
            isPrivacyMode: isPrivacyMode,
            onSelect: onSelect
        )
    }
}

// MARK: - History-local detail surface

public struct HistoryTaskDetailOverlay: View {
    public let run: TaskRun
    public let isPrivacyMode: Bool
    public let onClose: () -> Void
    @State private var executionExpanded = false
    @State private var logsExpanded = false

    public var body: some View {
        VStack(spacing: 7) {
            detailTitleBar
            detailScroll
        }
        .padding(9)
        .background(detailBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color.cyan.opacity(0.28), lineWidth: 0.8)
        )
        .onChange(of: run.id) { _, _ in
            executionExpanded = false
            logsExpanded = false
        }
    }

    private var detailTitleBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "rectangle.inset.filled.and.person.filled")
                .font(.system(size: 9))
                .foregroundColor(.cyan)
            Text(L("Task Detail", "任务详情"))
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Text(run.localizedFormattedDate)
                .font(.system(size: 7.4))
                .foregroundColor(.white.opacity(0.38))
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.48))
            }
            .buttonStyle(.plain)
            .help(L("Close", "关闭"))
        }
    }

    private var detailScroll: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 7) {
                detailHeader
                detailMetrics
                quotaSection
                detailNarrative
                TokenUsageBreakdownView(usage: run.aggregatedUsage)
                skillsSection
                detailWorkers
                stepsSection
                logsSection
            }
        }
        .frame(maxHeight: 360)
    }

    @ViewBuilder
    private var quotaSection: some View {
        if !run.effectiveQuotaWindows.isEmpty {
            let isPending = run.isRunning && (run.quotaAfter ?? []).isEmpty
            QuotaWindowsView(windows: run.effectiveQuotaWindows, isRunning: isPending)
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        if run.hasSkillsOrTools { InspectorSkillsToolsView(run: run) }
    }

    @ViewBuilder
    private var stepsSection: some View {
        if let steps = run.trajectory, !steps.isEmpty { detailSteps(steps) }
    }

    @ViewBuilder
    private var logsSection: some View {
        if let logs = run.logs, !logs.isEmpty { detailLogs(logs) }
    }

    private var detailBackground: some View {
        RoundedRectangle(cornerRadius: 13)
            .fill(Color(red: 0.045, green: 0.052, blue: 0.073).opacity(0.985))
            .shadow(color: .black.opacity(0.55), radius: 16, y: 7)
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                HoverRevealText(
                    run.projectName,
                    font: .system(size: 9.6, weight: .bold, design: .rounded),
                    foregroundColor: .white.opacity(0.9),
                    lineLimit: 1,
                    privacyBlur: isPrivacyMode,
                    popoverWidth: 300
                )
                if let branch = run.gitBranch, !branch.isEmpty {
                    HoverRevealText(
                        "(\(branch))",
                        font: .system(size: 7.8, design: .monospaced),
                        foregroundColor: .cyan.opacity(0.75),
                        lineLimit: 1,
                        privacyBlur: isPrivacyMode,
                        popoverWidth: 300
                    )
                }
                Spacer()
            }

            HoverRevealText(
                run.turnPreview,
                font: .system(size: 8.7),
                foregroundColor: .white.opacity(0.62),
                lineLimit: 2,
                privacyBlur: isPrivacyMode,
                popoverWidth: 390
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .background(detailCard)
    }

    private var detailMetrics: some View {
        HStack(spacing: 5) {
            miniMetric(L("Time", "耗时"), run.formattedDuration, .cyan)
            miniMetric(L("Tokens", "Token"), run.formattedTotalTokens, Color(red: 0.95, green: 0.35, blue: 0.8))
            miniMetric(L("Output", "输出"), TaskRun.formatTokenCount(run.aggregatedUsage.effectiveOutputTokens), .green)
        }
    }

    private func miniMetric(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 7.2, weight: .semibold))
                .foregroundColor(.white.opacity(0.42))
            Text(value)
                .font(.system(size: 9.2, weight: .bold, design: .rounded))
                .foregroundColor(tint)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(detailCard)
    }

    private var detailNarrative: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let goal = run.effectiveGoal, !goal.isEmpty {
                detailTextBlock(L("Objective", "目标"), goal, .cyan, 3)
            }
            if let conclusion = run.effectiveConclusion, !conclusion.isEmpty {
                detailTextBlock(L("Outcome", "结论"), conclusion, .green, 4)
            }
        }
    }

    private func detailTextBlock(_ title: String, _ text: String, _ tint: Color, _ lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 7.6, weight: .bold))
                .foregroundColor(tint.opacity(0.85))
            HoverRevealText(
                text,
                font: .system(size: 8.5),
                foregroundColor: .white.opacity(0.75),
                lineLimit: lines,
                privacyBlur: isPrivacyMode,
                popoverWidth: 390
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .background(detailCard)
    }

    private var detailWorkers: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(L("Participants", "参与 Agent"))
                    .font(.system(size: 7.7, weight: .bold))
                    .foregroundColor(.white.opacity(0.48))
                Spacer()
                Text(L("\(run.allWorkers.count) workers", "\(run.allWorkers.count) 个 Worker"))
                    .font(.system(size: 7.3))
                    .foregroundColor(.teal.opacity(0.7))
            }

            HStack(spacing: 3) {
                Text(L("Parent", "父 Agent"))
                    .font(.system(size: 7.4, weight: .semibold))
                    .foregroundColor(.indigo)
                HoverRevealText(
                    run.parent?.displayModel ?? "unknown",
                    font: .system(size: 7.6, weight: .medium, design: .monospaced),
                    foregroundColor: .white.opacity(0.7),
                    lineLimit: 1,
                    popoverWidth: 300
                )
                if let effort = run.parent?.displayEffort {
                    Text(effort)
                        .font(.system(size: 6.8, weight: .medium, design: .monospaced))
                        .foregroundColor(.indigo.opacity(0.9))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.indigo.opacity(0.15)))
                }
                Spacer()
                if let tokens = run.parent?.effectiveUsage?.totalTokens, tokens > 0 {
                    Text(TaskRun.formatTokenCount(tokens))
                        .font(.system(size: 7.3, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            ForEach(run.allWorkers.prefix(4)) { worker in
                HStack(spacing: 3) {
                    Text(L("Worker", "Worker"))
                        .font(.system(size: 7.4, weight: .semibold))
                        .foregroundColor(.teal)
                    HoverRevealText(
                        worker.name ?? worker.displayModel,
                        font: .system(size: 7.6),
                        foregroundColor: .white.opacity(0.68),
                        lineLimit: 1,
                        popoverWidth: 320
                    )
                    if let effort = worker.displayEffort {
                        Text(effort)
                            .font(.system(size: 6.8, weight: .medium, design: .monospaced))
                            .foregroundColor(.teal.opacity(0.9))
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.teal.opacity(0.15)))
                    }
                    Spacer()
                    Text(TaskRun.formatTokenCount(worker.effectiveUsage?.totalTokens ?? 0))
                        .font(.system(size: 7.3, design: .monospaced))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
        .padding(7)
        .background(detailCard)
    }

    private func detailSteps(_ steps: [TrajectoryStep]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    executionExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "point.filled.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 7.5))
                        .foregroundColor(.indigo)
                    Text(L("Execution", "执行轨迹"))
                        .font(.system(size: 7.7, weight: .bold))
                        .foregroundColor(.white.opacity(0.48))
                    Spacer()
                    Text(L("\(steps.count) steps", "\(steps.count) 步"))
                        .font(.system(size: 7.1, weight: .medium))
                        .foregroundColor(.white.opacity(0.32))
                    Image(systemName: executionExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.32))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if executionExpanded {
                ForEach(Array(steps.prefix(5))) { step in
                    HStack(alignment: .top, spacing: 4) {
                        Circle()
                            .fill(step.status == "error" ? Color.orange : Color.cyan)
                            .frame(width: 4, height: 4)
                            .padding(.top, 4)
                        HoverRevealText(
                            [step.title, step.detail].compactMap { $0 }.joined(separator: " — "),
                            font: .system(size: 7.6),
                            foregroundColor: .white.opacity(0.6),
                            lineLimit: 1,
                            privacyBlur: isPrivacyMode,
                            popoverWidth: 400
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(7)
        .background(detailCard)
    }

    private func detailLogs(_ logs: [TaskLogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    logsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 7.5))
                        .foregroundColor(.green)
                    Text(L("Recent logs", "最近日志"))
                        .font(.system(size: 7.7, weight: .bold))
                        .foregroundColor(.white.opacity(0.48))
                    Spacer()
                    Text(L("\(logs.count) entries", "\(logs.count) 条"))
                        .font(.system(size: 7.1, weight: .medium))
                        .foregroundColor(.white.opacity(0.32))
                    Image(systemName: logsExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(.white.opacity(0.32))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if logsExpanded {
                ForEach(Array(logs.suffix(4))) { entry in
                    HStack(alignment: .top, spacing: 4) {
                        Circle()
                            .fill(entry.level == "error" ? Color.orange : Color.green)
                            .frame(width: 4, height: 4)
                            .padding(.top, 4)
                        HoverRevealText(
                            entry.message ?? "",
                            font: .system(size: 7.4, design: .monospaced),
                            foregroundColor: entry.level == "error" ? .orange.opacity(0.82) : .white.opacity(0.58),
                            lineLimit: 2,
                            privacyBlur: isPrivacyMode,
                            popoverWidth: 410
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(7)
        .background(detailCard)
    }

    private var detailCard: some View {
        RoundedRectangle(cornerRadius: 7)
            .fill(Color.white.opacity(0.035))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.065), lineWidth: 0.6))
    }
}
