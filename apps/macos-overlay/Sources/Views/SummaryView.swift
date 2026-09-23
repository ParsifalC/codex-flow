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
    @State private var copied = false
    @State private var showUpdate = false
    @State private var showPicker = false
    @State private var changingLanguage = false
    @State private var languageError: String?
    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state; self.isFullHeight = isFullHeight
    }
    private var conversationTitle: String {
        if state.isPrivacyMode { return L("Hidden conversation", "会话已隐藏") }
        return currentRun?.thread?.name ?? state.recentChats.first(where: { $0.sessionId == currentRun?.sessionId })?.title ?? L("Untitled conversation", "未命名会话")
    }
    private var currentRun: TaskRun? { state.selectedRun }
    public var body: some View {
        VStack(spacing: 0) {
            chrome
            tabs
            OverlayDivider()
            projectPicker
            OverlayDivider()
            Group {
                if state.activeTab == .inspector {
                    HStack {
                        Text(state.isInspectingHistory ? L("Viewing history", "正在查看历史") : L("Current task", "当前任务"))
                            .foregroundStyle(OverlayTheme.secondary)
                        Spacer()
                        if state.isInspectingHistory {
                            Button(L("Return to current task", "返回当前任务")) { state.jumpToLive() }
                                .foregroundStyle(OverlayTheme.accent)
                        }
                    }.font(.system(size: 12)).buttonStyle(.plain)
                        .padding(.horizontal, 20).padding(.vertical, 8)
                    inspector
                    turnFooter
                } else {
                    switch state.activeTab {
                    case .inspector: EmptyView()
                    case .history: HistoryView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 20)
                    case .analytics: AnalyticsView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 20)
                    case .account: AccountView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 20)
                    }
                }
            }
        }
        .foregroundStyle(OverlayTheme.primary)
        .frame(maxWidth: .infinity, maxHeight: isFullHeight ? nil : .infinity)
        .background {
            if reduceTransparency { Color(red: 0.08, green: 0.10, blue: 0.13) }
            else {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                LinearGradient(colors: [Color(red: 0.094, green: 0.106, blue: 0.133).opacity(0.86), Color(red: 0.063, green: 0.071, blue: 0.094).opacity(0.90)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 0.8))
        .environment(\.colorScheme, .dark)
        .transaction { if reduceMotion { $0.animation = nil; $0.disablesAnimations = true } }
        .popover(isPresented: $showUpdate, arrowEdge: .top) { FlowPilotUpdateView() }
        .alert(L("Language change failed", "语言切换失败"), isPresented: Binding(
            get: { languageError != nil }, set: { if !$0 { languageError = nil } }
        )) {
            Button(L("OK", "好")) { languageError = nil }
        } message: { Text(languageError ?? "") }
    }
    private var chrome: some View {
        HStack(spacing: 6) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17)).foregroundStyle(OverlayTheme.accent)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.08)))
                .overlay(alignment: .bottomTrailing) {
                    Circle().fill(state.currentTaskRun?.isRunning == true ? OverlayTheme.good : OverlayTheme.muted)
                        .frame(width: 6, height: 6)
                }
                .accessibilityLabel(state.currentTaskRun?.isRunning == true ? L("Running", "运行中") : L("Ready", "就绪"))
            Text("FlowPilot").font(.system(size: 16, weight: .semibold, design: .rounded))
            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/ParsifalC/codex-flow")!)
            } label: {
                Label("Star", systemImage: "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(OverlayTheme.warning)
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(Capsule().fill(OverlayTheme.warning.opacity(0.09)))
                    .contentShape(Rectangle())
            }
            .buttonStyle(OverlayButtonStyle(cornerRadius: 14))
            .help(L("Support FlowPilot with a Star on GitHub", "前往 GitHub，为 FlowPilot 点个 Star"))
            .accessibilityLabel("Star on GitHub")
            Spacer()
            if state.isPrivacyMode {
                Image(systemName: "eye.slash.fill").font(.system(size: 12)).foregroundStyle(.cyan)
                    .help(L("Privacy mode is on", "隐私模式已开启"))
                    .accessibilityLabel(L("Privacy mode is on", "隐私模式已开启"))
            }
            chromeButton(state.isPinned ? "pin.fill" : "pin", L("Pin window", "置顶悬浮窗"), tint: state.isPinned ? OverlayTheme.accent : OverlayTheme.secondary) { state.isPinned.toggle() }
            chromeButton("chevron.down", L("Collapse", "收起悬浮窗")) { state.collapse() }
            Menu {
                Menu {
                    languageOption("auto", L("Follow system", "跟随系统"))
                    languageOption("zh", "中文")
                    languageOption("en", "English")
                } label: { Label(L("Language", "语言"), systemImage: "globe") }
                    .disabled(changingLanguage)
                Divider()
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
                    .frame(width: 32, height: 32)
                    .overlay(alignment: .topTrailing) { if updateService.hasUpdateBadge { Circle().fill(.cyan).frame(width: 5, height: 5) } }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L("More actions", "更多操作")).accessibilityLabel(L("More actions", "更多操作"))
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
    }

    private func chromeButton(_ icon: String, _ label: String, tint: Color = .white.opacity(0.6), action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint).frame(width: 32, height: 32) }
            .buttonStyle(OverlayButtonStyle()).help(label).accessibilityLabel(label)
    }
    private func languageOption(_ value: String, _ title: String) -> some View {
        Button {
            changingLanguage = true
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try AppLocalization.setConfiguredLanguage(value)
                    DispatchQueue.main.async {
                        localization.refresh()
                        changingLanguage = false
                    }
                } catch {
                    let message = error.localizedDescription
                    DispatchQueue.main.async {
                        languageError = message
                        changingLanguage = false
                    }
                }
            }
        } label: {
            if AppLocalization.configuredLanguage() == value {
                Label(title, systemImage: "checkmark")
            } else { Text(title) }
        }
    }
    private var tabs: some View {
        HStack(spacing: 0) {
            tab(L("Task", "任务"), selected: state.activeTab == .inspector) { state.selectTab(.inspector) }
            tab(L("History", "历史"), selected: state.activeTab == .history) { state.selectTab(.history) }
            tab(L("Statistics", "统计"), selected: state.activeTab == .analytics) { state.selectTab(.analytics) }
            tab(L("Account", "账户"), selected: state.activeTab == .account) { state.selectTab(.account) }
        }
        .padding(.horizontal, 20)
        .onMoveCommand { direction in
            guard direction == .left || direction == .right,
                  let index = OverlayTab.allCases.firstIndex(of: state.activeTab) else { return }
            let count = OverlayTab.allCases.count
            state.selectTab(OverlayTab.allCases[(index + (direction == .right ? 1 : -1) + count) % count])
        }
    }
    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? OverlayTheme.primary : OverlayTheme.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? OverlayTheme.accent : .clear).frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(OverlayButtonStyle(cornerRadius: 0))
        .frame(maxWidth: .infinity)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var projectPicker: some View {
        Button { showPicker.toggle() } label: {
            HStack(spacing: 10) {
                Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.white.opacity(0.58))
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.isPrivacyMode ? L("Hidden project", "项目已隐藏") : currentRun?.projectName ?? L("No completed turns", "尚无已完成轮次"))
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced)).lineLimit(1)
                    Text(conversationTitle).help(conversationTitle)
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.52)).lineLimit(1)
                }
                Spacer()
                Label(L("Switch", "切换"), systemImage: "chevron.down").font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20).padding(.vertical, 12)
        .accessibilityLabel(L("Switch conversation or turn", "切换会话或轮次"))
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text(L("Switch conversation or turn", "切换会话或轮次")).font(.headline)

            if let latest = state.currentTaskRun {
                Button(L("Current task", "当前任务") + " · " + (state.isPrivacyMode ? L("Hidden project", "项目已隐藏") : latest.projectName)) { state.jumpToLive(); showPicker = false }
            }
            ForEach(state.recentChats) { chat in
                Section(state.isPrivacyMode ? L("Chat", "对话") : chat.projectName + " · " + chat.title) {
                    ForEach(chat.runs.prefix(12)) { run in
                        Button(state.isPrivacyMode ? L("Completed turn", "已完成轮次") : run.localizedFormattedDate + " · " + String(run.turnPreview.prefix(40))) { state.inspect(run: run); showPicker = false }
                    }
                }
            }
            OverlayDivider()
            Button(L("Browse all history", "浏览全部历史")) { state.selectTab(.history); showPicker = false }

                }.buttonStyle(.plain).font(.system(size: 14)).padding(18)
            }.frame(width: 380, height: 400)
        }
    }
    private var inspector: some View {
        ScrollView(.vertical) {
            if let run = currentRun {
                VStack(alignment: .leading, spacing: 14) {
                    if !state.isPrivacyMode,
                       let warning = state.analysisService?.errorMessage ?? state.analysisService?.commandErrorMessage ?? state.analysisSnapshot?.sourceError?.message {
                        Text(warning).font(.system(size: 11)).foregroundStyle(OverlayTheme.warning)
                    }
                    HStack {
                        Circle().fill(run.isRunning ? Color.yellow : (run.isError ? Color.red : Color.green)).frame(width: 5, height: 5)
                        Text(state.isPrivacyMode ? L("Completed turn", "已完成轮次") : L("Turn", "轮次") + " · " + String((run.turnId ?? "—").prefix(8)))
                        Spacer()
                        Text(run.localizedFormattedDate)
                    }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    TurnDetailView(run: run, isPrivacyMode: state.isPrivacyMode,
                        analysis: state.analysis(for: run), analysisService: state.analysisService)
                        .simultaneousGesture(TapGesture().onEnded { state.markResultViewed(run) })
                    HStack {
                        Button { state.selectTab(.history) } label: { Label(L("History", "查看历史"), systemImage: "clock.arrow.circlepath") }
                        Spacer()
                        Button { copySummary() } label: { Label(copied ? L("Copied", "已复制") : L("Copy", "复制摘要"), systemImage: copied ? "checkmark" : "doc.on.doc") }.disabled(state.isPrivacyMode)
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }.padding(.horizontal, 20).padding(.vertical, 16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 27)).foregroundStyle(.cyan.opacity(0.6))
                    Text(L("No completed turns yet", "尚无已完成轮次")).font(.system(size: 17, weight: .medium))
                    Text(L("The goal and result appear here when a turn finishes.", "完成一轮后，目标与结果将在这里呈现。"))
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 55).padding(.horizontal, 20)
            }
        }.frame(maxHeight: .infinity).id(currentRun?.id ?? "empty-inspector")
    }

    private var turnFooter: some View {
        let navigation = state.turnNavigation
        let count = navigation.runs.count
        let index = count == 0 ? 0 : (navigation.selectedIndex ?? 0) + 1
        return VStack(spacing: 0) {
            OverlayDivider()
            HStack {
                turnButton(
                    title: L("Previous turn", "上一轮"),
                    icon: "chevron.left",
                    disabled: !navigation.canMovePrevious
                ) { state.moveTurn(by: -1) }
                Spacer()
                Text(L("Turn \(index) / \(count)", "轮次 \(index) / \(count)"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.52))
                    .accessibilityLabel(L("Turn \(index) of \(count)", "第 \(index) / \(count) 轮"))
                Spacer()
                turnButton(
                    title: L("Next turn", "下一轮"),
                    icon: "chevron.right",
                    disabled: !navigation.canMoveNext
                ) { state.moveTurn(by: 1) }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private func turnButton(title: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if icon == "chevron.left" { Image(systemName: icon) }
                Text(title)
                if icon == "chevron.right" { Image(systemName: icon) }
            }
                .font(.system(size: 12))
                .foregroundStyle(disabled ? Color.white.opacity(0.22) : Color.white.opacity(0.62))
                .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .buttonStyle(OverlayButtonStyle())
        .disabled(disabled)
        .accessibilityLabel(title)
    }
    private func copySummary() {
        guard let run = currentRun, !state.isPrivacyMode else { return }
        let goalLabel = run.isLegacyGoalFallback ? L("Goal (legacy): ", "本轮目标（历史兼容）：") : L("Goal: ", "本轮目标：")
        let resultLabel = run.isLegacyConclusionFallback ? L("Result (legacy): ", "结果（历史兼容）：") : L("Result: ", "结果：")
        let analysis = state.analysis(for: run)
        let text = "\(run.projectName) / \(run.sessionId ?? "—") / \(run.turnId ?? "—")\n\n" + goalLabel + localizedResultText(analysis?.requirementText ?? run.publishedGoal) + "\n\n" + resultLabel + localizedResultText(analysis?.summaryText ?? run.publishedConclusion)
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
