import Foundation

/// The durable JSON written by the analysis backend. The native preview keeps
/// this model tolerant of fields added by the backend so a partially upgraded
/// installation can still show the turns it knows about.
public struct AnalysisSnapshot: Codable, Equatable {
    public var schemaVersion: Int
    public var sessionID: String?
    public var enabled: Bool
    public var sourceError: AnalysisSourceError?
    public var updatedAtMS: Int64?
    public var source: AnalysisSourceCoverage?
    public var usage: AnalysisUsage?
    public var turns: [AnalysisTurn]

    public init(
        schemaVersion: Int = 1,
        sessionID: String? = nil,
        enabled: Bool = true,
        sourceError: AnalysisSourceError? = nil,
        updatedAtMS: Int64? = nil,
        source: AnalysisSourceCoverage? = nil,
        usage: AnalysisUsage? = nil,
        turns: [AnalysisTurn] = []
    ) {
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.enabled = enabled
        self.sourceError = sourceError
        self.updatedAtMS = updatedAtMS
        self.source = source
        self.usage = usage
        self.turns = turns
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sessionID = "session_id"
        case enabled
        case sourceError = "source_error"
        case updatedAtMS = "updated_at_ms"
        case source
        case usage
        case turns
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        sessionID = try values.decodeIfPresent(String.self, forKey: .sessionID)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        sourceError = try values.decodeIfPresent(AnalysisSourceError.self, forKey: .sourceError)
        updatedAtMS = try values.decodeIfPresent(Int64.self, forKey: .updatedAtMS)
        source = try values.decodeIfPresent(AnalysisSourceCoverage.self, forKey: .source)
        usage = try values.decodeIfPresent(AnalysisUsage.self, forKey: .usage)
        turns = try values.decodeIfPresent([AnalysisTurn].self, forKey: .turns) ?? []
    }
}

public struct AnalysisSourceError: Codable, Equatable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AnalysisSourceCoverage: Codable, Equatable {
    public var status: String?
    public var truncated: Bool?
    public var lineCount: Int?
    public var parsedLines: Int?
    public var bytes: Int?
    public var lastOffset: Int?
    public var path: String?

    public init(
        status: String? = nil,
        truncated: Bool? = nil,
        lineCount: Int? = nil,
        parsedLines: Int? = nil,
        bytes: Int? = nil,
        lastOffset: Int? = nil,
        path: String? = nil
    ) {
        self.status = status
        self.truncated = truncated
        self.lineCount = lineCount
        self.parsedLines = parsedLines
        self.bytes = bytes
        self.lastOffset = lastOffset
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case truncated
        case lineCount = "line_count"
        case parsedLines = "parsed_lines"
        case bytes
        case lastOffset = "last_offset"
        case path
    }
}

public struct AnalysisUsage: Codable, Equatable {
    public var requirementCalls: Int
    public var summaryCalls: Int
    public var skillCalls: Int
    public var totalCalls: Int

    public init(
        requirementCalls: Int = 0,
        summaryCalls: Int = 0,
        skillCalls: Int = 0,
        totalCalls: Int = 0
    ) {
        self.requirementCalls = requirementCalls
        self.summaryCalls = summaryCalls
        self.skillCalls = skillCalls
        self.totalCalls = totalCalls
    }

    private enum CodingKeys: String, CodingKey {
        case requirementCalls = "requirement_calls"
        case summaryCalls = "summary_calls"
        case skillCalls = "skill_calls"
        case totalCalls = "total_calls"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requirementCalls = try values.decodeIfPresent(Int.self, forKey: .requirementCalls) ?? 0
        summaryCalls = try values.decodeIfPresent(Int.self, forKey: .summaryCalls) ?? 0
        skillCalls = try values.decodeIfPresent(Int.self, forKey: .skillCalls) ?? 0
        totalCalls = try values.decodeIfPresent(Int.self, forKey: .totalCalls) ??
            requirementCalls + summaryCalls + skillCalls
    }
}

public struct AnalysisModelCoverage: Codable, Equatable {
    public var inputChars: Int?
    public var inputTruncated: Bool?
    public var outputTokens: Int?

    public init(
        inputChars: Int? = nil,
        inputTruncated: Bool? = nil,
        outputTokens: Int? = nil
    ) {
        self.inputChars = inputChars
        self.inputTruncated = inputTruncated
        self.outputTokens = outputTokens
    }

    private enum CodingKeys: String, CodingKey {
        case inputChars = "input_chars"
        case inputTruncated = "input_truncated"
        case outputTokens = "output_tokens"
    }
}

public struct AnalysisJobState: Codable, Equatable {
    public var status: String
    public var text: String?
    public var revision: Int?
    public var jobID: String?
    public var error: String?
    public var caveats: [String]
    public var coverage: AnalysisModelCoverage?

    public init(
        status: String,
        text: String? = nil,
        revision: Int? = nil,
        jobID: String? = nil,
        error: String? = nil,
        caveats: [String] = [],
        coverage: AnalysisModelCoverage? = nil
    ) {
        self.status = status
        self.text = text
        self.revision = revision
        self.jobID = jobID
        self.error = error
        self.caveats = caveats
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case text
        case revision
        case jobID = "job_id"
        case error
        case caveats
        case coverage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "not_analyzed"
        text = try values.decodeIfPresent(String.self, forKey: .text)
        revision = try values.decodeIfPresent(Int.self, forKey: .revision)
        jobID = try values.decodeIfPresent(String.self, forKey: .jobID)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        caveats = try values.decodeIfPresent([String].self, forKey: .caveats) ?? []
        coverage = try values.decodeIfPresent(AnalysisModelCoverage.self, forKey: .coverage)
    }
}

public struct AnalysisSkill: Codable, Equatable, Identifiable {
    public var jobID: String?
    public var status: String
    public var name: String?
    public var description: String?
    public var markdown: String?
    public var error: String?
    public var caveats: [String]
    public var coverage: AnalysisModelCoverage?

    public var id: String { jobID ?? name ?? UUID().uuidString }

    public init(
        jobID: String? = nil,
        status: String,
        name: String? = nil,
        description: String? = nil,
        markdown: String? = nil,
        error: String? = nil,
        caveats: [String] = [],
        coverage: AnalysisModelCoverage? = nil
    ) {
        self.jobID = jobID
        self.status = status
        self.name = name
        self.description = description
        self.markdown = markdown
        self.error = error
        self.caveats = caveats
        self.coverage = coverage
    }

    private enum CodingKeys: String, CodingKey {
        case jobID = "job_id"
        case status
        case name
        case description
        case markdown
        case error
        case caveats
        case coverage
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try values.decodeIfPresent(String.self, forKey: .jobID)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "not_analyzed"
        name = try values.decodeIfPresent(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description)
        markdown = try values.decodeIfPresent(String.self, forKey: .markdown)
        error = try values.decodeIfPresent(String.self, forKey: .error)
        caveats = try values.decodeIfPresent([String].self, forKey: .caveats) ?? []
        coverage = try values.decodeIfPresent(AnalysisModelCoverage.self, forKey: .coverage)
    }
}

public struct AnalysisTurn: Codable, Equatable, Identifiable {
    public var turnID: String
    public var sequence: Int
    public var userText: String
    public var requirement: AnalysisJobState
    public var summary: AnalysisJobState
    public var originalResult: String?
    public var skills: [AnalysisSkill]

    public var id: String { turnID }

    public init(
        turnID: String,
        sequence: Int,
        userText: String,
        requirement: AnalysisJobState,
        summary: AnalysisJobState,
        originalResult: String?,
        skills: [AnalysisSkill]
    ) {
        self.turnID = turnID
        self.sequence = sequence
        self.userText = userText
        self.requirement = requirement
        self.summary = summary
        self.originalResult = originalResult
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey {
        case turnID = "turn_id"
        case sequence
        case userText = "user_text"
        case requirement
        case summary
        case originalResult = "original_result"
        case skills
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        turnID = try values.decode(String.self, forKey: .turnID)
        sequence = try values.decodeIfPresent(Int.self, forKey: .sequence) ?? 0
        userText = try values.decodeIfPresent(String.self, forKey: .userText) ?? ""
        requirement = try values.decodeIfPresent(AnalysisJobState.self, forKey: .requirement) ??
            AnalysisJobState(status: "not_analyzed")
        summary = try values.decodeIfPresent(AnalysisJobState.self, forKey: .summary) ??
            AnalysisJobState(status: "not_analyzed")
        originalResult = try values.decodeIfPresent(String.self, forKey: .originalResult)
        skills = try values.decodeIfPresent([AnalysisSkill].self, forKey: .skills) ?? []
    }
}

public enum AnalysisJobKind {
    case requirement
    case summary
    case skill
}

/// A presentation projection keeps selection and privacy state outside the
/// backend snapshot. This is what prevents a refreshed latest turn from
/// displacing an explicitly selected historical turn.
public struct ConversationAnalysisProjection {
    public private(set) var snapshot: AnalysisSnapshot
    public private(set) var selectedTurnID: String?
    public private(set) var privacyMode: Bool

    public init(snapshot: AnalysisSnapshot, privacyMode: Bool = false) {
        self.snapshot = snapshot
        self.privacyMode = privacyMode
        self.selectedTurnID = Self.latestTurn(in: snapshot.turns)?.turnID
    }

    public var turns: [AnalysisTurn] { snapshot.turns.sorted { lhs, rhs in
        lhs.sequence == rhs.sequence ? lhs.turnID < rhs.turnID : lhs.sequence < rhs.sequence
    } }

    public var selectedTurn: AnalysisTurn? {
        guard let selectedTurnID else { return nil }
        return snapshot.turns.first { $0.turnID == selectedTurnID }
    }

    public var latestTurnID: String? { Self.latestTurn(in: snapshot.turns)?.turnID }
    public var sourceError: AnalysisSourceError? { snapshot.sourceError }

    public var requirementText: String? {
        guard !privacyMode, let state = selectedTurn?.requirement,
              state.status == "succeeded" else { return nil }
        return Self.nonEmpty(state.text)
    }

    public var summaryText: String? {
        guard !privacyMode, let state = selectedTurn?.summary,
              state.status == "succeeded" else { return nil }
        return Self.nonEmpty(state.text)
    }

    public var originalResult: String? {
        guard !privacyMode else { return nil }
        return Self.nonEmpty(selectedTurn?.originalResult)
    }

    public var selectedSkill: AnalysisSkill? {
        guard let skills = selectedTurn?.skills, !skills.isEmpty else { return nil }
        return skills.last
    }

    public var currentTurnWaitingForFinal: Bool {
        guard let turn = selectedTurn else { return false }
        return turn.originalResult == nil && turn.summary.status != "succeeded"
    }

    public var historicalTurnNeedsAnalysis: Bool {
        guard let turn = selectedTurn else { return false }
        return Self.nonEmpty(turn.originalResult) != nil && turn.summary.status != "succeeded"
    }

    public var canExtractSkill: Bool {
        !privacyMode && snapshot.enabled && selectedTurn != nil
    }

    public var canExportSkill: Bool {
        guard !privacyMode, let skill = selectedSkill,
              skill.status == "succeeded" else { return false }
        return Self.nonEmpty(skill.markdown) != nil
    }

    public mutating func update(snapshot: AnalysisSnapshot) {
        self.snapshot = snapshot
        guard let selectedTurnID,
              snapshot.turns.contains(where: { $0.turnID == selectedTurnID }) else {
            self.selectedTurnID = Self.latestTurn(in: snapshot.turns)?.turnID
            return
        }
    }

    @discardableResult
    public mutating func select(turnID: String) -> Bool {
        guard snapshot.turns.contains(where: { $0.turnID == turnID }) else { return false }
        selectedTurnID = turnID
        return true
    }

    public mutating func selectLatest() {
        selectedTurnID = latestTurnID
    }

    public mutating func setPrivacyMode(_ enabled: Bool) {
        privacyMode = enabled
    }

    public func retryJobID(for kind: AnalysisJobKind) -> String? {
        let state: AnalysisJobState?
        switch kind {
        case .requirement: state = selectedTurn?.requirement
        case .summary: state = selectedTurn?.summary
        case .skill: return selectedSkill?.status == "failed" ? selectedSkill?.jobID : nil
        }
        guard state?.status == "failed" else { return nil }
        return state?.jobID
    }

    @discardableResult
    public func exportSkill(to url: URL) -> Bool {
        guard canExportSkill, let markdown = selectedSkill?.markdown else { return false }
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func latestTurn(in turns: [AnalysisTurn]) -> AnalysisTurn? {
        turns.max { lhs, rhs in
            lhs.sequence == rhs.sequence ? lhs.turnID < rhs.turnID : lhs.sequence < rhs.sequence
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }
}


public struct AnalysisSkillDraftState {
    public var text = ""
    private var sourceKey: String?
    public init() {}
    public mutating func load(skill: AnalysisSkill?) {
        let key = skill.map { ($0.jobID ?? "") + ":" + $0.status }
        guard key != sourceKey else { return }
        sourceKey = key
        text = skill?.status == "succeeded" ? (skill?.markdown ?? "") : ""
    }
}
