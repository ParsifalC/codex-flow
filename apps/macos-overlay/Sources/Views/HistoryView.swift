import SwiftUI

public struct HistoryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false
    @State private var searchGeneration = 0

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
    }

    public var body: some View {
        VStack(spacing: 12) {
            HistorySearchField(state: state, searchGeneration: $searchGeneration)
            HistoryHeader(state: state)
            HistoryList(state: state)
                .frame(maxHeight: .infinity)
        }
        .padding(.top, 16)
        .onAppear { state.loadHistory() }
    }
}

private struct HistoryHeader: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        HStack {
            Text(L("Turn history", "历史轮次"))
                .font(.system(size: 13, weight: .medium))
            Spacer()
            HistoryFilterButton(state: state, title: L("All", "全部"), today: false)
            HistoryFilterButton(state: state, title: L("Today", "今天"), today: true)
            Button { state.loadHistory() } label: {
                Image(systemName: "arrow.clockwise").frame(width: 32, height: 32)
            }
            .buttonStyle(OverlayButtonStyle())
            .help(L("Refresh history", "刷新历史"))
        }
    }
}

private struct HistoryFilterButton: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    let title: String
    let today: Bool

    var body: some View {
        Button {
            state.isTodayOnly = today
            state.loadHistory()
        } label: {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(state.isTodayOnly == today ? 0.12 : 0)))
        }
        .buttonStyle(OverlayButtonStyle())
    }
}

private struct HistorySearchField: View {
    @ObservedObject var state: OverlayState
    @Binding var searchGeneration: Int
    @ObservedObject private var localization = AppLocalization.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.white.opacity(0.72))
            TextField(
                L("Search project, chat or goal", "搜索项目、对话或目标"),
                text: $state.searchQuery
            )
            .textFieldStyle(.plain)
            .onChange(of: state.searchQuery) { _, _ in
                searchGeneration += 1
                let generation = searchGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if generation == searchGeneration {
                        state.loadHistory()
                    }
                }
            }
            if !state.searchQuery.isEmpty {
                Button { state.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(OverlayButtonStyle())
            }
        }
        .font(.system(size: 13))
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.055)))
    }
}

private struct HistoryList: View {
    @ObservedObject var state: OverlayState
    private var runs: [TaskRun] {
        state.historyRuns
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if runs.isEmpty {
                    Text(L("No completed turns found", "暂无符合条件的已完成轮次"))
                        .font(.system(size: 13)).foregroundStyle(OverlayTheme.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 45)
                }
                ForEach(runs) { run in
                    HistoryRunRow(state: state, run: run)
                    OverlayDivider()
                }
            }.padding(.bottom, 10)
        }
    }
}

private struct HistoryRunRow: View {
    @ObservedObject var state: OverlayState
    let run: TaskRun
    @State private var hovered = false

    var body: some View {
        Button { state.inspect(run: run) } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(state.isPrivacyMode ? L("Goal hidden", "目标已隐藏") : localizedResultText(run.publishedGoal))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(OverlayTheme.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        Text(run.isError ? L("Error", "异常") : L("Done", "完成"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(run.isError ? OverlayTheme.warning : OverlayTheme.good)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill((run.isError ? OverlayTheme.warning : OverlayTheme.good).opacity(0.10)))
                        Text(state.isPrivacyMode ? "•••" : run.projectName)
                            .lineLimit(1).truncationMode(.middle)
                        Text("· " + String((run.turnId ?? "—").prefix(6)))
                            .lineLimit(1).fixedSize()
                        if run.isLegacyGoalFallback {
                            Text(L("Legacy", "历史兼容"))
                                .font(.system(size: 10, weight: .medium))
                                .help(L("Goal recovered from the historical summary", "目标来自历史摘要兼容读取"))
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(OverlayTheme.muted)
                    Text(run.localizedFormattedDate)
                        .font(.system(size: 10.5)).foregroundStyle(OverlayTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 5) {
                    Text(run.formattedTotalTokens)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(OverlayTheme.secondary)
                    Text(run.formattedDuration)
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(OverlayTheme.muted)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10)).foregroundStyle(OverlayTheme.muted).opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 5).padding(.vertical, 14)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
        }
        .buttonStyle(OverlayButtonStyle())
        .onHover { hovered = $0 }
        .help(state.isPrivacyMode ? L("Open turn", "打开轮次") : (run.thread?.name ?? run.projectName) + " · " + (run.publishedGoal ?? ""))
    }
}
