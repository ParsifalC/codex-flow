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
    public var id: String {
        if let aid = agentId, !aid.isEmpty { return aid }
        if let n = name, !n.isEmpty { return n }
        return generatedId
    }
    private var generatedId: String = UUID().uuidString
    public var agentId: String?
    public var name: String?
    public var agentType: String?
    public var model: String?
    public var reasoningEffort: String?
    public var status: String?
    public var conclusion: String?
    public var startedAtMs: Double?
    public var finishedAtMs: Double?
    public var usage: TokenUsage?
    public var usageDelta: TokenUsage?
    
    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case name
        case agentType = "agent_type"
        case model
        case reasoningEffort = "reasoning_effort"
        case status
        case conclusion
        case startedAtMs = "started_at_ms"
        case finishedAtMs = "finished_at_ms"
        case usage
        case usageDelta = "usage_delta"
    }
    
    public init(
        agentId: String? = nil,
        name: String? = nil,
        agentType: String? = nil,
        model: String? = nil,
        reasoningEffort: String? = nil,
        status: String? = nil,
        conclusion: String? = nil,
        startedAtMs: Double? = nil,
        finishedAtMs: Double? = nil,
        usage: TokenUsage? = nil,
        usageDelta: TokenUsage? = nil
    ) {
        self.agentId = agentId
        self.name = name
        self.agentType = agentType
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.status = status
        self.conclusion = conclusion
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
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

public struct DailyQuotaUsage: Identifiable {
    public var id: String { dateString }
    public let date: Date
    public let dateString: String
    public let displayDate: String
    public let quotaDelta: Double
    public let tokens: Int
    public let runs: Int

    public init(
        date: Date,
        dateString: String,
        displayDate: String,
        quotaDelta: Double,
        tokens: Int,
        runs: Int
    ) {
        self.date = date
        self.dateString = dateString
        self.displayDate = displayDate
        self.quotaDelta = quotaDelta
        self.tokens = tokens
        self.runs = runs
    }
}

public struct SkillUsage: Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var count: Int?
    
    public init(name: String, count: Int? = 1) {
        self.name = name
        self.count = count
    }
}

public struct ToolCallInfo: Codable, Identifiable {
    public var id: String { name }
    public var name: String
    public var count: Int?
    public var isMcp: Bool?
    public var category: String?
    
    enum CodingKeys: String, CodingKey {
        case name
        case count
        case isMcp = "is_mcp"
        case category
    }
    
    public init(name: String, count: Int? = 1, isMcp: Bool? = false, category: String? = nil) {
        self.name = name
        self.count = count
        self.isMcp = isMcp
        self.category = category
    }
    
    public var displayName: String {
        if isMcp == true {
            return name.replacingOccurrences(of: "mcp__", with: "")
        }
        return name
    }
}

public struct TrajectoryStep: Codable, Identifiable {
    public var id: String { callId ?? "\(type ?? "step")_\(timestamp ?? "")_\(title ?? "")" }
    public var type: String?
    public var name: String?
    public var title: String?
    public var detail: String?
    public var status: String?
    public var isMcp: Bool?
    public var callId: String?
    public var timestamp: String?
    public var durationMs: Int?
    
    enum CodingKeys: String, CodingKey {
        case type
        case name
        case title
        case detail
        case status
        case isMcp = "is_mcp"
        case callId = "call_id"
        case timestamp
        case durationMs = "duration_ms"
    }
    
    public init(
        type: String? = nil,
        name: String? = nil,
        title: String? = nil,
        detail: String? = nil,
        status: String? = nil,
        isMcp: Bool? = false,
        callId: String? = nil,
        timestamp: String? = nil,
        durationMs: Int? = nil
    ) {
        self.type = type
        self.name = name
        self.title = title
        self.detail = detail
        self.status = status
        self.isMcp = isMcp
        self.callId = callId
        self.timestamp = timestamp
        self.durationMs = durationMs
    }
}

public struct TaskLogEntry: Codable, Identifiable {
    public var id: String { "\(timestamp ?? "")_\(type ?? "")_\(message ?? "")" }
    public var timestamp: String?
    public var level: String?
    public var type: String?
    public var message: String?
    
    public init(timestamp: String? = nil, level: String? = nil, type: String? = nil, message: String? = nil) {
        self.timestamp = timestamp
        self.level = level
        self.type = type
        self.message = message
    }
}

public struct TaskSummaryInfo: Codable {
    public var goal: String?
    public var conclusion: String?
    
    public init(goal: String? = nil, conclusion: String? = nil) {
        self.goal = goal
        self.conclusion = conclusion
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
    public var quotaAfter: [QuotaWindow]?
    public var quotaChangeDuringRun: [QuotaWindow]?
    public var skillsUsed: [SkillUsage]?
    public var toolsUsed: [ToolCallInfo]?
    public var trajectory: [TrajectoryStep]?
    public var logs: [TaskLogEntry]?
    public var summaryInfo: TaskSummaryInfo?
    public var transcriptPath: String?
    
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
        case quotaAfter = "quota_after"
        case quotaChangeDuringRun = "quota_change_during_run"
        case skillsUsed = "skills_used"
        case toolsUsed = "tools_used"
        case trajectory
        case logs
        case summaryInfo = "summary_info"
        case transcriptPath = "transcript_path"
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
        quotaAfter = try container.decodeIfPresent([QuotaWindow].self, forKey: .quotaAfter)
        quotaChangeDuringRun = try container.decodeIfPresent([QuotaWindow].self, forKey: .quotaChangeDuringRun)
        skillsUsed = try container.decodeIfPresent([SkillUsage].self, forKey: .skillsUsed)
        toolsUsed = try container.decodeIfPresent([ToolCallInfo].self, forKey: .toolsUsed)
        trajectory = try container.decodeIfPresent([TrajectoryStep].self, forKey: .trajectory)
        logs = try container.decodeIfPresent([TaskLogEntry].self, forKey: .logs)
        summaryInfo = try container.decodeIfPresent(TaskSummaryInfo.self, forKey: .summaryInfo)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        
        if let dict = try? container.decode([String: ParticipantInfo].self, forKey: .workers) {
            var updatedDict: [String: ParticipantInfo] = [:]
            var list: [ParticipantInfo] = []
            for (key, var worker) in dict {
                if worker.agentId == nil || worker.agentId?.isEmpty == true {
                    worker.agentId = key
                }
                updatedDict[key] = worker
                list.append(worker)
            }
            list.sort {
                let s1 = $0.startedAtMs ?? 0
                let s2 = $1.startedAtMs ?? 0
                if s1 != s2 { return s1 < s2 }
                return ($0.agentId ?? $0.id) < ($1.agentId ?? $1.id)
            }
            workersDict = updatedDict
            workersList = list
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
        if let d = workersDict {
            try container.encode(d, forKey: .workers)
        } else if let l = workersList {
            try container.encode(l, forKey: .workers)
        }
        try container.encodeIfPresent(quotaBefore, forKey: .quotaBefore)
        try container.encodeIfPresent(quotaAfter, forKey: .quotaAfter)
        try container.encodeIfPresent(quotaChangeDuringRun, forKey: .quotaChangeDuringRun)
        try container.encodeIfPresent(skillsUsed, forKey: .skillsUsed)
        try container.encodeIfPresent(toolsUsed, forKey: .toolsUsed)
        try container.encodeIfPresent(trajectory, forKey: .trajectory)
        try container.encodeIfPresent(logs, forKey: .logs)
        try container.encodeIfPresent(summaryInfo, forKey: .summaryInfo)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
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
        quotaAfter: [QuotaWindow]? = nil,
        quotaChangeDuringRun: [QuotaWindow]? = nil,
        skillsUsed: [SkillUsage]? = nil,
        toolsUsed: [ToolCallInfo]? = nil,
        trajectory: [TrajectoryStep]? = nil,
        logs: [TaskLogEntry]? = nil,
        summaryInfo: TaskSummaryInfo? = nil,
        transcriptPath: String? = nil,
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
        self.quotaAfter = quotaAfter
        self.quotaChangeDuringRun = quotaChangeDuringRun
        self.skillsUsed = skillsUsed
        self.toolsUsed = toolsUsed
        self.trajectory = trajectory
        self.logs = logs
        self.summaryInfo = summaryInfo
        self.transcriptPath = transcriptPath
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
    
    public var effectiveGoal: String? {
        return summaryInfo?.goal ?? thread?.preview
    }
    
    public var effectiveConclusion: String? {
        return summaryInfo?.conclusion ?? summary
    }
    
    public var hasSkillsOrTools: Bool {
        return !(skillsUsed ?? []).isEmpty || !(toolsUsed ?? []).isEmpty
    }
    
    public var hasTrajectory: Bool {
        return !(trajectory ?? []).isEmpty
    }
    
    public var hasLogs: Bool {
        return !(logs ?? []).isEmpty
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
        if let list = workersList { return list }
        guard let dict = workersDict else { return [] }
        return Array(dict.values).sorted {
            let s1 = $0.startedAtMs ?? 0
            let s2 = $1.startedAtMs ?? 0
            if s1 != s2 { return s1 < s2 }
            return ($0.agentId ?? $0.id) < ($1.agentId ?? $1.id)
        }
    }
    
    public var effectiveQuotaWindows: [QuotaWindow] {
        if let current = quotaChangeDuringRun, !current.isEmpty {
            if current.contains(where: { $0.deltaPercentagePoints == nil }),
               let before = quotaBefore, !before.isEmpty {
                return current.map { w in
                    var window = w
                    if window.deltaPercentagePoints == nil {
                        let match = before.first(where: {
                            ($0.windowDurationMins != nil && $0.windowDurationMins == w.windowDurationMins) ||
                            ($0.slot != nil && $0.slot == w.slot)
                        })
                        if let afterUsed = w.usedPercent, let beforeUsed = match?.usedPercent {
                            window.deltaPercentagePoints = afterUsed - beforeUsed
                        }
                    }
                    return window
                }
            }
            return current
        }
        if let after = quotaAfter, !after.isEmpty {
            if let before = quotaBefore, !before.isEmpty {
                return after.map { w in
                    var window = w
                    if window.deltaPercentagePoints == nil {
                        let match = before.first(where: {
                            ($0.windowDurationMins != nil && $0.windowDurationMins == w.windowDurationMins) ||
                            ($0.slot != nil && $0.slot == w.slot)
                        })
                        if let afterUsed = w.usedPercent, let beforeUsed = match?.usedPercent {
                            window.deltaPercentagePoints = afterUsed - beforeUsed
                        }
                    }
                    return window
                }
            }
            return after
        }
        return quotaBefore ?? []
    }

    public static let shortQuotaWindowMinutes = 300
    public static let weeklyQuotaWindowMinutes = 10_080

    private func quotaWindow(durationMinutes: Int) -> QuotaWindow? {
        return effectiveQuotaWindows.first { $0.windowDurationMins == durationMinutes }
    }

    public var shortWindowQuotaDelta: Double? {
        return quotaWindow(durationMinutes: Self.shortQuotaWindowMinutes)?.deltaPercentagePoints
    }

    public var weeklyQuotaDelta: Double? {
        return quotaWindow(durationMinutes: Self.weeklyQuotaWindowMinutes)?.deltaPercentagePoints
    }

    /// Canonical quota movement used by task, project, model, chat and trend analytics.
    /// Never fall back to the short window: a 5h percentage point is not comparable
    /// with a weekly percentage point when account capacities differ.
    public var canonicalQuotaDelta: Double? {
        return weeklyQuotaDelta
    }
    
    /// Backward-compatible name used by existing analytics consumers. Its semantic
    /// value is now the canonical weekly quota delta, not the first/shortest window.
    public var primaryQuotaDelta: Double? {
        return canonicalQuotaDelta
    }

    public var shortWindowQuotaRemaining: Double? {
        return quotaWindow(durationMinutes: Self.shortQuotaWindowMinutes)?.remainingPercent
    }

    public var weeklyQuotaRemaining: Double? {
        return quotaWindow(durationMinutes: Self.weeklyQuotaWindowMinutes)?.remainingPercent
    }
    
    public var primaryQuotaRemaining: Double? {
        return shortWindowQuotaRemaining
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
                QuotaWindow(slot: "primary", usedPercent: 12.0, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(180).timeIntervalSince1970),
                QuotaWindow(slot: "secondary", usedPercent: 34.0, windowDurationMins: 10_080, resetsAt: Date().addingTimeInterval(2400).timeIntervalSince1970)
            ],
            quotaChangeDuringRun: [
                QuotaWindow(slot: "primary", usedPercent: 18.0, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(180).timeIntervalSince1970, deltaPercentagePoints: 6.0),
                QuotaWindow(slot: "secondary", usedPercent: 39.0, windowDurationMins: 10_080, resetsAt: Date().addingTimeInterval(2400).timeIntervalSince1970, deltaPercentagePoints: 5.0)
            ]
        )
    }
}

// MARK: - Chat Session Aggregate (Dimension 2: Chat)
public struct ChatSession: Identifiable {
    public var id: String { sessionId }
    public var sessionId: String
    public var projectName: String
    public var gitBranch: String?
    public var cwd: String?
    public var title: String
    public var summary: String?
    public var startedAtMs: Double?
    public var finishedAtMs: Double?
    public var lastActiveAtMs: Double
    public var runs: [TaskRun] // all session runs in this chat, sorted newest first
    
    public init(
        sessionId: String,
        projectName: String,
        gitBranch: String? = nil,
        cwd: String? = nil,
        title: String,
        summary: String? = nil,
        startedAtMs: Double? = nil,
        finishedAtMs: Double? = nil,
        lastActiveAtMs: Double? = nil,
        runs: [TaskRun] = []
    ) {
        self.sessionId = sessionId
        self.projectName = projectName
        self.gitBranch = gitBranch
        self.cwd = cwd
        self.title = title
        self.summary = summary
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
        self.lastActiveAtMs = lastActiveAtMs ?? finishedAtMs ?? startedAtMs ?? 0
        self.runs = runs
    }
    
    // MARK: - Aggregated Metrics
    
    public var totalRunsCount: Int {
        return runs.count
    }
    
    public var isRunning: Bool {
        return runs.contains { $0.isRunning }
    }
    
    public var isError: Bool {
        return runs.contains { $0.isError }
    }
    
    public var isSuccess: Bool {
        return !isRunning && !isError && !runs.isEmpty
    }
    
    public var totalDurationSeconds: Double {
        return runs.reduce(0.0) { $0 + $1.durationSeconds }
    }
    
    public var formattedDuration: String {
        let d = totalDurationSeconds
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
    
    public var aggregatedUsage: TokenUsage {
        var total = 0
        var prompt = 0
        var completion = 0
        var cached = 0
        var reasoning = 0
        var credits: Double = 0
        
        for run in runs {
            let u = run.aggregatedUsage
            total += u.totalTokens ?? 0
            prompt += u.effectivePromptTokens
            completion += u.effectiveOutputTokens
            cached += u.effectiveCachedTokens
            reasoning += u.effectiveReasoningTokens
            credits += u.estimatedCreditsMicros ?? 0
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
    
    public var totalTokens: Int {
        return aggregatedUsage.totalTokens ?? 0
    }
    
    public var formattedTotalTokens: String {
        return TaskRun.formatTokenCount(totalTokens)
    }
    
    public var formattedCost: String {
        if let creditsMicros = aggregatedUsage.estimatedCreditsMicros, creditsMicros > 0 {
            let dollars = creditsMicros / 1_000_000.0
            return String(format: "$%.3f", dollars)
        }
        return "--"
    }
    
    public var maxWorkerCount: Int {
        return runs.map { $0.allWorkers.count }.max() ?? 0
    }
    
    public var totalQuotaDelta: Double? {
        var total: Double = 0
        var hasDelta = false
        for r in runs {
            if let d = r.canonicalQuotaDelta {
                total += d
                hasDelta = true
            }
        }
        return hasDelta ? total : nil
    }
    
    public var totalWorkersCount: Int {
        return runs.reduce(0) { $0 + $1.allWorkers.count }
    }
    
    public var latestRun: TaskRun? {
        return runs.first
    }
    
    public var localizedFormattedDate: String {
        guard lastActiveAtMs > 0 else { return "--:--" }
        let date = Date(timeIntervalSince1970: lastActiveAtMs / 1000.0)
        let calendar = Calendar.current
        let formatter = DateFormatter()
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
            return L("Today \(formatter.string(from: date))", "今天 \(formatter.string(from: date))")
        } else {
            formatter.dateFormat = "MM-dd HH:mm"
            return formatter.string(from: date)
        }
    }
}

// MARK: - Analytics & Stats Data Models

public struct ModelStats: Identifiable {
    public var id: String { name }
    public var name: String
    public var calls: Int
    public var tokens: Int
    public var roles: [String]
    public var quotaDelta: Double?
    public var estimatedCost: Double?
    
    public init(
        name: String,
        calls: Int,
        tokens: Int,
        roles: [String],
        quotaDelta: Double? = nil,
        estimatedCost: Double? = nil
    ) {
        self.name = name
        self.calls = calls
        self.tokens = tokens
        self.roles = roles
        self.quotaDelta = quotaDelta
        self.estimatedCost = estimatedCost
    }
}

public struct ProjectStats: Identifiable {
    public var id: String { name }
    public var name: String
    public var runs: Int
    public var delegated: Int
    public var tokens: Int
    public var durationMs: Double
    public var quotaDelta: Double?
    public var estimatedCost: Double?
    
    public init(
        name: String,
        runs: Int,
        delegated: Int,
        tokens: Int,
        durationMs: Double,
        quotaDelta: Double? = nil,
        estimatedCost: Double? = nil
    ) {
        self.name = name
        self.runs = runs
        self.delegated = delegated
        self.tokens = tokens
        self.durationMs = durationMs
        self.quotaDelta = quotaDelta
        self.estimatedCost = estimatedCost
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