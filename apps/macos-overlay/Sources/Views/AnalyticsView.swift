import SwiftUI

public struct AnalyticsView: View {
    @ObservedObject var state: OverlayState
    
    public init(state: OverlayState) {
        self.state = state
    }
    
    private var stats: TelemetryStats {
        return state.statsData ?? TelemetryStats()
    }
    
    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 9) {
                // MARK: 1. Header & Period Selector
                periodHeader
                
                if stats.totalRuns == 0 {
                    emptyStatsState
                } else {
                    // MARK: 2. Core KPIs Row
                    kpiSummaryGrid
                    
                    // MARK: 3. Efficiency Rings / Bars (Cache & Offload)
                    efficiencyCard
                    
                    // MARK: 4. Model Breakdown List
                    if !stats.models.isEmpty {
                        modelBreakdownCard
                    }
                    
                    // MARK: 5. Project Breakdown List
                    if !stats.projects.isEmpty {
                        projectBreakdownCard
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 345)
        .onAppear {
            state.loadStats()
        }
    }
    
    // MARK: - Period Header
    private var periodHeader: some View {
        HStack {
            Text("Aggregation Summary")
                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
            
            Spacer()
            
            HStack(spacing: 2) {
                dayButton(days: 7, title: "7 Days")
                dayButton(days: 30, title: "30 Days")
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }
    
    private func dayButton(days: Int, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                state.statsDays = days
                state.loadStats()
            }
        } label: {
            Text(title)
                .font(.system(size: 9, weight: state.statsDays == days ? .bold : .medium, design: .rounded))
                .foregroundColor(state.statsDays == days ? .white : .white.opacity(0.55))
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .contentShape(Capsule())
                .background(
                    Capsule()
                        .fill(state.statsDays == days ? Color.cyan.opacity(0.3) : Color.white.opacity(0.001))
                )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Empty Stats State
    private var emptyStatsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.3))
                .padding(.top, 28)
            
            Text("No activity in past \(state.statsDays) days")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.white.opacity(0.75))
            
            Text("Multi-model usage, cache efficiencies, and worker offload metrics will appear here automatically.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
    }
    
    // MARK: - Core KPI Summary Grid
    private var kpiSummaryGrid: some View {
        HStack(spacing: 6) {
            kpiCard(
                title: "Tasks",
                value: "\(stats.totalRuns)",
                subtext: "\(stats.delegatedRuns) delegated",
                icon: "sparkles",
                accentColor: .cyan
            )
            
            kpiCard(
                title: "Active Time",
                value: stats.formattedTotalDuration,
                subtext: "\(stats.days)d total",
                icon: "timer",
                accentColor: .indigo
            )
            
            kpiCard(
                title: "Tokens",
                value: TaskRun.formatTokenCount(stats.totalTokens),
                subtext: stats.formattedCost,
                icon: "circle.grid.cross.fill",
                accentColor: Color(red: 0.95, green: 0.35, blue: 0.8)
            )
        }
    }
    
    private func kpiCard(title: String, value: String, subtext: String, icon: String, accentColor: Color) -> some View {
        VStack(spacing: 2.5) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundColor(accentColor)
                Text(title)
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .textCase(.uppercase)
            }
            
            Text(value)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
            
            Text(subtext)
                .font(.system(size: 8.0, weight: .regular, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                )
        )
    }
    
    // MARK: - Efficiency & Offload Card
    private var efficiencyCard: some View {
        VStack(spacing: 6) {
            // Cache Ratio Bar
            efficiencyRow(
                title: "Cache Efficiency",
                percentage: stats.cacheRatio,
                detail: "\(TaskRun.formatTokenCount(stats.cachedInputTokens)) cached",
                color: Color(red: 0.28, green: 0.58, blue: 0.95)
            )
            
            // Worker Offload Bar
            efficiencyRow(
                title: "Worker Offload",
                percentage: stats.workerOffloadRatio,
                detail: "\(TaskRun.formatTokenCount(stats.workerTokens)) / \(TaskRun.formatTokenCount(stats.totalTokens))",
                color: Color(red: 0.22, green: 0.88, blue: 0.58)
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                )
        )
    }
    
    private func efficiencyRow(title: String, percentage: Double, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 9.0, weight: .medium))
                    .foregroundColor(.white.opacity(0.75))
                
                Spacer()
                
                Text(String(format: "%.1f%%", percentage))
                    .font(.system(size: 9.0, weight: .bold, design: .rounded))
                    .foregroundColor(color)
                
                Text("(\(detail))")
                    .font(.system(size: 8.0, weight: .regular, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            
            GeometryReader { geo in
                let w = geo.size.width
                let fillW = max(0, min(w, w * CGFloat(percentage / 100.0)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: fillW)
                }
            }
            .frame(height: 4.5)
        }
    }
    
    // MARK: - Model Breakdown Card
    private var modelBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Model Breakdown")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .textCase(.uppercase)
            
            VStack(spacing: 4) {
                ForEach(stats.models) { m in
                    ModelBreakdownRow(model: m, totalTokens: stats.totalTokens)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                )
        )
    }
    
    // MARK: - Project Breakdown Card
    private var projectBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Projects Distribution")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
                .textCase(.uppercase)
            
            VStack(spacing: 3.5) {
                ForEach(Array(stats.projects.prefix(5))) { p in
                    ProjectBreakdownRow(project: p)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.8)
                )
        )
    }
}

// MARK: - Model Breakdown Row
public struct ModelBreakdownRow: View {
    public var model: ModelStats
    public var totalTokens: Int
    
    public var body: some View {
        let pct = totalTokens > 0 ? (Double(model.tokens) / Double(totalTokens) * 100.0) : 0
        HStack(spacing: 5) {
            Text(model.name)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))
                .frame(width: 90, alignment: .leading)
                .lineLimit(1)
            
            // Roles chips
            HStack(spacing: 2) {
                ForEach(model.roles, id: \.self) { role in
                    Text(role)
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundColor(role == "parent" ? .indigo.opacity(0.9) : .teal.opacity(0.9))
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(
                            Capsule()
                                .fill((role == "parent" ? Color.indigo : Color.teal).opacity(0.2))
                        )
                }
            }
            
            Spacer()
            
            Text("\(model.calls) calls")
                .font(.system(size: 8.0, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
            
            Text(TaskRun.formatTokenCount(model.tokens))
                .font(.system(size: 9.0, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
                .frame(width: 40, alignment: .trailing)
            
            Text(String(format: "%.0f%%", pct))
                .font(.system(size: 8.0, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.5))
                .frame(width: 24, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.025))
        )
    }
}

// MARK: - Project Breakdown Row
public struct ProjectBreakdownRow: View {
    public var project: ProjectStats
    
    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 7.5))
                .foregroundColor(.white.opacity(0.5))
            
            Text(project.name)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            
            Spacer()
            
            Text("\(project.runs) runs")
                .font(.system(size: 8.0, weight: .regular))
                .foregroundColor(.white.opacity(0.4))
            
            Text(TaskRun.formatTokenCount(project.tokens))
                .font(.system(size: 9.0, weight: .bold, design: .rounded))
                .foregroundColor(.cyan)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
    }
}

