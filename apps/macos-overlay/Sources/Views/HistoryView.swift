import SwiftUI

public struct HistoryView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    @State private var availableProjects: [String] = []
    
    public init(state: OverlayState) {
        self.state = state
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            // MARK: Filter & Search Bar
            filterBar
            
            // MARK: History Task List / Empty State
            if state.historyRuns.isEmpty {
                emptyState
            } else {
                taskList
            }
        }
        .onAppear {
            availableProjects = ["All"] + TelemetryQueryEngine.shared.allProjects()
            state.loadHistory()
        }
    }
    
    // MARK: - Filter Bar
    private var filterBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                // Scope selector (All / Today)
                HStack(spacing: 2) {
                    scopeButton(title: L("All", "全部"), isSelected: !state.isTodayOnly) {
                        state.isTodayOnly = false
                        state.loadHistory()
                    }
                    scopeButton(title: L("Today", "今天"), isSelected: state.isTodayOnly) {
                        state.isTodayOnly = true
                        state.loadHistory()
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.06)))
                
                // Project picker if multiple projects exist
                if availableProjects.count > 2 {
                    Menu {
                        ForEach(availableProjects, id: \.self) { proj in
                            Button(proj == "All" ? L("All", "全部") : proj) {
                                state.selectedProject = (proj == "All" ? nil : proj)
                                state.loadHistory()
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text(state.selectedProject ?? L("All Projects", "全部项目"))
                                .font(.system(size: 9.5, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 7.5))
                        }
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(0.07)))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                
                Spacer()
                
                // Task Count Badge
                Text(L("\(state.historyRuns.count) runs", "\(state.historyRuns.count) 次任务"))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
            
            // Search Input Box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.4))
                
                TextField(L("Search session, branch, or prompt...", "搜索会话、分支或提示词…"), text: $state.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 10.5))
                    .foregroundColor(.white)
                    .onChange(of: state.searchQuery) {
                        state.loadHistory()
                    }
                
                if !state.searchQuery.isEmpty {
                    Button {
                        state.searchQuery = ""
                        state.loadHistory()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
            )
        }
    }
    
    private func scopeButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9.5, weight: isSelected ? .bold : .medium, design: .rounded))
                .foregroundColor(isSelected ? .white : .white.opacity(0.55))
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(isSelected ? Color.cyan.opacity(0.3) : Color.white.opacity(0.001))
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Task List
    private var taskList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                ForEach(Array(state.historyRuns.enumerated()), id: \.element.id) { index, run in
                    HistoryItemRow(
                        index: index + 1,
                        run: run,
                        isSelected: state.inspectedRun?.id == run.id,
                        onSelect: {
                            state.inspect(run: run)
                        }
                    )
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 340)
    }
    
    // MARK: - Contextual Empty State
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: !state.searchQuery.isEmpty ? "magnifyingglass" : "tray")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.3))
                .padding(.top, 24)
            
            if !state.searchQuery.isEmpty {
                Text(L("No results for \"\(state.searchQuery)\"", "没有找到‘\(state.searchQuery)’的结果"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Button {
                    state.searchQuery = ""
                    state.loadHistory()
                } label: {
                    Text(L("Clear Search", "清除搜索"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if state.isTodayOnly {
                Text(L("No tasks recorded today", "今天还没有任务记录"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Button {
                    state.isTodayOnly = false
                    state.loadHistory()
                } label: {
                    Text(L("Show All Time", "查看全部时间"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if let p = state.selectedProject {
                Text(L("No runs for project \"\(p)\"", "项目‘\(p)’暂无任务"))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Button {
                    state.selectedProject = nil
                    state.loadHistory()
                } label: {
                    Text(L("Show All Projects", "查看全部项目"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                Text(L("No telemetry runs recorded yet", "尚未记录遥测任务"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Text(L("FlowPilot logs token and duration telemetry automatically.", "FlowPilot 会自动记录 Token 和耗时遥测。"))
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
}

// MARK: - Individual History Row
public struct HistoryItemRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    public var index: Int
    public var run: TaskRun
    public var isSelected: Bool
    public var onSelect: () -> Void
    
    @State private var isHovered: Bool = false
    
    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                indexBadge
                mainInfo
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(rowBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var indexBadge: some View {
        Text("#\(index)")
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
            .foregroundColor(index == 1 ? .cyan : .white.opacity(0.45))
            .frame(width: 24, alignment: .leading)
    }

    private var mainInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            headerRow

            Text(run.sessionTitle)
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.white.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            footerRow
        }
    }

    private var headerRow: some View {
        HStack(spacing: 4) {
            Text(run.projectName)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
                .lineLimit(1)

            if let branch = run.gitBranch, !branch.isEmpty {
                Text("(\(branch))")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.8))
                    .lineLimit(1)
            }

            Spacer()

            Text(run.localizedFormattedDate)
                .font(.system(size: 8.5, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var footerRow: some View {
        HStack(spacing: 6) {
            executionMode

            Text("·")
                .foregroundColor(.white.opacity(0.2))

            Text(run.formattedDuration)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))

            Spacer()

            Text(run.formattedTotalTokens)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))

            Circle()
                .fill(statusColor)
                .frame(width: 4.5, height: 4.5)
        }
    }

    @ViewBuilder
    private var executionMode: some View {
        let workerCount = run.allWorkers.count
        if workerCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 7.5))
                Text(L("\(workerCount) workers", "\(workerCount) 个 Worker"))
                    .font(.system(size: 8.5, weight: .medium))
            }
            .foregroundColor(.teal.opacity(0.85))
        } else {
            Text(L("Direct", "直接执行"))
                .font(.system(size: 8.5, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private var rowFillColor: Color {
        if isSelected { return Color.cyan.opacity(0.15) }
        if isHovered { return Color.white.opacity(0.07) }
        return Color.white.opacity(0.03)
    }

    private var rowStrokeColor: Color {
        if isSelected { return Color.cyan.opacity(0.4) }
        if isHovered { return Color.white.opacity(0.12) }
        return Color.white.opacity(0.05)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 9)
            .fill(rowFillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(rowStrokeColor, lineWidth: 0.8)
            )
    }

    private var statusColor: Color {
        if run.isRunning {
            return .cyan
        } else if run.isError {
            return .orange
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
}

