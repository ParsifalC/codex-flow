import Foundation

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
    public var completionTokens: Int?
    public var cachedPromptTokens: Int?
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    public var estimatedCreditsMicros: Double?
    
    enum CodingKeys: String, CodingKey {
        case totalTokens = "total_tokens"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case cachedPromptTokens = "cached_prompt_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case estimatedCreditsMicros = "estimated_credits_micros"
    }
    
    public init(
        totalTokens: Int? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        cacheReadInputTokens: Int? = nil,
        cacheCreationInputTokens: Int? = nil,
        estimatedCreditsMicros: Double? = nil
    ) {
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.estimatedCreditsMicros = estimatedCreditsMicros
    }
    
    public var effectiveCachedTokens: Int {
        if let c = cachedPromptTokens, c > 0 { return c }
        if let r = cacheReadInputTokens, r > 0 { return r }
        return 0
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

public struct TaskRun: Codable {
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
        workers: [ParticipantInfo]? = nil
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
        return thread?.preview ?? thread?.name ?? sessionId ?? "FlowPilot Task"
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
    
    public var allWorkers: [ParticipantInfo] {
        return workersList ?? (workersDict != nil ? Array(workersDict!.values) : [])
    }
    
    public var aggregatedUsage: TokenUsage {
        var total = 0
        var prompt = 0
        var completion = 0
        var cached = 0
        var credits: Double = 0
        
        let allParticipants = [parent].compactMap { $0 } + allWorkers
        for p in allParticipants {
            if let u = p.effectiveUsage {
                total += u.totalTokens ?? 0
                prompt += u.promptTokens ?? 0
                completion += u.completionTokens ?? 0
                cached += u.effectiveCachedTokens
                credits += u.estimatedCreditsMicros ?? 0
            }
        }
        
        return TokenUsage(
            totalTokens: total > 0 ? total : nil,
            promptTokens: prompt > 0 ? prompt : nil,
            completionTokens: completion > 0 ? completion : nil,
            cachedPromptTokens: cached > 0 ? cached : nil,
            estimatedCreditsMicros: credits > 0 ? credits : nil
        )
    }
    
    public var formattedTotalTokens: String {
        let count = aggregatedUsage.totalTokens ?? 0
        return TaskRun.formatTokenCount(count)
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
            summary: "成功实现 macOS 原生悬浮窗与 Summary UI，支持光标悬停 1 秒平滑弹性展开、动态环形指标与多 Agent 拓扑展示。",
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
                        estimatedCreditsMicros: 10000
                    )
                )
            ]
        )
    }
}
