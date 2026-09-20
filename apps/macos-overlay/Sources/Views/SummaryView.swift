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
        return L("Conversation: ", "会话：") + (currentRun?.thread?.name ?? L("Untitled conversation", "未命名会话"))
    }
    private var currentRun: TaskRun? { state.notificationRun ?? state.inspectedRun ?? state.latestRun }
    public var body: some View {
        VStack(spacing: 0) {
            chrome
            tabs
            projectPicker
            Divider().overlay(Color.white.opacity(0.05))
            Group {
                switch state.activeTab {
                case .inspector: inspector
                case .history: HistoryView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 16)
                case .analytics: AnalyticsView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 16)
                case .account: AccountView(state: state, isFullHeight: isFullHeight).padding(.horizontal, 16)
                }
            }
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
        .popover(isPresented: $showUpdate, arrowEdge: .top) { FlowPilotUpdateView() }
        .alert(L("Language change failed", "语言切换失败"), isPresented: Binding(
            get: { languageError != nil }, set: { if !$0 { languageError = nil } }
        )) {
            Button(L("OK", "好")) { languageError = nil }
        } message: { Text(languageError ?? "") }
    }
    private var chrome: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17)).foregroundStyle(.cyan.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(.cyan.opacity(0.12)))
            Text("FlowPilot").font(.system(size: 17, weight: .semibold, design: .rounded))
            Spacer()
            if state.isPrivacyMode {
                Image(systemName: "eye.slash.fill").font(.system(size: 12)).foregroundStyle(.cyan)
                    .help(L("Privacy mode is on", "隐私模式已开启"))
                    .accessibilityLabel(L("Privacy mode is on", "隐私模式已开启"))
            }
            chromeButton(state.isPinned ? "pin.fill" : "pin", L("Pin window", "置顶悬浮窗"), tint: state.isPinned ? .cyan : .white.opacity(0.6)) { state.isPinned.toggle() }
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
        }.padding(.horizontal, 17).padding(.vertical, 13)
    }
    private func chromeButton(_ icon: String, _ label: String, tint: Color = .white.opacity(0.6), action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 14)).foregroundStyle(tint).frame(width: 32, height: 32) }
            .buttonStyle(.plain).help(label).accessibilityLabel(label)
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
        HStack(spacing: 4) {
            tab(L("Task", "任务"), selected: state.activeTab == .inspector) { state.selectTab(.inspector) }
            tab(L("History", "历史"), selected: state.activeTab == .history) { state.selectTab(.history) }
            tab(L("Statistics", "统计"), selected: state.activeTab == .analytics) { state.selectTab(.analytics) }
            tab(L("Account", "账户"), selected: state.activeTab == .account) { state.selectTab(.account) }
        }.padding(4).background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.18))).padding(.horizontal, 16)
    }
    private func tab(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: selected ? .semibold : .regular))
                .foregroundStyle(.white.opacity(selected ? 0.95 : 0.72)).frame(maxWidth: .infinity).padding(.vertical, 10)
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
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text(conversationTitle).help(conversationTitle)
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72)).lineLimit(1)
                }
                Spacer()
                Label(L("Switch", "切换"), systemImage: "chevron.down").font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
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
                Button(L("Latest completed turn", "最近完成轮次") + " · " + (state.isPrivacyMode ? L("Hidden project", "项目已隐藏") : latest.projectName)) { state.jumpToLive(); showPicker = false }
            }
            ForEach(state.recentChats) { chat in
                Section(state.isPrivacyMode ? L("Chat", "对话") : chat.projectName + " · " + chat.title) {
                    ForEach(chat.runs.prefix(12)) { run in
                        Button(state.isPrivacyMode ? L("Completed turn", "已完成轮次") : run.localizedFormattedDate + " · " + String(run.turnPreview.prefix(40))) { state.inspect(run: run); showPicker = false }
                    }
                }
            }
            Divider()
            Button(L("Browse all history", "浏览全部历史")) { state.selectTab(.history); showPicker = false }

                }.buttonStyle(.plain).font(.system(size: 14)).padding(18)
            }.frame(width: 380, height: 400)
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
                    }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                    TurnDetailView(run: run, isPrivacyMode: state.isPrivacyMode)
                        .simultaneousGesture(TapGesture().onEnded { state.markResultViewed(run) })
                    HStack {
                        Button { state.selectTab(.history) } label: { Label(L("History", "查看历史"), systemImage: "clock.arrow.circlepath") }
                        Spacer()
                        Button { copySummary() } label: { Label(copied ? L("Copied", "已复制") : L("Copy", "复制摘要"), systemImage: copied ? "checkmark" : "doc.on.doc") }.disabled(state.isPrivacyMode)
                    }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                }.padding(16)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tray").font(.system(size: 27)).foregroundStyle(.cyan.opacity(0.6))
                    Text(L("No completed turns yet", "尚无已完成轮次")).font(.system(size: 17, weight: .medium))
                    Text(L("The goal and result appear here when a turn finishes.", "完成一轮后，目标与结果将在这里呈现。"))
                        .font(.system(size: 14)).foregroundStyle(.white.opacity(0.72)).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity).padding(.vertical, 55).padding(.horizontal, 20)
            }
        }.frame(maxHeight: isFullHeight ? .infinity : 400)
    }
    private func copySummary() {
        guard let run = currentRun, !state.isPrivacyMode else { return }
        let goalLabel = run.isLegacyGoalFallback ? L("Goal (legacy): ", "本轮目标（历史兼容）：") : L("Goal: ", "本轮目标：")
        let resultLabel = run.isLegacyConclusionFallback ? L("Result (legacy): ", "结果（历史兼容）：") : L("Result: ", "结果：")
        let text = "\(run.projectName) / \(run.sessionId ?? "—") / \(run.turnId ?? "—")\n\n" + goalLabel + localizedResultText(run.publishedGoal) + "\n\n" + resultLabel + localizedResultText(run.publishedConclusion)
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
