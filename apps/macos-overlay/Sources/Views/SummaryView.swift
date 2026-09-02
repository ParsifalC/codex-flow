import SwiftUI
import AppKit

// MARK: - Metric Progress Ring Component
public struct MetricRingView: View {
    public var title: String
    public var value: String
    public var progress: Double // 0.0 to 1.0
    public var ringColor: Color
    public var secondaryColor: Color
    public var iconName: String?
    
    public init(
        title: String,
        value: String,
        progress: Double = 0.75,
        ringColor: Color = .cyan,
        secondaryColor: Color = .blue,
        iconName: String? = nil
    ) {
        self.title = title
        self.value = value
        self.progress = min(max(progress, 0.05), 1.0)
        self.ringColor = ringColor
        self.secondaryColor = secondaryColor
        self.iconName = iconName
    }
    
    public var body: some View {
        VStack(spacing: 8) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 4.5)
                    .frame(width: 46, height: 46)
                
                // Progress stroke
                Circle()
                    .trim(from: 0.0, to: CGFloat(progress))
                    .stroke(
                        AngularGradient(
                            colors: [ringColor, secondaryColor, ringColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 46, height: 46)
                    .shadow(color: ringColor.opacity(0.5), radius: 3)
                
                // Value or icon inside ring
                if let icon = iconName {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 32, height: 32)
                }
            }
            
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .textCase(.uppercase)
                
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - Token Segmented Distribution Bar
public struct TokenDistributionBar: View {
    public var usage: TokenUsage
    
    public init(usage: TokenUsage) {
        self.usage = usage
    }
    
    private var prompt: Int { usage.promptTokens ?? 0 }
    private var completion: Int { usage.completionTokens ?? 0 }
    private var cached: Int { usage.effectiveCachedTokens }
    private var total: Int { max(usage.totalTokens ?? (prompt + completion), 1) }
    
    private var promptOnly: Int { max(0, prompt - cached) }
    
    private var promptOnlyRatio: CGFloat { CGFloat(promptOnly) / CGFloat(total) }
    private var cachedRatio: CGFloat { CGFloat(cached) / CGFloat(total) }
    private var completionRatio: CGFloat { CGFloat(completion) / CGFloat(total) }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerRow
            progressBar
            legendRow
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
    
    private var headerRow: some View {
        HStack {
            Text("Token Progress")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            
            Spacer()
            
            Text("Total: \(TaskRun.formatTokenCount(usage.totalTokens ?? (prompt + completion)))")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
        }
    }
    
    private var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                if promptOnly > 0 {
                    Rectangle()
                        .fill(Color(red: 0.88, green: 0.35, blue: 0.82))
                        .frame(width: w * promptOnlyRatio)
                }
                
                if cached > 0 {
                    Rectangle()
                        .fill(Color(red: 0.28, green: 0.58, blue: 0.95))
                        .frame(width: w * cachedRatio)
                }
                
                if completion > 0 {
                    Rectangle()
                        .fill(Color(red: 0.22, green: 0.88, blue: 0.58))
                        .frame(width: w * completionRatio)
                }
            }
        }
        .frame(height: 7)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
    
    private var legendRow: some View {
        HStack {
            let promptPct = Int(Double(prompt) / Double(total) * 100)
            legendItem(
                color: Color(red: 0.88, green: 0.35, blue: 0.82),
                label: "Prompt",
                count: TaskRun.formatTokenCount(prompt),
                pct: promptPct
            )
            
            Spacer()
            
            let compPct = Int(Double(completion) / Double(total) * 100)
            legendItem(
                color: Color(red: 0.22, green: 0.88, blue: 0.58),
                label: "Output",
                count: TaskRun.formatTokenCount(completion),
                pct: compPct
            )
            
            if cached > 0 {
                Spacer()
                let cachedPct = Int(Double(cached) / Double(total) * 100)
                legendItem(
                    color: Color(red: 0.28, green: 0.58, blue: 0.95),
                    label: "Cached",
                    count: TaskRun.formatTokenCount(cached),
                    pct: cachedPct
                )
            }
        }
        .padding(.top, 1)
    }
    
    private func legendItem(color: Color, label: String, count: String, pct: Int) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5.5, height: 5.5)
            
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            
            Text("\(pct)%")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
            
            Text("(\(count))")
                .font(.system(size: 9.0, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Native Summary View Card
public struct SummaryView: View {
    @ObservedObject var state: OverlayState
    @State private var copiedSummary: Bool = false
    
    public init(state: OverlayState) {
        self.state = state
    }
    
    private var run: TaskRun {
        return state.latestRun ?? TaskRun.previewSample
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // MARK: 1. Header Bar
            headerBar
            
            // MARK: 2. Key Performance Indicators (3 Rings)
            HStack(spacing: 8) {
                MetricRingView(
                    title: "Time",
                    value: run.formattedDuration,
                    progress: min(1.0, run.durationSeconds / 30.0),
                    ringColor: Color.cyan,
                    secondaryColor: Color.indigo
                )
                
                MetricRingView(
                    title: "Tokens",
                    value: run.formattedTotalTokens,
                    progress: min(1.0, Double(run.aggregatedUsage.totalTokens ?? 0) / 100_000.0),
                    ringColor: Color(red: 0.95, green: 0.35, blue: 0.8),
                    secondaryColor: Color(red: 0.6, green: 0.2, blue: 0.9)
                )
                
                MetricRingView(
                    title: "Cost",
                    value: run.formattedCost,
                    progress: min(1.0, (run.aggregatedUsage.estimatedCreditsMicros ?? 0) / 100_000.0),
                    ringColor: Color(red: 0.2, green: 0.85, blue: 0.45),
                    secondaryColor: Color.teal
                )
            }
            
            // MARK: 3. Token Distribution Bar
            TokenDistributionBar(usage: run.aggregatedUsage)
            
            // MARK: 4. Participants (Parent + Workers)
            participantsSection
            
            // MARK: 5. Action Footer
            actionFooter
        }
        .padding(14)
        .frame(width: 376)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: .windowBackgroundColor).opacity(0.85),
                                    Color.black.opacity(0.92)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.2),
                            Color.white.opacity(0.05),
                            Color.cyan.opacity(0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        )
        .shadow(color: Color.black.opacity(0.4), radius: 16, x: 0, y: 8)
    }
    
    // MARK: - Header Bar
    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Row 1: App Title & Status + Window Controls
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.cyan, .indigo],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    Text("FlowPilot Summary")
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                }
                
                statusBadge
                
                Spacer()
                
                // Pin Toggle Button
                Button {
                    state.isPinned.toggle()
                } label: {
                    Image(systemName: state.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(state.isPinned ? .cyan : .white.opacity(0.5))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle()
                                .fill(state.isPinned ? Color.cyan.opacity(0.2) : Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
                
                // Collapse Button
                Button {
                    state.collapse()
                } label: {
                    Image(systemName: "chevron.up.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            
            // Row 2: Project & Branch Badge + Task Preview
            HStack(spacing: 6) {
                // Project & Branch Chip
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.6))
                    
                    Text(run.projectName)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    
                    if let branch = run.gitBranch {
                        Text("·")
                            .foregroundColor(.white.opacity(0.3))
                        
                        Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                            .font(.system(size: 8))
                            .foregroundColor(.cyan.opacity(0.8))
                        
                        Text(branch)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.9))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(Color.white.opacity(0.07))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                        )
                )
                .fixedSize(horizontal: true, vertical: false)
                
                // Task Subtitle / Preview
                if let preview = run.thread?.preview ?? run.summary, !preview.isEmpty {
                    Text(preview)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
    
    // MARK: - Status Badge
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusBadgeColor)
                .frame(width: 5.5, height: 5.5)
                .shadow(color: statusBadgeColor.opacity(0.8), radius: 2)
            
            Text(statusBadgeText)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(statusBadgeColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
        .background(
            Capsule()
                .fill(statusBadgeColor.opacity(0.12))
                .overlay(
                    Capsule()
                        .stroke(statusBadgeColor.opacity(0.3), lineWidth: 0.5)
                )
        )
    }
    
    private var statusBadgeColor: Color {
        if run.isRunning {
            return .cyan
        } else if run.isError {
            return .orange
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
    
    private var statusBadgeText: String {
        if run.isRunning {
            return "RUNNING"
        } else if run.isError {
            return "FAILED"
        }
        return "COMPLETED"
    }
    
    // MARK: - Participants Section
    private var participantsSection: some View {
        HStack(spacing: 8) {
            // Parent Agent
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 10))
                        .foregroundColor(.indigo.opacity(0.9))
                    Text("Parent Model")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                HStack(spacing: 4) {
                    Text(run.parent?.displayModel ?? "gpt-5-pro")
                        .font(.system(size: 11.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    if let effort = run.parent?.displayEffort {
                        Text(effort)
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.indigo.opacity(0.9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(Color.indigo.opacity(0.2))
                            )
                    }
                }
                
                if let u = run.parent?.effectiveUsage?.totalTokens {
                    Text("\(TaskRun.formatTokenCount(u)) tokens")
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
            )
            
            // Workers Section
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.teal.opacity(0.9))
                    Text("Workers (\(run.allWorkers.count))")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                if run.allWorkers.isEmpty {
                    Text("No subagents")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.white.opacity(0.4))
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(run.allWorkers.prefix(2)) { worker in
                            HStack(spacing: 4) {
                                Text(worker.name ?? worker.displayModel)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                if let tok = worker.effectiveUsage?.totalTokens {
                                    Text(TaskRun.formatTokenCount(tok))
                                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                                        .foregroundColor(.teal.opacity(0.9))
                                }
                            }
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
            )
        }
    }
    
    // MARK: - Action Footer
    private var actionFooter: some View {
        HStack(spacing: 8) {
            // Copy Summary Button
            Button {
                copySummaryToClipboard()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copiedSummary ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .semibold))
                    Text(copiedSummary ? "Copied!" : "Copy Summary")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundColor(copiedSummary ? Color(red: 0.2, green: 0.85, blue: 0.45) : .white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(copiedSummary ? Color.green.opacity(0.15) : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                        )
                )
            }
            .buttonStyle(.plain)
            
            // Open Console Button
            Button {
                openConsole()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open Console")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                        )
                )
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Relative update time
            Text("Just updated")
                .font(.system(size: 9.5, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.top, 2)
    }
    
    private func copySummaryToClipboard() {
        let text = """
        📊 FlowPilot Task Summary
        • Project: \(run.projectName) (\(run.gitBranch ?? "main"))
        • Duration: \(run.formattedDuration)
        • Total Tokens: \(run.formattedTotalTokens)
        • Estimated Cost: \(run.formattedCost)
        • Parent Model: \(run.parent?.displayModel ?? "unknown")
        • Workers: \(run.allWorkers.count)
        • Overview: \(run.summary ?? run.sessionTitle)
        """
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        
        withAnimation {
            copiedSummary = true
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation {
                copiedSummary = false
            }
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
