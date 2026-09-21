import SwiftUI

public struct AnalyticsView: View {
    @ObservedObject var state: OverlayState
    @ObservedObject private var localization = AppLocalization.shared
    public var isFullHeight: Bool = false

    @State private var detailsExpanded = false
    @State private var trendRuns: [TaskRun] = []
    @State private var trendLoading = false
    @State private var trendRequestGeneration = 0

    public init(state: OverlayState, isFullHeight: Bool = false) {
        self.state = state
        self.isFullHeight = isFullHeight
    }

    private var stats: TelemetryStats {
        state.statsData ?? TelemetryStats()
    }

    public var body: some View {
        let content = VStack(spacing: 20) {
            periodHeader

            if stats.totalRuns == 0 {
                emptyStatsState
            } else {
                kpiSummaryGrid
                OverlayDivider()
                usageTrendCard
                OverlayDivider()
                efficiencyCard

                if !stats.models.isEmpty || !stats.projects.isEmpty {
                    DisclosureGroup(L("More statistics", "更多统计"), isExpanded: $detailsExpanded) {
                        VStack(spacing: 18) {
                            if !stats.models.isEmpty { modelBreakdownCard }
                            if !stats.projects.isEmpty { projectBreakdownCard }
                        }.padding(.top, 14)
                    }
                    .font(.system(size: 12.5)).tint(OverlayTheme.secondary)
                }
            }
        }
        .padding(.vertical, 20)

        return Group {
            if isFullHeight {
                content
            } else {
                ScrollView(.vertical, showsIndicators: true) { content }
                    .frame(maxHeight: .infinity)
            }
        }
        .onAppear {
            state.loadStats()
            loadTrendRuns()
        }
        .onChange(of: state.statsDays) { _, _ in
            loadTrendRuns()
        }
        .onChange(of: state.selectedProject) { _, _ in
            loadTrendRuns()
        }
    }

    // MARK: - Period

    private var periodHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Statistics", "统计"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white.opacity(0.86))
                Text(L("Locally recorded turns", "本机已记录轮次"))
                    .font(.system(size: 11.5))
                    .foregroundColor(OverlayTheme.muted)
            }

            Spacer()

            HStack(spacing: 2) {
                dayButton(days: 7, title: L("7 Days", "7 天"))
                dayButton(days: 30, title: L("30 Days", "30 天"))
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
        }
    }

    private func dayButton(days: Int, title: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.14)) {
                state.statsDays = days
                state.loadStats()
            }
        } label: {
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(state.statsDays == days ? .white : .white.opacity(0.48))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(state.statsDays == days ? Color.white.opacity(0.12) : Color.clear))
        }
        .buttonStyle(OverlayButtonStyle(cornerRadius: 14))
    }

    // MARK: - Empty

    private var emptyStatsState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 24))
                .foregroundColor(OverlayTheme.muted)
                .padding(.top, 28)
            Text(L("No activity in this period", "当前周期暂无活动"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(OverlayTheme.secondary)
            Text(L("Task, token and efficiency trends will appear after telemetry is recorded.", "记录遥测后会显示任务、Token 与效率趋势。"))
                .font(.system(size: 12))
                .foregroundColor(OverlayTheme.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 15)
        }
        .frame(maxWidth: .infinity, minHeight: 225)
    }

    // MARK: - KPIs

    private var kpiSummaryGrid: some View {
        HStack(spacing: 0) {
            analyticsKPI(
                title: L("Tasks", "任务"),
                value: "\(stats.totalRuns)",
                subtext: L("\(stats.delegatedRuns) delegated", "委派 \(stats.delegatedRuns) 次"),
                icon: "sparkles",
                accent: OverlayTheme.accent
            )

            OverlayDivider(vertical: true).frame(height: 42)

            analyticsKPI(
                title: L("Active Time", "活跃时长"),
                value: stats.formattedTotalDuration,
                subtext: L("past \(stats.days)d", "近 \(stats.days) 天"),
                icon: "timer",
                accent: OverlayTheme.accent
            )

            OverlayDivider(vertical: true).frame(height: 42)

            // No monetary "Cost" here: token counts are deterministic, while
            // estimated credits are optional and are not equivalent to USD.
            analyticsKPI(
                title: L("Tokens", "Token"),
                value: TaskRun.formatTokenCount(stats.totalTokens),
                subtext: L(
                    "out \(TaskRun.formatTokenCount(stats.outputTokens))",
                    "输出 \(TaskRun.formatTokenCount(stats.outputTokens))"
                ),
                icon: "circle.grid.cross.fill",
                accent: OverlayTheme.accent
            )
        }
    }

    private func analyticsKPI(title: String, value: String, subtext: String, icon: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(accent)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(OverlayTheme.muted)

            }

            Text(value)
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
                .lineLimit(1)

            Text(subtext)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(OverlayTheme.muted)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
    }

    // MARK: - Trend curve

    private var usageTrendCard: some View {
        let points = UsageTrendPoint.make(runs: trendRuns, days: state.statsDays)
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                HStack(spacing: 4) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 12))
                        .foregroundColor(OverlayTheme.accent)
                    Text(L("Usage Trend", "用量趋势"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(OverlayTheme.secondary)
                }
                Spacer()
                if trendLoading {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(L("tokens / day", "Token / 天"))
                        .font(.system(size: 12))
                        .foregroundColor(OverlayTheme.muted)
                }
            }

            UsageTrendChart(points: points)
                .frame(height: 116)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Efficiency

    private var efficiencyCard: some View {
        VStack(spacing: 16) {
            efficiencyRow(
                title: L("Cache Efficiency", "缓存效率"),
                percentage: stats.cacheRatio,
                detail: L("\(TaskRun.formatTokenCount(stats.cachedInputTokens)) cached", "缓存 \(TaskRun.formatTokenCount(stats.cachedInputTokens))"),
                accent: OverlayTheme.accent
            )

            efficiencyRow(
                title: L("Worker Offload", "Worker 分流"),
                percentage: stats.workerOffloadRatio,
                detail: "\(TaskRun.formatTokenCount(stats.workerTokens)) / \(TaskRun.formatTokenCount(stats.totalTokens))",
                accent: OverlayTheme.good
            )
        }
        .padding(.vertical, 4)
    }

    private func efficiencyRow(title: String, percentage: Double, detail: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OverlayTheme.muted)
                Spacer()
                Text(String(format: "%.1f%%", percentage))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(accent)
            }
            Text(detail)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(OverlayTheme.muted)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.075))
                    Capsule()
                        .fill(accent)
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, percentage / 100.0))))
                }
            }
            .frame(height: 4.5)
        }
    }

    // MARK: - Model & project breakdown

    private var modelBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Model Breakdown", "模型分布"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OverlayTheme.muted)


            ForEach(stats.models) { model in
                AnalyticsModelRow(model: model, totalTokens: stats.totalTokens)
            }
        }
        .padding(.vertical, 4)
    }

    private var projectBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Projects Distribution", "项目分布"))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OverlayTheme.muted)


            ForEach(Array(stats.projects.prefix(6))) { project in
                AnalyticsProjectRow(project: project, isPrivacyMode: state.isPrivacyMode)
            }
        }
        .padding(.vertical, 4)
    }

    private func loadTrendRuns() {
        trendRequestGeneration += 1
        let generation = trendRequestGeneration
        trendLoading = true
        let days = state.statsDays
        let project = state.selectedProject
        DispatchQueue.global(qos: .userInitiated).async {
            let runs = TelemetryQueryEngine.shared.fetchHistory(
                limit: 1200,
                project: project,
                todayOnly: false,
                search: ""
            )
            let cutoff = Date().addingTimeInterval(-Double(days) * 86_400).timeIntervalSince1970 * 1000.0
            let filtered = runs.filter { ($0.startedAtMs ?? 0) >= cutoff }
            DispatchQueue.main.async {
                guard generation == trendRequestGeneration else { return }
                trendRuns = filtered
                trendLoading = false
            }
        }
    }
}

// MARK: - Trend chart

public struct UsageTrendPoint: Identifiable {
    public var id: Date { date }
    public let date: Date
    public let tokens: Int
    public let runs: Int

    public static func make(runs: [TaskRun], days: Int) -> [UsageTrendPoint] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: Date())
        let start = calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: end) ?? end

        var buckets: [Date: (tokens: Int, runs: Int)] = [:]
        for run in runs {
            guard let ms = run.startedAtMs else { continue }
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: ms / 1000.0))
            guard day >= start && day <= end else { continue }
            let existing = buckets[day] ?? (0, 0)
            buckets[day] = (existing.tokens + (run.aggregatedUsage.totalTokens ?? 0), existing.runs + 1)
        }

        return (0..<max(1, days)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let value = buckets[day] ?? (0, 0)
            return UsageTrendPoint(date: day, tokens: value.tokens, runs: value.runs)
        }
    }
}

public struct UsageTrendChart: View {
    public let points: [UsageTrendPoint]

    public init(points: [UsageTrendPoint]) {
        self.points = points
    }

    public var body: some View {
        let maxTokens = max(1, points.map(\.tokens).max() ?? 0)
        VStack(spacing: 2) {
            HStack(spacing: 5) {
                VStack {
                    Text(TaskRun.formatTokenCount(maxTokens))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(OverlayTheme.muted)
                    Spacer()
                    Text("0")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(OverlayTheme.muted)
                }
                .frame(width: 60)
                .lineLimit(1)

                GeometryReader { proxy in
                    ZStack {
                        VStack(spacing: 0) {
                            chartGridLine
                            Spacer()
                            chartGridLine
                            Spacer()
                            chartGridLine
                        }

                        if points.count > 1 {
                            trendPath(size: proxy.size, maxTokens: maxTokens)
                                .stroke(
                                    LinearGradient(colors: [.cyan, .indigo], startPoint: .leading, endPoint: .trailing),
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                                )
                                .shadow(color: .cyan.opacity(0.3), radius: 3)

                            areaPath(size: proxy.size, maxTokens: maxTokens)
                                .fill(
                                    LinearGradient(
                                        colors: [.cyan.opacity(0.16), .cyan.opacity(0.0)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }

                        ForEach(Array(points.enumerated()), id: \.element.id) { index, point in
                            if point.tokens > 0 && (points.count <= 8 || index % max(1, points.count / 7) == 0 || index == points.count - 1) {
                                Circle()
                                    .fill(Color.cyan)
                                    .frame(width: 4, height: 4)
                                    .position(position(index: index, tokens: point.tokens, size: proxy.size, maxTokens: maxTokens))
                                    .help("\(formatTrendDate(point.date)) · \(TaskRun.formatTokenCount(point.tokens)) tokens · \(point.runs) tasks")
                            }
                        }
                    }
                }
            }

            HStack {
                Text(points.first.map { formatTrendDate($0.date) } ?? "—")
                Spacer()
                Text(points.last.map { formatTrendDate($0.date) } ?? "—")
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(OverlayTheme.muted)
            .padding(.leading, 65)
        }
    }

    private var chartGridLine: some View {
        Rectangle()
            .fill(Color.white.opacity(0.055))
            .frame(height: 0.5)
    }

    private func position(index: Int, tokens: Int, size: CGSize, maxTokens: Int) -> CGPoint {
        let denominator = max(1, points.count - 1)
        let x = size.width * CGFloat(index) / CGFloat(denominator)
        let yRatio = CGFloat(Double(tokens) / Double(maxTokens))
        let y = size.height - (size.height * yRatio)
        return CGPoint(x: x, y: max(1, min(size.height - 1, y)))
    }

    private func trendPath(size: CGSize, maxTokens: Int) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        let positions = points.enumerated().map { position(index: $0.offset, tokens: $0.element.tokens, size: size, maxTokens: maxTokens) }
        path.move(to: positions[0])
        for index in 1..<positions.count {
            let previous = positions[index - 1]
            let current = positions[index]
            let midpoint = (previous.x + current.x) / 2
            path.addCurve(
                to: current,
                control1: CGPoint(x: midpoint, y: previous.y),
                control2: CGPoint(x: midpoint, y: current.y)
            )
        }
        return path
    }

    private func areaPath(size: CGSize, maxTokens: Int) -> Path {
        var path = trendPath(size: size, maxTokens: maxTokens)
        guard points.count > 1 else { return path }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}

private func formatTrendDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd"
    return formatter.string(from: date)
}

// MARK: - Breakdown rows

public struct AnalyticsModelRow: View {
    public let model: ModelStats
    public let totalTokens: Int

    public var body: some View {
        let percentage = totalTokens > 0 ? Double(model.tokens) / Double(totalTokens) * 100 : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HoverRevealText(
                    model.name,
                    font: .system(size: 12, weight: .semibold, design: .monospaced),
                    foregroundColor: .white.opacity(0.86),
                    lineLimit: 1,
                    popoverWidth: 320
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 2) {
                    ForEach(model.roles, id: \.self) { role in
                        Text(localizedRole(role))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(role == "parent" ? .indigo : .teal)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill((role == "parent" ? Color.indigo : Color.teal).opacity(0.13)))
                    }
                }

            }

            HStack(spacing: 8) {
                Text(L("\(model.calls) calls", "\(model.calls) 次"))
                    .font(.system(size: 12))
                    .foregroundColor(OverlayTheme.muted)

                Spacer(minLength: 8)

                Text(TaskRun.formatTokenCount(model.tokens))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
                    .frame(minWidth: 38, alignment: .trailing)

                Text(String(format: "%.0f%%", percentage))
                    .font(.system(size: 12, design: .rounded))
                    .foregroundColor(OverlayTheme.muted)
                    .frame(minWidth: 36, alignment: .trailing)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.022)))
    }
}


public struct AnalyticsProjectRow: View {
    public let project: ProjectStats
    public let isPrivacyMode: Bool

    public var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "folder.fill")
                .font(.system(size: 12))
                .foregroundColor(OverlayTheme.muted)

            HoverRevealText(
                project.name,
                font: .system(size: 11, weight: .medium),
                foregroundColor: .white.opacity(0.8),
                lineLimit: 1,
                privacyBlur: isPrivacyMode,
                popoverWidth: 340
            )

            Spacer(minLength: 3)

            Text(L("\(project.runs) runs", "\(project.runs) 次"))
                .font(.system(size: 12))
                .foregroundColor(OverlayTheme.muted)

            Text(TaskRun.formatTokenCount(project.tokens))
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3.5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.022)))
    }
}
