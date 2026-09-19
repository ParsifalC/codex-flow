import SwiftUI

public struct HistoryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false
    @State private var searchGeneration = 0
    public init(state: OverlayState, isFullHeight: Bool = false) { self.state = state; self.isFullHeight = isFullHeight }
    private var projects: [String] {
        var seen = Set<String>()
        return state.historyChats.compactMap { chat in
            let key = chat.cwd ?? chat.projectName
            return seen.insert(key).inserted ? key : nil
        }
    }
    public var body: some View {
        VStack(spacing: 13) {
            HStack {
                Text(L("Turn history", "历史轮次")).font(.system(size: 16, weight: .semibold))
                Spacer()
                filter(L("All", "全部"), today: false)
                filter(L("Today", "今天"), today: true)
                Button { state.loadHistory() } label: { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).help(L("Refresh history", "刷新历史"))
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.72))
                TextField(L("Search project, chat or goal", "搜索项目、对话或目标"), text: $state.searchQuery).textFieldStyle(.plain)
                    .onChange(of: state.searchQuery) { _, _ in
                        searchGeneration += 1; let generation = searchGeneration
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if generation == searchGeneration { state.loadHistory() } }
                    }
                if !state.searchQuery.isEmpty {
                    Button { state.searchQuery = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
            }.font(.system(size: 14)).padding(10).background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.055)))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if state.historyChats.isEmpty {
                        Text(L("No completed turns found", "暂无符合条件的已完成轮次"))
                            .font(.system(size: 14)).foregroundStyle(.white.opacity(0.72)).frame(maxWidth: .infinity).padding(.vertical, 45)
                    }
                    ForEach(projects, id: \.self) { project in
                        let chats = state.historyChats.filter { ($0.cwd ?? $0.projectName) == project }
                        VStack(alignment: .leading, spacing: 9) {
                            Label(state.isPrivacyMode ? L("Project hidden", "项目已隐藏") : chats.first?.projectName ?? project, systemImage: "folder")
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.72))
                            ForEach(chats) { chat in
                                VStack(alignment: .leading, spacing: 0) {
                                    Button { state.toggleChatExpansion(chat.id) } label: {
                                        HStack {
                                            Image(systemName: state.isChatExpanded(chat.id) ? "chevron.down" : "chevron.right").font(.system(size: 9))
                                            Text(state.isPrivacyMode ? L("Chat hidden", "对话已隐藏") : chat.title).lineLimit(1)
                                            Spacer()
                                            Text("\(chat.runs.count)").foregroundStyle(.white.opacity(0.72))
                                        }.font(.system(size: 14, weight: .medium)).padding(14).contentShape(Rectangle())
                                    }.buttonStyle(.plain)
                                    if state.isChatExpanded(chat.id) {
                                        ForEach(chat.runs) { run in
                                            Button { state.inspect(run: run) } label: {
                                                VStack(alignment: .leading, spacing: 7) {
                                                    HStack {
                                                        Text(L("Turn", "轮次") + " · " + String((run.turnId ?? "—").prefix(8)))
                                                        Spacer(); Text(run.localizedFormattedDate)
                                                    }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                                                    Text(state.isPrivacyMode ? L("Goal hidden", "目标已隐藏") : localizedResultText(run.publishedGoal))
                                                        .font(.system(size: 14)).lineLimit(2).lineSpacing(5).frame(maxWidth: .infinity, alignment: .leading)
                                                    HStack {
                                                        Text(run.formattedDuration + " · " + run.formattedTotalTokens + " tokens")
                                                        Spacer(); Image(systemName: "arrow.up.right")
                                                    }.font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                                                }.padding(14).contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                            if run.id != chat.runs.last?.id { Divider().padding(.horizontal, 12) }
                                        }
                                    }
                                }.background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.04)))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.06)))
                            }
                        }
                    }
                }.padding(.bottom, 10)
            }.frame(maxHeight: isFullHeight ? .infinity : 305)
        }.padding(.top, 15).onAppear { state.loadHistory() }
    }
    private func filter(_ title: String, today: Bool) -> some View {
        Button { state.isTodayOnly = today; state.loadHistory() } label: {
            Text(title).font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(state.isTodayOnly == today ? 0.12 : 0)))
        }.buttonStyle(.plain)
    }
}
