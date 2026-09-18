import SwiftUI
import AppKit

/// Native counterpart of the approved four-tab overlay preview.
public struct SummaryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var updateService = FlowPilotUpdateService.shared
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    public var isFullHeight: Bool = false
    @State private var showingAccount = false
    @State private var copied = false
    @State private var showUpdate = false
    @State private var showPicker = false
    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state; self.isFullHeight = isFullHeight
    }
    private var currentRun: TaskRun? { state.inspectedRun ?? state.latestRun }
    public var body: some View {
        VStack(spacing: 0) {
            chrome
            tabs
            projectPicker
            Divider().overlay(Color.white.opacity(0.05))
            Group {
                if showingAccount {
                    AccountView(state: state, isFullHeight: isFullHeight)
                        .padding(.horizontal, 16)
                } else {
                    switch state.activeTab {
                    case .inspector: inspector
                    case .history: HistoryView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 16)
                    case .analytics: AnalyticsView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 16)
                    }
                }
            }
            footer
        }
        .foregroundStyle(.white.opacity(0.9))
        .background {
            if reduceTransparency { Color(red: 0.08, green: 0.10, blue: 0.13) }
            else {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                LinearGradient(colors: [Color(red: 0.11, green: 0.16, blue: 0.20).opacity(0.78), Color(red: 0.055, green: 0.065, blue: 0.09).opacity(0.88)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.white.opacity(0.16), lineWidth: 0.8))
        .environment(\.colorScheme, .dark)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .onChange(of: state.activeTab) { _, _ in showingAccount = false }
        .popover(isPresented: $showUpdate, arrowEdge: .top) { FlowPilotUpdateView() }
    }
    private var chrome: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 15)).foregroundStyle(.cyan.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(.cyan.opacity(0.12)))
            Text("FlowPilot").font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            chromeButton(state.isPinned ? "pin.fill" : "pin", L("Pin window", "置顶悬浮窗"), tint: state.isPinned ? .cyan : .white.opacity(0.6)) { state.isPinned.toggle() }
            chromeButton("chevron.down", L("Collapse", "收起悬浮窗")) { state.collapse() }
            Menu {
                Button { state.isPrivacyMode.toggle() } label: {
                    Label(state.isPrivacyMode ? L("Disable privacy mode", "关闭隐私模式") : L("Enable privacy mode", "开启隐私模式"), systemImage: "eye.slash")
                }
                Button { showUpdate = true } label: { Label(L("Software update", "检查软件更新"), systemImage: "arrow.down.circle") }
                Button { NSWorkspace.shared.open(URL(string: "https://github.com/ParsifalC/codex-flow")!) } label: { Label("GitHub", systemImage: "arrow.up.right.square") }
                Button { openConsole() } label: { Label(L("Open console", "打开控制台"), systemImage: "terminal") }
                Divider()
                Button { copySummary() } label: { Label(L("Copy this turn", "复制本轮摘要"), systemImage: "doc.on.doc") }
                    .disabled(currentRun == nil || state.isPrivacyMode)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) { if updateService.hasUpdateBadge { Circle().fill(.cyan).frame(width: 5, height: 5) } }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("More actions", "更多操作")).accessibilityLabel(L("More actions", "更多操作"))
        }.padding(.horizontal, 17).padding(.vertical, 13)
    }
    private func chromeButton(_ icon: String, _ label: String, tint: Color = .white.opacity(0.6), action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint).frame(width: 28, height: 28) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
    private var tabs: some View {
        HStack(spacing: 4) {
            tab(L("Task", "任务"), selected: !showingAccount && state.activeTab == .inspector) { showingAccount = false; state.selectTab(.inspector) }
            tab(L("History", "历史"), selected: !showingAccount && state.activeTab == .history) { showingAccount = false; state.selectTab(.history) }
            tab(L("Statistics", "统计"), selected: !showingAccount && state.activeTab == .analytics) { showingAccount = false; state.selectTab(.analytics) }
            tab(L("Account", "账户"), selected: showingAccount) { showingAccount = true }
        }.padding(4).background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.18))).padding(.horizontal, 16)
    }
    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.5)).frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selected ? 0.10 : 0)))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var projectPicker: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 16)).foregroundStyle(.cyan.opacity(0.7))
                    .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.04)))
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.isPrivacyMode ? L("Hidden project", "项目已隐藏") : currentRun?.projectName ?? L("No completed turns", "尚无已完成轮次"))
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(state.isPrivacyMode ? "•••" : currentRun?.thread?.name ?? currentRun?.sessionId.map { L("Chat", "对话") + " · " + String($0.prefix(12)) } ?? L("Waiting for a completed turn", "等待轮次完成"))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 11)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 18).padding(.vertical, 15)
        .accessibilityLabel(L("Switch completed turn", "切换已完成轮次"))
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(L("Switch completed turn", "切换已完成轮次")).font(.headline)

            if let latest = state.latestRun {
                Button(L("Latest completed turn", "最近完成轮次") + " · " + latest.projectName) { state.jumpToLive(); showPicker = false }
            }
            ForEach(state.recentChats) { chat in
                Section(state.isPrivacyMode ? L("Chat", "对话") : chat.projectName + " · " + chat.title) {
                    ForEach(chat.runs.prefix(12)) { run in
                        Button(state.isPrivacyMode ? L("Completed turn", "已完成轮次") : run.localizedFormattedDate + " · " + String(run.turnPreview.prefix(40))) { state.inspect(run: run); showingAccount = false; showPicker = false }
                    }
                }
            }
            Divider()
            Button(L("Browse all history", "浏览全部历史")) { showingAccount = false; state.selectTab(.history); showPicker = false }

                }.buttonStyle(.plain).font(.system(size: 12)).padding(18)
            }.frame(width: 345, height: 360)
        }
    }
    private var inspector: some View {
        ScrollView(.vertical) {
            if let run = currentRun {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(state.isPrivacyMode ? L("Completed turn", "已完成轮次") : L("Turn", "轮次") + " · " + String((run.turnId ?? "—").prefix(8)))
                        Spacer()
                        Text(run.localizedFormattedDate)
                    }.font(.system(size: 10)).foregroundStyle(.secondary)
                    TurnDetailView(run: run, isPrivacyMode: state.isPrivacyMode)
                    HStack {
                        Button { state.selectTab(.history) } label: { Label(L("History", "查看历史"), systemImage: "clock.arrow.circlepath") }
                        Spacer()
                        Button { copySummary() } label: { Label(copied ? L("Copied", "已复制") : L("Copy", "复制摘要"), systemImage: copied ? "checkmark" : "doc.on.doc") }.disabled(state.isPrivacyMode)
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                }.padding(16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 27)).foregroundStyle(.cyan.opacity(0.6))
                    Text(L("No completed turns yet", "尚无已完成轮次")).font(.system(size: 15, weight: .medium))
                    Text(L("The goal and result appear here when a turn finishes.", "完成一轮后，目标与结果将在这里呈现。"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 55).padding(.horizontal, 20)
            }
        }.frame(maxHeight: isFullHeight ? .infinity : 370)
    }
    private var footer: some View {
        HStack {
            Text("FlowPilot")
            Spacer()
            Text(state.isPrivacyMode ? L("Privacy mode", "隐私模式") : L("Completed turns", "已完成轮次"))
        }.font(.system(size: 10)).foregroundStyle(.white.opacity(0.3)).padding(.horizontal, 18).padding(.vertical, 11)
    }
    private func copySummary() {
        guard let run = currentRun, !state.isPrivacyMode else { return }
        let text = "\(run.projectName) / \(run.sessionId ?? "—") / \(run.turnId ?? "—")\n\n" + L("Goal: ", "本轮目标：") + localizedResultText(run.publishedGoal) + "\n\n" + L("Result: ", "结果：") + localizedResultText(run.publishedConclusion)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
    private func openConsole() {
        let script = "tell application \"Terminal\"\nactivate\ndo script \"codex-flow\"\nend tell"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
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
    public let isRunning: Bool

    public init(windows: [QuotaWindow], isRunning: Bool = false) {
        self.windows = windows
        self.isRunning = isRunning
    }

    private var ordered: [QuotaWindow] {
        windows.filter { $0.windowDurationMins != TaskRun.shortQuotaWindowMinutes }
            .sorted { ($0.windowDurationMins ?? Int.max) < ($1.windowDurationMins ?? Int.max) }
    }

    private var cardTitle: String {
        isRunning
            ? L("Quota remaining at task start", "任务起始额度剩余")
            : L("Quota remaining at task completion", "任务结束额度剩余")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(cardTitle, systemImage: "gauge.with.needle.fill")
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))

                Spacer()

                if isRunning {
                    HStack(spacing: 3) {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 4, height: 4)
                        Text(L("Running · Settles upon completion", "运行中 · 结束后结算消耗"))
                            .font(.system(size: 7.2, weight: .medium))
                            .foregroundColor(.cyan.opacity(0.85))
                    }
                }
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

                if let delta = window.deltaPercentagePoints, abs(delta) >= 0.1 {
                    let deltaText = abs(delta) < 0.95
                        ? String(format: "%.1f%%", abs(delta))
                        : String(format: "%.0f%%", abs(delta))
                    Text(delta > 0
                        ? String(format: L("(%@ used)", "(消耗 %@)"), deltaText)
                        : String(format: L("(%@ restored)", "(恢复 %@)"), deltaText)
                    )
                    .font(.system(size: 7.6, weight: .bold, design: .rounded))
                    .foregroundColor(delta > 0 ? .orange : .green)
                    .help(delta > 0
                        ? String(format: L("Quota consumed during this run: %@", "本轮任务配额消耗：%@"), deltaText)
                        : String(format: L("Quota restored during this run: %@", "本轮任务配额恢复：%@"), deltaText)
                    )
                }

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
    public let workerTokens: Int?
    public let parentTokens: Int?

    public init(usage: TokenUsage, workerTokens: Int? = nil, parentTokens: Int? = nil) {
        self.usage = usage
        self.workerTokens = workerTokens
        self.parentTokens = parentTokens
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
            HStack(spacing: 4) {
                Text(L("Token usage", "Token 用量"))
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                if let wTok = workerTokens, wTok > 0 {
                    let share = Double(wTok) / Double(max(1, reportedTotal)) * 100.0
                    Text(L("Worker: \(TaskRun.formatTokenCount(wTok)) (\(String(format: "%.1f%%", share)))", "Worker: \(TaskRun.formatTokenCount(wTok)) (\(String(format: "%.1f%%", share)))"))
                        .font(.system(size: 7.2, weight: .semibold, design: .rounded))
                        .foregroundColor(.teal.opacity(0.9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.teal.opacity(0.12)))
                }
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
