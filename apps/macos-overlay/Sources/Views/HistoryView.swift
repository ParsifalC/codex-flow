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
            // MARK: Filter & Search Bar (Dimension 1: Project & Time Scope)
            filterBar
            
            // MARK: Chat List / Empty State (Dimension 2: Chat & Dimension 3: Session)
            if state.historyChats.isEmpty && state.historyRuns.isEmpty {
                emptyState
            } else {
                chatList
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
                
                // Project picker (Dimension 1: Project)
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
                
                // Aggregate Count Badge (Chats & Total Runs)
                countBadge
            }
            
            // Search Input Box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.4))
                
                TextField(L("Search chat, prompt, branch or id...", "搜索对话、提示词、分支或 ID…"), text: $state.searchQuery)
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
    
    private var countBadge: some View {
        let chatCount = state.historyChats.count
        let runCount = state.historyRuns.count
        let text = chatCount == runCount
            ? L("\(chatCount) chats", "\(chatCount) 个对话")
            : L("\(chatCount) chats · \(runCount) runs", "\(chatCount) 个对话 · \(runCount) 次执行")
        
        return Text(text)
            .font(.system(size: 9.0, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.5))
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
    
    // MARK: - Chat List (Accordion)
    private var chatList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 8) {
                ForEach(Array(state.historyChats.enumerated()), id: \.element.id) { index, chat in
                    ChatAccordionRow(
                        index: index + 1,
                        chat: chat,
                        isExpanded: state.isChatExpanded(chat.sessionId),
                        inspectedRunId: state.inspectedRun?.id,
                        onToggleExpand: {
                            state.toggleChatExpansion(chat.sessionId)
                        },
                        onSelectRun: { run in
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
                Text(L("No chats recorded today", "今天还没有对话记录"))
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
                Text(L("No chats for project \"\(p)\"", "项目‘\(p)’暂无对话"))
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

// MARK: - Dimension 2: Chat Level Accordion Row
public struct ChatAccordionRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    public var index: Int
    public var chat: ChatSession
    public var isExpanded: Bool
    public var inspectedRunId: String?
    public var onToggleExpand: () -> Void
    public var onSelectRun: (TaskRun) -> Void
    
    @State private var isHovered: Bool = false
    
    public var body: some View {
        VStack(spacing: 0) {
            // Chat Header Card
            chatHeaderButton
            
            // Expanded Session Breakdown (Dimension 3: Sessions inside Chat)
            if isExpanded {
                sessionsBreakdownContainer
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(containerBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? Color.cyan.opacity(0.25) : containerStrokeColor, lineWidth: 0.8)
        )
    }
    
    // MARK: - Chat Header Button
    private var chatHeaderButton: some View {
        Button(action: onToggleExpand) {
            HStack(alignment: .top, spacing: 7) {
                // Index & Chevron
                VStack(spacing: 4) {
                    Text("#\(index)")
                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                        .foregroundColor(index == 1 ? .cyan : .white.opacity(0.45))
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(isExpanded ? 0.9 : 0.35))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .animation(.easeInOut(duration: 0.18), value: isExpanded)
                }
                .frame(width: 26, alignment: .leading)
                .padding(.top, 1)
                
                // Chat Info & Aggregation
                VStack(alignment: .leading, spacing: 3) {
                    // Top: Project & Branch & Timestamp
                    HStack(spacing: 4) {
                        Text(chat.projectName)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1)
                        
                        if let branch = chat.gitBranch, !branch.isEmpty {
                            Text("(\(branch))")
                                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                                .foregroundColor(.cyan.opacity(0.8))
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Text(chat.localizedFormattedDate)
                            .font(.system(size: 8.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    
                    // Chat Title / Prompt Preview
                    Text(chat.title)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    // Chat Aggregated Metrics Row (Chat Totals)
                    HStack(spacing: 6) {
                        // Sessions count badge
                        HStack(spacing: 2.5) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.system(size: 7))
                            Text(chat.localizedRunsSummary)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                        }
                        .foregroundColor(Color.cyan.opacity(0.9))
                        .padding(.horizontal, 4.5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.cyan.opacity(0.12)))
                        
                        // Execution mode (Worker or Direct)
                        executionModeBadge
                        
                        Text("·")
                            .foregroundColor(.white.opacity(0.2))
                        
                        // Total Chat Duration
                        Text(chat.formattedDuration)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                        
                        Spacer()
                        
                        // Total Chat Tokens (Aggregated Sum)
                        Text(chat.formattedTotalTokens)
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
                        
                        // Overall Status Dot
                        Circle()
                            .fill(statusColor)
                            .frame(width: 5, height: 5)
                    }
                    .padding(.top, 1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(headerBackground)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
    
    // MARK: - Sessions Breakdown Container (Dimension 3: Sessions)
    private var sessionsBreakdownContainer: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.white.opacity(0.08))
            
            VStack(alignment: .leading, spacing: 3) {
                // Section Header / Quick action
                HStack {
                    HStack(spacing: 3) {
                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 8))
                            .foregroundColor(.cyan.opacity(0.7))
                        Text(L("Session Turns (\(chat.runs.count))", "执行轮次（共 \(chat.runs.count) 轮）"))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    
                    Spacer()
                    
                    if let latest = chat.latestRun {
                        Button {
                            onSelectRun(latest)
                        } label: {
                            HStack(spacing: 2) {
                                Image(systemName: "bolt.fill")
                                    .font(.system(size: 7))
                                Text(L("Inspect Latest", "查看最新"))
                                    .font(.system(size: 8, weight: .medium))
                            }
                            .foregroundColor(.cyan.opacity(0.85))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.cyan.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 4)
                .padding(.bottom, 2)
                
                // Individual Session Rows
                ForEach(Array(chat.runs.enumerated()), id: \.element.id) { turnIndex, run in
                    // In reversed chronological order: latest turn is highest #
                    let turnNumber = chat.runs.count - turnIndex
                    SessionItemRow(
                        chatIndex: index,
                        turnNumber: turnNumber,
                        run: run,
                        isSelected: inspectedRunId == run.id,
                        onSelect: {
                            onSelectRun(run)
                        }
                    )
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.2))
        }
    }
    
    @ViewBuilder
    private var executionModeBadge: some View {
        let maxWorkers = chat.maxWorkerCount
        if maxWorkers > 0 {
            HStack(spacing: 2) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 7.5))
                Text(L("\(maxWorkers) workers", "\(maxWorkers) 个 Worker"))
                    .font(.system(size: 8.5, weight: .medium))
            }
            .foregroundColor(.teal.opacity(0.85))
        } else {
            Text(L("Direct", "直接执行"))
                .font(.system(size: 8.5, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
        }
    }
    
    private var headerBackground: Color {
        if isHovered { return Color.white.opacity(0.06) }
        return Color.white.opacity(0.02)
    }
    
    private var containerBackground: Color {
        if isExpanded { return Color.white.opacity(0.04) }
        return Color.white.opacity(0.025)
    }
    
    private var containerStrokeColor: Color {
        if isHovered { return Color.white.opacity(0.12) }
        return Color.white.opacity(0.06)
    }
    
    private var statusColor: Color {
        if chat.isRunning {
            return .cyan
        } else if chat.isError {
            return .orange
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
}

// MARK: - Dimension 3: Individual Session Item Row
public struct SessionItemRow: View {
    @ObservedObject private var localization = AppLocalization.shared
    public var chatIndex: Int
    public var turnNumber: Int
    public var run: TaskRun
    public var isSelected: Bool
    public var onSelect: () -> Void
    
    @State private var isHovered: Bool = false
    
    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                // Left connector guide
                Capsule()
                    .fill(isSelected ? Color.cyan : (isHovered ? Color.white.opacity(0.4) : Color.white.opacity(0.12)))
                    .frame(width: 2.5, height: 22)
                
                // Turn Badge
                Text("#\(chatIndex).\(turnNumber)")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(isSelected ? .cyan : .white.opacity(0.55))
                    .frame(width: 28, alignment: .leading)
                
                // Turn Content & Meta
                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 4) {
                        // Time & Duration
                        Text(run.localizedFormattedDate)
                            .font(.system(size: 8.0, weight: .regular))
                            .foregroundColor(.white.opacity(0.45))
                        
                        Text("·")
                            .foregroundColor(.white.opacity(0.2))
                        
                        Text(run.formattedDuration)
                            .font(.system(size: 8.0, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                        
                        Spacer()
                        
                        // Worker info
                        sessionWorkerBadge
                        
                        // Turn Tokens
                        Text(run.formattedTotalTokens)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8).opacity(0.9))
                        
                        // Status dot
                        Circle()
                            .fill(runStatusColor)
                            .frame(width: 4, height: 4)
                    }
                    
                    // Turn prompt snippet / summary if available
                    if let preview = run.thread?.preview ?? run.summary, !preview.isEmpty {
                        Text(preview)
                            .font(.system(size: 8.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.65))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4.5)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.cyan.opacity(0.5) : (isHovered ? Color.white.opacity(0.12) : Color.clear), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
    
    @ViewBuilder
    private var sessionWorkerBadge: some View {
        let workers = run.allWorkers.count
        if workers > 0 {
            HStack(spacing: 1.5) {
                Image(systemName: "person.2.fill")
                    .font(.system(size: 6.5))
                Text("\(workers)w")
                    .font(.system(size: 7.5, weight: .medium))
            }
            .foregroundColor(.teal.opacity(0.8))
        }
    }
    
    private var rowBackground: Color {
        if isSelected { return Color.cyan.opacity(0.18) }
        if isHovered { return Color.white.opacity(0.08) }
        return Color.white.opacity(0.02)
    }
    
    private var runStatusColor: Color {
        if run.isRunning {
            return .cyan
        } else if run.isError {
            return .orange
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
}
