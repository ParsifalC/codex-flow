import Foundation

public enum OverlayTab: String, CaseIterable, Identifiable {
    case inspector = "Inspector"
    case history = "History"
    case analytics = "Analytics"
    
    public var id: String { rawValue }
    
    public var iconName: String {
        switch self {
        case .inspector: return "bolt.fill"
        case .history: return "clock.arrow.circlepath"
        case .analytics: return "chart.bar.xaxis"
        }
    }
}

public struct GitInfo: Codable {
    public var branch: String?
    public var commit: String?
    
    public init(branch: String? = nil, commit: String? = nil) {
        self.branch = branch
        self.commit = commit
    }
}

public struct ThreadInfo: Codable {
    public var name: String?
    public var preview: String?
    public var cwd: String?
    public var gitInfo: GitInfo?
    
    public init(name: String? = nil, preview: String? = nil, cwd: String? = nil, gitInfo: GitInfo? = nil) {
        self.name = name
        self.preview = preview
        self.cwd = cwd
        self.gitInfo = gitInfo
    }
}

public struct TokenUsage: Codable {
    public var totalTokens: Int?
    public var promptTokens: Int?
    public var inputTokens: Int?
    public var completionTokens: Int?
    public var outputTokens: Int?
    public var cachedPromptTokens: Int?
    public var cachedInputTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var estimatedCreditsMicros: Double?
    
    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case inputTokens = "input_tokens"
        case completionTokens = "completion_tokens"
        case outputTokens = "output_tokens"
        case cachedPromptTokens = "cached_prompt_tokens"
        case cachedInputTokens = "cached_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case estimatedCreditsMicros = "estimated_credits_micros"
    }
    
    public init(
        totalTokens: Int? = nil,
        promptTokens: Int? = nil,
        inputTokens: Int? = nil,
        completionTokens: Int? = nil,
        outputTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        estimatedCreditsMicros: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.inputTokens = inputTokens
        self.completionTokens = completionTokens
        self.outputTokens = outputTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.cachedInputTokens = cachedInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.estimatedCreditsMicros = estimatedCreditsMicros
    }
    
    public var effectivePromptTokens: Int {
        if let p = promptTokens, p > 0 { return p }
        if let i = inputTokens, i > 0 { return i }
        return 0
    }
    
    public var effectiveOutputTokens: Int {
        if let c = completionTokens, c > 0 { return c }
        if let o = outputTokens, o > 0 { return o }
        return 0
    }
    
    public var effectiveCachedTokens: Int {
        if let c = cachedPromptTokens, c > 0 { return c }
        if let ci = cachedInputTokens, ci > 0 { return ci }
        if let r = cacheReadInputTokens, r > 0 { return r }
        return 0
    }
    
    public var effectiveReasoningTokens: Int {
        return reasoningOutputTokens ?? 0
    }
}

public struct ParticipantInfo: Codable, Identifiable {
    public var id: String { name ?? model ?? UUID().uuidString }
    public var name: String?
    public var agentType: String?
    public var model: String?
    public var reasoningEffort: String?
    public var status: String?
    public var usage: TokenUsage?
    public var usageDelta: TokenUsage?
    
    enum CodingKeys: String, CodingKey {
        case name
        case agentType = "agent_type"
        case model
        case reasoningEffort = "reasoning_effort"
        case status
        case usage
        case usageDelta = "usage_delta"
    }
    
    public init(
        name: String? = nil,
        agentType: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        status: String? = nil,
        usage: TokenUsage? = nil,
        usageDelta: TokenUsage? = nil
    ) {
        self.name = name
        self.agentType = agentType
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.status = status
        self.usage = usage
        self.usageDelta = usageDelta
    }
    
    public var effectiveUsage: TokenUsage? {
        return usageDelta ?? usage
    }
    
    public var displayModel: String {
        return model ?? "unknown"
    }
    
    public var displayEffort: String? {
        guard let effort = reasoningEffort, !effort.isEmpty, effort.lowercased() != "none" else {
            return nil
        }
        return effort
    }
}

public struct QuotaWindow: Codable, Identifiable {
    public var id: String { "\(slot ?? "primary")_\(windowDurationMins ?? 0)" }
    public var slot: String?
    public var usedPercent: Double?
    public var windowDurationMins: Int?
    public var resetsAt: Double?
    public var deltaPercentagePoints: Double?
    
    enum CodingKeys: String, CodingKey {
        case slot
        case usedPercent = "used_percent"
        case windowDurationMins = "window_duration_mins"
        case resetsAt = "resets_at"
        case deltaPercentagePoints = "delta_percentage_points"
    }
    
    public init(
        slot: String? = nil,
        usedPercent: Double? = nil,
        windowDurationMins: Int? = nil,
        resetsAt: Double? = nil,
        deltaPercentagePoints: Double? = nil
    ) {
        self.slot = slot
        self.usedPercent = usedPercent
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
        self.deltaPercentagePoints = deltaPercentagePoints
    }
    
    public var label: String {
        guard let mins = windowDurationMins else {
            return slot?.capitalized ?? "Window"
        }
        if mins < 60 {
            return "\(mins)m"
        } else if mins < 1440 {
            let hours = mins / 60
            return "\(hours)h"
        } else {
            let days = mins / 1440
            return "\(days)d"
        }
    }
    
    public var remainingPercent: Double {
        guard let used = usedPercent else { return 100.0 }
        return max(0.0, 100.0 - used)
    }
    
    public var formattedResetsAt: String? {
        guard let r = resetsAt, r > 0 else { return nil }
        let date = Date(timeIntervalSince1970: r > 1_000_000_000_000 ? r / 1000.0 : r)
        let now = Date()
        let interval = date.timeIntervalSince(now)
        if interval <= 0 {
            return "resets now"
        } else if interval < 86400 {
            let mins = Int(interval) / 60
            if mins < 60 {
                return "resets in \(max(1, mins))m"
            } else {
                let hours = mins / 60
                let remMins = mins % 60
                return "resets in \(hours)h \(remMins)m"
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "resets at \(formatter.string(from: date))"
    }
}

public struct TaskRun: Codable, Identifiable {
    public var id: String {
        if let s = sessionId, let t = turnId {
            return "\(s)--\(t)"
        }
        return fileStem ?? UUID().uuidString
    }
    
    public var fileStem: String?
    public var sessionId: String?
    public var turnId: String?
    public var startedAtMs: Double?
    public var finishedAtMs: Double?
    public var status: String?
    public var thread: ThreadInfo?
    public var cwd: String?
    public var summary: String?
    public var parent: ParticipantInfo?
    public var workersDict: [String: ParticipantInfo]?
    public var workersList: [ParticipantInfo]?
    public var quotaBefore: [QuotaWindow]?
    public var quotaChangeDuringRun: [QuotaWindow]?
    
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case turnId = "turn_id"
        case startedAtMs = "started_at_ms"
        case finishedAtMs = "finished_at_ms"
        case status
        case thread
        case cwd
        case summary
        case parent
        case workers
        case quotaBefore = "quota_before"
        case quotaChangeDuringRun = "quota_change_during_run"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        turnId = try container.decodeIfPresent(String.self, forKey: .turnId)
        
        if let s = try? container.decode(Double.self, forKey: .startedAtMs) {
            startedAtMs = s
        } else if let s = try? container.decode(Int.self, forKey: .startedAtMs) {
            startedAtMs = Double(s)
        }
        
        if let f = try? container.decode(Double.self, forKey: .finishedAtMs) {
            finishedAtMs = f
        } else if let f = try? container.decode(Int.self, forKey: .finishedAtMs) {
            finishedAtMs = Double(f)
        }
        
        status = try container.decodeIfPresent(String.self, forKey: .status)
        thread = try container.decodeIfPresent(ThreadInfo.self, forKey: .thread)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        parent = try container.decodeIfPresent(ParticipantInfo.self, forKey: .parent)
        quotaBefore = try container.decodeIfPresent([QuotaWindow].self, forKey: .quotaBefore)
        quotaChangeDuringRun = try container.decodeIfPresent([QuotaWindow].self, forKey: .quotaChangeDuringRun)
        
        if let dict = try? container.decode([String: ParticipantInfo].self, forKey: .workers) {
            workersDict = dict
            workersList = Array(dict.values)
        } else if let list = try? container.decode([ParticipantInfo].self, forKey: .workers) {
            workersList = list
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(turnId, forKey: .turnId)
        try container.encodeIfPresent(startedAtMs, forKey: .startedAtMs)
        try container.encodeIfPresent(finishedAtMs, forKey: .finishedAtMs)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(thread, forKey: .thread)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(summary, forKey: .summary)
        try container.encodeIfPresent(parent, forKey: .parent)
        try container.encodeIfPresent(workersDict, forKey: .workers)
        try container.encodeIfPresent(quotaBefore, forKey: .quotaBefore)
        try container.encodeIfPresent(quotaChangeDuringRun, forKey: .quotaChangeDuringRun)
    }
    
    public init(
        sessionId: String? = nil,
        turnId: String? = nil,
        startedAtMs: Double? = nil,
        finishedAtMs: Double? = nil,
        status: String? = nil,
        thread: ThreadInfo? = nil,
        cwd: String? = nil,
        summary: String? = nil,
        parent: ParticipantInfo? = nil,
        workers: [ParticipantInfo]? = nil,
        quotaBefore: [QuotaWindow]? = nil,
        quotaChangeDuringRun: [QuotaWindow]? = nil,
        fileStem: String? = nil
    ) {
        self.sessionId = sessionId
        self.turnId = turnId
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
        self.status = status
        self.thread = thread
        self.cwd = cwd
        self.summary = summary
        self.parent = parent
        self.workersList = workers
        self.quotaBefore = quotaBefore
        self.quotaChangeDuringRun = quotaChangeDuringRun
        self.fileStem = fileStem
    }
    
    // MARK: - Computed Properties
    
    public var projectName: String {
        if let c = thread?.cwd ?? cwd, !c.isEmpty {
            return URL(fileURLWithPath: c).lastPathComponent
        }
        if let n = thread?.name, !n.isEmpty {
            return n
        }
        return "codex-flow"
    }
    
    public var gitBranch: String? {
        return thread?.gitInfo?.branch
    }
    
    public var sessionTitle: String {
        return thread?.preview ?? thread?.name ?? summary ?? sessionId ?? "FlowPilot Task"
    }
    
    public var isRunning: Bool {
        if let st = status?.lowercased() {
            return st == "running" || st == "in_progress" || st == "active"
        }
        return finishedAtMs == nil
    }
    
    public var isSuccess: Bool {
        if let st = status?.lowercased() {
            return st == "success" || st == "completed" || st == "finished"
        }
        return finishedAtMs != nil
    }
    
    public var isError: Bool {
        if let st = status?.lowercased() {
            return st == "error" || st == "failed" || st == "cancelled"
        }
        return false
    }
    
    public var durationSeconds: Double {
        guard let s = startedAtMs else { return 0 }
        let e = finishedAtMs ?? (Date().timeIntervalSince1970 * 1000)
        return max(0, (e - s) / 1000.0)
    }
    
    public var formattedDuration: String {
        let d = durationSeconds
        if d < 1.0 {
            return String(format: "%.0f ms", d * 1000)
        } else if d < 60.0 {
            return String(format: "%.1f s", d)
        } else {
            let mins = Int(d) / 60
            let secs = Int(d) % 60
            return "\(mins)m \(secs)s"
        }
    }
    
    public var formattedDate: String {
        guard let s = startedAtMs else { return "--:--" }
        let date = Date(timeIntervalSince1970: s / 1000.0)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return "Today \(formatter.string(from: date))"
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }
    
    public var allWorkers: [ParticipantInfo] {
        return workersList ?? (workersDict != nil ? Array(workersDict!.values) : [])
    }
    
    public var effectiveQuotaWindows: [QuotaWindow] {
        if let current = quotaChangeDuringRun, !current.isEmpty {
            return current
        }
        return quotaBefore ?? []
    }
    
    public var aggregatedUsage: TokenUsage {
        var total = 0
        var prompt = 0
        var completion = 0
        var cached = 0
        var reasoning = 0
        var credits: Double = 0
        
        let allParticipants = [parent].compactMap { $0 } + allWorkers
        for p in allParticipants {
            if let u = p.effectiveUsage {
                total += u.totalTokens ?? (u.effectivePromptTokens + u.effectiveOutputTokens)
                prompt += u.effectivePromptTokens
                completion += u.effectiveOutputTokens
                cached += u.effectiveCachedTokens
                reasoning += u.effectiveReasoningTokens
                credits += u.estimatedCreditsMicros ?? 0
            }
        }
        
        return TokenUsage(
            totalTokens: total > 0 ? total : nil,
            promptTokens: prompt > 0 ? prompt : nil,
            completionTokens: completion > 0 ? completion : nil,
            cachedPromptTokens: cached > 0 ? cached : nil,
            reasoningOutputTokens: reasoning > 0 ? reasoning : nil,
            estimatedCreditsMicros: credits > 0 ? credits : nil
        )
    }
    
    public var formattedTotalTokens: String {
        let count = aggregatedUsage.totalTokens ?? 0
        return TaskRun.formatTokenCount(count)
    }
    
    public var formattedCompactTokens: String {
        let count = aggregatedUsage.totalTokens ?? 0
        return TaskRun.formatCompactTokenCount(count)
    }
    
    public var formattedCost: String {
        if let creditsMicros = aggregatedUsage.estimatedCreditsMicros, creditsMicros > 0 {
            let dollars = creditsMicros / 1_000_000.0
            return String(format: "$%.3f", dollars)
        }
        return "--"
    }
    
    public static func formatTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        } else if count >= 1_000 {
            return String(format: "%.1fk", Double(count) / 1_000.0)
        } else {
            return "\(count)"
        }
    }
    
    public static func formatCompactTokenCount(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.0fM", round(Double(count) / 1_000_000.0))
        } else if count >= 1_000 {
            return String(format: "%.0fk", round(Double(count) / 1_000.0))
        } else {
            return "\(count)"
        }
    }
    
    // Preview sample data for testing and mock rendering
    public static var previewSample: TaskRun {
        return TaskRun(
            sessionId: "sess-84920",
            turnId: "turn-01",
            startedAtMs: Date().addingTimeInterval(-14.2).timeIntervalSince1970 * 1000,
            finishedAtMs: Date().timeIntervalSince1970 * 1000,
            status: "completed",
            thread: ThreadInfo(
                name: "codex-flow",
                preview: "feat: macOS native floating widget with hover expand",
                cwd: "/Users/parsifal/Repo/SkillHub/codex-flow",
                gitInfo: GitInfo(branch: "main")
            ),
            cwd: "/Users/parsifal/Repo/SkillHub/codex-flow",
            summary: "成功实现 macOS 原生悬浮窗与 Summary UI，支持光标悬停平滑展开、动态环形指标、Quota 配额监控与多 Agent 拓扑展示。",
            parent: ParticipantInfo(
                name: "Parent Agent",
                agentType: "orchestrator",
                model: "gpt-5-pro",
                reasoningEffort: "high",
                status: "completed",
                usage: TokenUsage(
                    totalTokens: 14200,
                    promptTokens: 8500,
                    completionTokens: 5700,
                    cachedPromptTokens: 3200,
                    reasoningOutputTokens: 2100,
                    estimatedCreditsMicros: 18000
                )
            ),
            workers: [
                ParticipantInfo(
                    name: "Worker 1 (UI Engine)",
                    agentType: "subagent",
                    model: "gpt-5-flash",
                    reasoningEffort: "medium",
                    status: "completed",
                    usage: TokenUsage(
                        totalTokens: 26100,
                        promptTokens: 14000,
                        completionTokens: 12100,
                        cachedPromptTokens: 8200,
                        reasoningOutputTokens: 3800,
                        estimatedCreditsMicros: 14000
                    )
                ),
                ParticipantInfo(
                    name: "Worker 2 (IPC & Telemetry)",
                    agentType: "subagent",
                    model: "gpt-5-flash",
                    reasoningEffort: "medium",
                    status: "completed",
                    usage: TokenUsage(
                        totalTokens: 18100,
                        promptTokens: 9800,
                        completionTokens: 8300,
                        cachedPromptTokens: 4500,
                        reasoningOutputTokens: 2400,
                        estimatedCreditsMicros: 10000
                    )
                )
            ],
            quotaBefore: [
                QuotaWindow(slot: "primary", usedPercent: 12.0, windowDurationMins: 5, resetsAt: Date().addingTimeInterval(180).timeIntervalSince1970),
                QuotaWindow(slot: "secondary", usedPercent: 34.0, windowDurationMins: 60, resetsAt: Date().addingTimeInterval(2400).timeIntervalSince1970)
            ],
            quotaChangeDuringRun: [
                QuotaWindow(slot: "primary", usedPercent: 18.0, windowDurationMins: 5, resetsAt: Date().addingTimeInterval(180).timeIntervalSince1970, deltaPercentagePoints: 6.0),
                QuotaWindow(slot: "secondary", usedPercent: 39.0, windowDurationMins: 60, resetsAt: Date().addingTimeInterval(2400).timeIntervalSince1970, deltaPercentagePoints: 5.0)
            ]
        )
    }
}

// MARK: - Analytics & Stats Data Models

public struct ModelStats: Identifiable {
    public var id: String { name }
    public var name: String
    public var calls: Int
    public var tokens: Int
    public var roles: [String]
    
    public init(name: String, calls: Int, tokens: Int, roles: [String]) {
        self.name = name
        self.calls = calls
        self.tokens = tokens
        self.roles = roles
    }
}

public struct ProjectStats: Identifiable {
    public var id: String { name }
    public var name: String
    public var runs: Int
    public var delegated: Int
    public var tokens: Int
    public var durationMs: Double
    
    public init(name: String, runs: Int, delegated: Int, tokens: Int, durationMs: Double) {
        self.name = name
        self.runs = runs
        self.delegated = delegated
        self.tokens = tokens
        self.durationMs = durationMs
    }
    
    public var formattedDuration: String {
        let secs = durationMs / 1000.0
        if secs < 60 {
            return String(format: "%.0fs", secs)
        } else if secs < 3600 {
            return String(format: "%.1fm", secs / 60.0)
        } else {
            return String(format: "%.1fh", secs / 3600.0)
        }
    }
}

public struct TelemetryStats {
    public var days: Int
    public var projectFilter: String?
    public var totalRuns: Int
    public var delegatedRuns: Int
    public var directRuns: Int
    public var totalDurationMs: Double
    public var totalTokens: Int
    public var parentTokens: Int
    public var workerTokens: Int
    public var cachedInputTokens: Int
    public var inputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int
    public var cacheRatio: Double
    public var workerOffloadRatio: Double
    public var estimatedCreditsMicros: Double?
    public var models: [ModelStats]
    public var projects: [ProjectStats]
    
    public init(
        days: Int = 30,
        projectFilter: String? = nil,
        totalRuns: Int = 0,
        delegatedRuns: Int = 0,
        directRuns: Int = 0,
        totalDurationMs: Double = 0,
        totalTokens: Int = 0,
        parentTokens: Int = 0,
        workerTokens: Int = 0,
        cachedInputTokens: Int = 0,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        cacheRatio: Double = 0,
        workerOffloadRatio: Double = 0,
        estimatedCreditsMicros: Double? = nil,
        models: [ModelStats] = [],
        projects: [ProjectStats] = []
    ) {
        self.days = days
        self.projectFilter = projectFilter
        self.totalRuns = totalRuns
        self.delegatedRuns = delegatedRuns
        self.directRuns = directRuns
        self.totalDurationMs = totalDurationMs
        self.totalTokens = totalTokens
        self.parentTokens = parentTokens
        self.workerTokens = workerTokens
        self.cachedInputTokens = cachedInputTokens
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.cacheRatio = cacheRatio
        self.workerOffloadRatio = workerOffloadRatio
        self.estimatedCreditsMicros = estimatedCreditsMicros
        self.models = models
        self.projects = projects
    }
    
    public var formattedTotalDuration: String {
        let secs = totalDurationMs / 1000.0
        if secs < 60 {
            return String(format: "%.0fs", secs)
        } else if secs < 3600 {
            return String(format: "%.1fm", secs / 60.0)
        } else {
            let hours = secs / 3600.0
            return String(format: "%.1fh", hours)
        }
    }
    
    public var formattedCost: String {
        if let micros = estimatedCreditsMicros, micros > 0 {
            return String(format: "$%.3f", micros / 1_000_000.0)
        }
        return "--"
    }
}
