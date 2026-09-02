import SwiftUI

public struct HistoryView: View {
    @ObservedObject var state: OverlayState
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
                    scopeButton(title: "All", isSelected: !state.isTodayOnly) {
                        state.isTodayOnly = false
                        state.loadHistory()
                    }
                    scopeButton(title: "Today", isSelected: state.isTodayOnly) {
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
                            Button(proj) {
                                state.selectedProject = (proj == "All" ? nil : proj)
                                state.loadHistory()
                            }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "folder")
                                .font(.system(size: 9))
                            Text(state.selectedProject ?? "All Projects")
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
                Text("\(state.historyRuns.count) runs")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.45))
            }
            
            // Search Input Box
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 9.5))
                    .foregroundColor(.white.opacity(0.4))
                
                TextField("Search session, branch, or prompt...", text: $state.searchQuery)
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
                Text("No results for \"\(state.searchQuery)\"")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Button {
                    state.searchQuery = ""
                    state.loadHistory()
                } label: {
                    Text("Clear Search")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if state.isTodayOnly {
                Text("No tasks recorded today")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Button {
                    state.isTodayOnly = false
                    state.loadHistory()
                } label: {
                    Text("Show All Time")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else if let p = state.selectedProject {
                Text("No runs for project \"\(p)\"")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Button {
                    state.selectedProject = nil
                    state.loadHistory()
                } label: {
                    Text("Show All Projects")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.15)))
                }
                .buttonStyle(.plain)
            } else {
                Text("No telemetry runs recorded yet")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Text("FlowPilot logs token and duration telemetry automatically.")
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
    public var index: Int
    public var run: TaskRun
    public var isSelected: Bool
    public var onSelect: () -> Void
    
    @State private var isHovered: Bool = false
    
    public var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 7) {
                // Index badge
                Text("#\(index)")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .foregroundColor(index == 1 ? .cyan : .white.opacity(0.45))
                    .frame(width: 24, alignment: .leading)
                
                // Main Info
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        // Project & branch chip
                        Text(run.projectName)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundColor(.white.opacity(0.95))
                            .lineLimit(1)
                        
                        if let b = run.gitBranch, !b.isEmpty {
                            Text("(\(b))")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundColor(.cyan.opacity(0.8))
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        // Time stamp
                        Text(run.formattedDate)
                            .font(.system(size: 8.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    
                    // Task Preview / Title
                    Text(run.sessionTitle)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    // Footer details: Workers, Duration, Tokens
                    HStack(spacing: 6) {
                        let wCount = run.allWorkers.count
                        if wCount > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 7.5))
                                Text("\(wCount) workers")
                                    .font(.system(size: 8.5, weight: .medium))
                            }
                            .foregroundColor(.teal.opacity(0.85))
                        } else {
                            Text("Direct")
                                .font(.system(size: 8.5, weight: .regular))
                                .foregroundColor(.white.opacity(0.4))
                        }
                        
                        Text("·")
                            .foregroundColor(.white.opacity(0.2))
                        
                        Text(run.formattedDuration)
                            .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.55))
                        
                        Spacer()
                        
                        // Tokens Badge
                        Text(run.formattedTotalTokens)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
                        
                        // Status dot
                        Circle()
                            .fill(statusColor)
                            .frame(width: 4.5, height: 4.5)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(
                        isSelected ? Color.cyan.opacity(0.15) :
                        (isHovered ? Color.white.opacity(0.07) : Color.white.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(
                                isSelected ? Color.cyan.opacity(0.4) :
                                (isHovered ? Color.white.opacity(0.12) : Color.white.opacity(0.05)),
                                lineWidth: 0.8
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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

