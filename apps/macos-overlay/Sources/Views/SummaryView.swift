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
        let cleanProgress = progress.isFinite ? progress : 0.04
        self.progress = min(max(cleanProgress, 0.04), 1.0)
        self.ringColor = ringColor
        self.secondaryColor = secondaryColor
        self.iconName = iconName
    }
    
    public var body: some View {
        VStack(spacing: 5) {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color.white.opacity(0.08), lineWidth: 3.5)
                    .frame(width: 40, height: 40)
                
                // Progress stroke
                Circle()
                    .trim(from: 0.0, to: CGFloat(progress))
                    .stroke(
                        AngularGradient(
                            colors: [ringColor, secondaryColor, ringColor],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 3.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 40, height: 40)
                    .shadow(color: ringColor.opacity(0.35), radius: 2.5)
                
                // Value or icon inside ring
                if let icon = iconName {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                } else {
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .frame(width: 26, height: 26)
                }
            }
            
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
                    .textCase(.uppercase)
                    .lineLimit(1)
                
                Text(value)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 2)
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

// MARK: - Quota & Rate Limit Windows Meter
public struct QuotaWindowsView: View {
    public var windows: [QuotaWindow]
    
    public init(windows: [QuotaWindow]) {
        self.windows = windows
    }
    
    public var body: some View {
        if !windows.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "gauge.with.needle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.cyan)
                        Text("Rate Limits & Account Quota")
                            .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                            .lineLimit(1)
                    }
                    
                    Spacer(minLength: 4)
                    
                    if let firstReset = windows.compactMap({ $0.formattedResetsAt }).first {
                        Text(firstReset)
                            .font(.system(size: 8.0, weight: .regular))
                            .foregroundColor(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                
                HStack(spacing: 5) {
                    ForEach(windows) { window in
                        quotaWindowPill(window: window)
                    }
                }
            }
            .padding(8)
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
    
    private func quotaWindowPill(window: QuotaWindow) -> some View {
        let used = window.usedPercent ?? 0.0
        let rem = window.remainingPercent
        let color = used > 80 ? Color.orange : (used > 50 ? Color.yellow : Color.cyan)
        
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(window.label)
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                
                Spacer(minLength: 4)
                
                Text(String(format: "%.0f%% rem", rem))
                    .font(.system(size: 8.0, weight: .semibold, design: .rounded))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            
            // Progress Bar
            GeometryReader { geo in
                let w = geo.size.width
                let fillW = max(0, min(w, w * CGFloat(used / 100.0)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(color)
                        .frame(width: fillW)
                }
            }
            .frame(height: 3)
            
            if let delta = window.deltaPercentagePoints, delta != 0 {
                Text(String(format: "%+.1f pp", delta))
                    .font(.system(size: 7.5, weight: .regular))
                    .foregroundColor(delta > 0 ? .orange.opacity(0.85) : .green.opacity(0.85))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.03))
        )
    }
}

// MARK: - Token Segmented Distribution Bar
public struct TokenDistributionBar: View {
    public var usage: TokenUsage
    
    public init(usage: TokenUsage) {
        self.usage = usage
    }
    
    private var prompt: Int { usage.effectivePromptTokens }
    private var completion: Int { usage.effectiveOutputTokens }
    private var cached: Int { usage.effectiveCachedTokens }
    private var reasoning: Int { usage.effectiveReasoningTokens }
    private var rawTotal: Int { usage.totalTokens ?? (prompt + completion) }
    private var total: Int { max(rawTotal, 1) }
    
    private var promptOnly: Int { max(0, prompt - cached) }
    
    private var promptOnlyRatio: CGFloat { rawTotal > 0 ? CGFloat(promptOnly) / CGFloat(total) : 0 }
    private var cachedRatio: CGFloat { rawTotal > 0 ? CGFloat(cached) / CGFloat(total) : 0 }
    private var completionRatio: CGFloat { rawTotal > 0 ? CGFloat(max(0, completion - reasoning)) / CGFloat(total) : 0 }
    private var reasoningRatio: CGFloat { rawTotal > 0 ? CGFloat(reasoning) / CGFloat(total) : 0 }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            headerRow
            progressBar
            legendRow
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }
    
    private var headerRow: some View {
        HStack {
            Text("Token Distribution")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            
            Spacer(minLength: 4)
            
            Text("Total: \(TaskRun.formatTokenCount(rawTotal))")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.6))
                .lineLimit(1)
        }
    }
    
    private var progressBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                if rawTotal == 0 {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                } else {
                    if promptOnly > 0 {
                        Rectangle()
                            .fill(Color(red: 0.88, green: 0.35, blue: 0.82))
                            .frame(width: max(2, w * promptOnlyRatio))
                    }
                    
                    if cached > 0 {
                        Rectangle()
                            .fill(Color(red: 0.28, green: 0.58, blue: 0.95))
                            .frame(width: max(2, w * cachedRatio))
                    }
                    
                    if completion > 0 {
                        Rectangle()
                            .fill(Color(red: 0.22, green: 0.88, blue: 0.58))
                            .frame(width: max(2, w * completionRatio))
                        
                        if reasoning > 0 {
                            Rectangle()
                                .fill(Color(red: 0.65, green: 0.45, blue: 0.95))
                                .frame(width: max(2, w * reasoningRatio))
                        }
                    }
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }
    
    private var legendRow: some View {
        VStack(spacing: 3.5) {
            // Row 1: Prompt & Output
            HStack {
                let promptPct = rawTotal > 0 ? Int(Double(prompt) / Double(total) * 100) : 0
                legendItem(
                    color: Color(red: 0.88, green: 0.35, blue: 0.82),
                    label: "Prompt",
                    count: TaskRun.formatTokenCount(prompt),
                    pct: promptPct
                )
                
                Spacer(minLength: 8)
                
                let compPct = rawTotal > 0 ? Int(Double(completion) / Double(total) * 100) : 0
                legendItem(
                    color: Color(red: 0.22, green: 0.88, blue: 0.58),
                    label: "Output",
                    count: TaskRun.formatTokenCount(completion),
                    pct: compPct
                )
            }
            
            // Row 2: Cached & Reasoning (if present)
            if cached > 0 || reasoning > 0 {
                HStack {
                    if cached > 0 {
                        let cachedPct = Int(Double(cached) / Double(total) * 100)
                        legendItem(
                            color: Color(red: 0.28, green: 0.58, blue: 0.95),
                            label: "Cached",
                            count: TaskRun.formatTokenCount(cached),
                            pct: cachedPct
                        )
                    } else {
                        Spacer()
                    }
                    
                    Spacer(minLength: 8)
                    
                    if reasoning > 0 {
                        let rPct = Int(Double(reasoning) / Double(total) * 100)
                        legendItem(
                            color: Color(red: 0.65, green: 0.45, blue: 0.95),
                            label: "Reason",
                            count: TaskRun.formatTokenCount(reasoning),
                            pct: rPct
                        )
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .padding(.top, 1)
    }
    
    private func legendItem(color: Color, label: String, count: String, pct: Int) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 4.5, height: 4.5)
            
            Text(label)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            
            Text("\(pct)%")
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.95))
            
            Text("(\(count))")
                .font(.system(size: 8.0, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// MARK: - Native Summary View Card
public struct SummaryView: View {
    @ObservedObject var state: OverlayState
    @State private var copiedSummary: Bool = false
    
    public init(state: OverlayState) {
        self.state = state
    }
    
    private var currentRun: TaskRun? {
        return state.inspectedRun ?? state.latestRun
    }
    
    private var isViewingHistoricalTask: Bool {
        if let inspected = state.inspectedRun, let latest = state.latestRun {
            return inspected.id != latest.id
        }
        return state.inspectedRun != nil
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // MARK: 1. Top Bar (App Title & Window Controls)
            topBar
            
            // MARK: 2. Glass Segmented Tab Bar
            tabSegmentedBar
            
            // MARK: 3. Dynamic Content
            switch state.activeTab {
            case .inspector:
                if let run = currentRun {
                    activeInspectorScrollContent(run: run)
                } else {
                    idleInspectorContent
                }
            case .history:
                HistoryView(state: state)
            case .analytics:
                AnalyticsView(state: state)
            }
        }
        .padding(12)
        .frame(width: 384)
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
    
    // MARK: - Top Bar
    private var topBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                
                Text("FlowPilot")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            
            if state.activeTab == .inspector {
                statusBadge
            }
            
            Spacer()
            
            // Pin Toggle Button
            Button {
                state.isPinned.toggle()
            } label: {
                Image(systemName: state.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 10.5, weight: .semibold))
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
                    .font(.system(size: 13.5))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
    }
    
    // MARK: - Glass Segmented Tab Bar
    private var tabSegmentedBar: some View {
        HStack(spacing: 4) {
            ForEach(OverlayTab.allCases) { tab in
                let isSelected = state.activeTab == tab
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        state.selectTab(tab)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.iconName)
                            .font(.system(size: 10, weight: isSelected ? .bold : .medium))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                    }
                    .foregroundColor(isSelected ? .white : .white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 27)
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(isSelected ? Color.cyan.opacity(0.28) : Color.white.opacity(0.001))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(isSelected ? Color.cyan.opacity(0.45) : Color.clear, lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                )
        )
    }
    
    // MARK: - Active Inspector Content (Scrollable Container)
    private func activeInspectorScrollContent(run: TaskRun) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                // Historical Task Notice Bar
                if isViewingHistoricalTask {
                    historicalTaskBanner
                }
                
                // Project & Branch + Session Preview
                projectHeaderRow(run: run)
                
                // 3 KPI Rings
                HStack(spacing: 6) {
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
                
                // Quota & Rate Limit Windows Meter
                if !run.effectiveQuotaWindows.isEmpty {
                    QuotaWindowsView(windows: run.effectiveQuotaWindows)
                }
                
                // Token Distribution Bar
                TokenDistributionBar(usage: run.aggregatedUsage)
                
                // Participants (Parent + Workers)
                participantsSection(run: run)
                
                // Action Footer
                actionFooter(run: run)
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 395)
    }
    
    // MARK: - Idle / Ready Inspector Content (Clean Zero/Cleared State)
    private var idleInspectorContent: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.12))
                    .frame(width: 54, height: 54)
                
                Image(systemName: "sparkles")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 14)
            
            VStack(spacing: 4) {
                Text("FlowPilot is Ready")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text("Listening for live agent runs & telemetry")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(0.6))
            }
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(red: 0.2, green: 0.85, blue: 0.45))
                        .frame(width: 6, height: 6)
                    Text("Telemetry Hook:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("Active & Streaming")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color(red: 0.2, green: 0.85, blue: 0.45))
                }
                
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 6, height: 6)
                    Text("IPC Daemon:")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("Connected")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.cyan)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
            )
            
            // Quick Actions
            HStack(spacing: 8) {
                Button {
                    openConsole()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal.fill")
                            .font(.system(size: 9.5))
                        Text("Open Console")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.cyan.opacity(0.3))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.cyan.opacity(0.5), lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
                
                Button {
                    state.selectTab(.history)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9.5))
                        Text("History")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundColor(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.1), lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 4)
    }
    
    // MARK: - Historical Task Banner
    private var historicalTaskBanner: some View {
        HStack {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 9))
                .foregroundColor(.cyan)
            
            Text("Viewing Historical Task")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.cyan)
            
            Spacer()
            
            Button {
                state.jumpToLive()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                    Text("Jump to Live")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule()
                        .fill(Color.cyan.opacity(0.35))
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.cyan.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.cyan.opacity(0.25), lineWidth: 0.6)
                )
        )
    }
    
    // MARK: - Project Header Row
    private func projectHeaderRow(run: TaskRun) -> some View {
        HStack(spacing: 6) {
            // Project & Branch Chip
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.6))
                
                Text(run.projectName)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)
                
                if let branch = run.gitBranch {
                    Text("·")
                        .foregroundColor(.white.opacity(0.3))
                    
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 7.5))
                        .foregroundColor(.cyan.opacity(0.8))
                    
                    Text(branch)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.9))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.07))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                    )
            )
            .layoutPriority(1)
            
            // Task Subtitle / Preview
            if let preview = run.thread?.preview ?? run.summary, !preview.isEmpty {
                Text(preview)
                    .font(.system(size: 10, weight: .regular))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
    
    // MARK: - Status Badge
    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusBadgeColor)
                .frame(width: 5, height: 5)
                .shadow(color: statusBadgeColor.opacity(0.8), radius: 2)
            
            Text(statusBadgeText)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundColor(statusBadgeColor)
        }
        .padding(.horizontal, 5.5)
        .padding(.vertical, 2)
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
        guard let run = currentRun else {
            return Color(red: 0.2, green: 0.85, blue: 0.45)
        }
        if run.isRunning {
            return .cyan
        } else if run.isError {
            return .orange
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
    
    private var statusBadgeText: String {
        guard let run = currentRun else {
            return "READY"
        }
        if run.isRunning {
            return "RUNNING"
        } else if run.isError {
            return "FAILED"
        }
        return "COMPLETED"
    }
    
    // MARK: - Participants Section
    private func participantsSection(run: TaskRun) -> some View {
        HStack(spacing: 6) {
            // Parent Agent
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 9))
                        .foregroundColor(.indigo.opacity(0.9))
                    Text("Parent Model")
                        .font(.system(size: 9.0, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                HStack(spacing: 3) {
                    Text(run.parent?.displayModel ?? "Direct CLI")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    if let effort = run.parent?.displayEffort {
                        Text(effort)
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundColor(.indigo.opacity(0.9))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 0.5)
                            .background(
                                Capsule()
                                    .fill(Color.indigo.opacity(0.2))
                            )
                            .lineLimit(1)
                    }
                }
                
                let u = run.parent?.effectiveUsage?.totalTokens ?? 0
                Text("\(TaskRun.formatTokenCount(u)) tokens")
                    .font(.system(size: 8.5, weight: .regular))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
            )
            
            // Workers Section
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 3) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.teal.opacity(0.9))
                    Text("Workers (\(run.allWorkers.count))")
                        .font(.system(size: 9.0, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                if run.allWorkers.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Direct Execution")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                        Text("No subagents")
                            .font(.system(size: 8.5, weight: .regular))
                            .foregroundColor(.white.opacity(0.4))
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(run.allWorkers.prefix(2)) { worker in
                            HStack(spacing: 3) {
                                Text(worker.name ?? worker.displayModel)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundColor(.white.opacity(0.85))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                
                                Spacer(minLength: 2)
                                
                                if let tok = worker.effectiveUsage?.totalTokens {
                                    Text(TaskRun.formatTokenCount(tok))
                                        .font(.system(size: 8.0, weight: .semibold, design: .rounded))
                                        .foregroundColor(.teal.opacity(0.9))
                                        .lineLimit(1)
                                }
                            }
                        }
                        
                        if run.allWorkers.count > 2 {
                            Text("+\(run.allWorkers.count - 2) more subagents")
                                .font(.system(size: 8.0, weight: .regular))
                                .foregroundColor(.teal.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                    )
            )
        }
    }
    
    // MARK: - Action Footer
    private func actionFooter(run: TaskRun) -> some View {
        HStack(spacing: 6) {
            // Copy Summary Button
            Button {
                copySummaryToClipboard(run: run)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: copiedSummary ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                    Text(copiedSummary ? "Copied!" : "Copy")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundColor(copiedSummary ? Color(red: 0.2, green: 0.85, blue: 0.45) : .white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(copiedSummary ? Color.green.opacity(0.15) : Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                        )
                )
            }
            .buttonStyle(.plain)
            
            // Open Console Button
            Button {
                openConsole()
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Console")
                        .font(.system(size: 9.5, weight: .medium))
                }
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.white.opacity(0.1), lineWidth: 0.6)
                        )
                )
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            // Relative date / update time
            Text(run.formattedDate)
                .font(.system(size: 8.5, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.top, 1)
    }
    
    private func copySummaryToClipboard(run: TaskRun) {
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

