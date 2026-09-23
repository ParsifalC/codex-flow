import Foundation

@main
struct ConversationAnalysisTests {
    static func main() throws {
        testOverlayBindingUsesSessionAndTurn()
        testOverlayNavigationIncludesUnfinishedAnalysisTurn()
        try testOverlayKeepsSelectionAndScopesActions()
        testLatestSkillAndEditableDraft()
        testDecodeBackendSnapshotAndCaveats()
        testHistoricalSelectionDoesNotJumpWhenLatestTurnArrives()
        testPendingStateDoesNotExposeStaleCompletedText()
        testSourceErrorAndMissingSummaryStayVisible()
        testRetryAndSkillJobIDsAreProjected()
        try testPrivacyGuardsActionsAndExport()
        try testLaunchConfigurationRequiresExplicitAbsolutePaths()
        print("Conversation analysis projection and command guard tests passed")
    }

    private static func testOverlayBindingUsesSessionAndTurn() {
        let snapshot = decode(snapshotJSON)
        precondition(snapshot.projection(sessionID: "another-chat", turnID: "turn-2") == nil)
        precondition(snapshot.projection(sessionID: "session-a", turnID: "missing") == nil)
        precondition(snapshot.projection(sessionID: "session-a", turnID: "turn-1")?.selectedTurnID == "turn-1")
        let hidden = snapshot.projection(sessionID: "session-a", turnID: "turn-2", privacyMode: true)
        precondition(hidden?.requirementText == nil && hidden?.canExtractSkill == false)
    }

    private static func testOverlayNavigationIncludesUnfinishedAnalysisTurn() {
        var snapshot = decode(snapshotJSON)
        snapshot.turns[1].originalResult = nil
        let runs = snapshot.overlayRuns
        precondition(runs.count == 2)
        precondition(runs[1].isRunning && runs[1].startedAtMs == nil)
        precondition(runs[1].publication == nil, "analysis must not fabricate published telemetry")
        let order = Dictionary(uniqueKeysWithValues: runs.enumerated().map { ($0.element.id, $0.offset) })
        let navigation = TurnNavigation(runs: runs, selectedIdentity: runs[1].id,
            additionalVisibleIDs: Set(runs.map(\.id)), sourceOrder: order)
        precondition(navigation.runs.count == 2 && navigation.canMovePrevious)
        precondition(navigation.moved(by: -1).currentRun?.id == runs[0].id)
    }

    private static func testOverlayKeepsSelectionAndScopesActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-analysis-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previousHome = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: root)
        }
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        let view = root.appendingPathComponent("view.json")
        var snapshot = decode(snapshotJSON)
        try JSONEncoder().encode(snapshot).write(to: view)
        let runner = RecordingAnalysisRunner()
        let service = ConversationAnalysisService(configuration: AnalysisPreviewConfiguration(stateDirectory: root,
            analysisScript: view, pythonExecutable: URL(fileURLWithPath: "/usr/bin/true")), runner: runner)
        defer { service.stop() }
        let suite = "overlay-analysis-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OverlayState(readDefaults: defaults)
        state.attachAnalysis(service)
        waitUntil { state.selectedRun?.turnId == "turn-2" }
        state.moveTurn(by: -1)
        waitUntil { state.selectedRun?.turnId == "turn-1" }
        snapshot.turns.append(AnalysisTurn(turnID: "turn-3", sequence: 3, userText: "next",
            requirement: AnalysisJobState(status: "pending"), summary: AnalysisJobState(status: "not_analyzed"),
            originalResult: nil, skills: []))
        try JSONEncoder().encode(snapshot).write(to: view, options: .atomic)
        service.reloadNow()
        waitUntil { state.turnNavigation.runs.count == 3 }
        precondition(state.selectedRun?.turnId == "turn-1")
        precondition(!service.performForTurn("extract-skill", sessionID: "wrong", turnID: "turn-1"))
        precondition(runner.commands.isEmpty)
        precondition(service.performForTurn("extract-skill", sessionID: "session-a", turnID: "turn-1"))
        precondition(runner.commands.last?.last == "turn-1")
        state.isPrivacyMode = true
        precondition(!service.performForTurn("extract-skill", sessionID: "session-a", turnID: "turn-1"))
        let export = root.appendingPathComponent("SKILL.md")
        precondition(!service.exportDraft("edited", sessionID: "session-a", turnID: "turn-2", jobID: "job-skill-2", to: export))
        state.isPrivacyMode = false
        precondition(!service.exportDraft("edited", sessionID: "wrong", turnID: "turn-2", jobID: "job-skill-2", to: export))
        precondition(!service.exportDraft("edited", sessionID: "session-a", turnID: "turn-2", jobID: "stale", to: export))
        precondition(service.exportDraft("edited", sessionID: "session-a", turnID: "turn-2", jobID: "job-skill-2", to: export))
        let saved = try String(contentsOf: export, encoding: .utf8)
        precondition(saved == "edited")
        state.jumpToLive()
        waitUntil { state.selectedRun?.turnId == "turn-3" }
    }

    private static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        precondition(condition(), "asynchronous overlay state did not converge")
    }

    private static func testLatestSkillAndEditableDraft() {
        var snapshot = decode(snapshotJSON)
        snapshot.turns[1].originalResult = nil
        snapshot.turns[1].skills.append(AnalysisSkill(jobID: "latest", status: "failed"))
        let projection = ConversationAnalysisProjection(snapshot: snapshot)
        precondition(projection.canExtractSkill)
        precondition(projection.selectedSkill?.jobID == "latest")
        precondition(!projection.canExportSkill)
        precondition(projection.retryJobID(for: .skill) == "latest")
        var draft = AnalysisSkillDraftState()
        let skill = AnalysisSkill(jobID: "draft", status: "succeeded", markdown: "original")
        draft.load(skill: skill)
        draft.text = ""
        draft.load(skill: skill)
        precondition(draft.text.isEmpty, "refresh must preserve intentional clearing")
    }

    private static func testDecodeBackendSnapshotAndCaveats() {
        let snapshot = decode(snapshotJSON)
        precondition(snapshot.schemaVersion == 1)
        precondition(snapshot.sessionID == "session-a")
        precondition(snapshot.turns.count == 2)
        precondition(snapshot.turns[1].turnID == "turn-2")
        precondition(snapshot.turns[1].requirement.caveats == ["constraint is inferred"])
        precondition(snapshot.turns[1].summary.caveats.isEmpty)
        precondition(snapshot.turns[1].skills[0].caveats == ["tool evidence unavailable"])
    }

    private static func testHistoricalSelectionDoesNotJumpWhenLatestTurnArrives() {
        var projection = ConversationAnalysisProjection(snapshot: decode(snapshotJSON))
        precondition(projection.selectedTurnID == "turn-2", "initial selection should be latest")
        precondition(projection.select(turnID: "turn-1"))

        var refreshed = decode(snapshotJSON)
        refreshed.turns.append(AnalysisTurn(
            turnID: "turn-3",
            sequence: 3,
            userText: "new request",
            requirement: AnalysisJobState(status: "pending"),
            summary: AnalysisJobState(status: "not_analyzed"),
            originalResult: nil,
            skills: []
        ))
        projection.update(snapshot: refreshed)

        precondition(projection.selectedTurnID == "turn-1", "refresh must keep an explicit historical selection")
        precondition(projection.latestTurnID == "turn-3")
        projection.selectLatest()
        precondition(projection.selectedTurnID == "turn-3")
    }

    private static func testPendingStateDoesNotExposeStaleCompletedText() {
        var snapshot = decode(snapshotJSON)
        snapshot.turns[1].requirement = AnalysisJobState(
            status: "pending",
            text: "old completed requirement",
            jobID: "job-new"
        )
        let projection = ConversationAnalysisProjection(snapshot: snapshot)
        precondition(projection.requirementText == nil, "pending requirement must not look completed")
        precondition(projection.selectedTurn?.requirement.status == "pending")
    }

    private static func testSourceErrorAndMissingSummaryStayVisible() {
        var snapshot = decode(snapshotJSON)
        snapshot.sourceError = AnalysisSourceError(code: "partial_tail", message: "partial_tail")
        snapshot.turns[1].originalResult = nil
        snapshot.turns[1].summary = AnalysisJobState(status: "not_analyzed")
        let projection = ConversationAnalysisProjection(snapshot: snapshot)

        precondition(projection.sourceError?.code == "partial_tail")
        precondition(projection.summaryText == nil, "missing final must not invent a summary")
        precondition(projection.originalResult == nil)
    }

    private static func testRetryAndSkillJobIDsAreProjected() {
        let projection = ConversationAnalysisProjection(snapshot: decode(snapshotJSON))
        precondition(projection.retryJobID(for: .requirement) == "job-req-2")
        precondition(projection.retryJobID(for: .summary) == nil)
        precondition(projection.selectedSkill?.jobID == "job-skill-2")
        precondition(projection.canExtractSkill)
        precondition(projection.canExportSkill)
    }

    private static func testPrivacyGuardsActionsAndExport() throws {
        var projection = ConversationAnalysisProjection(snapshot: decode(snapshotJSON))
        projection.setPrivacyMode(true)
        precondition(projection.requirementText == nil)
        precondition(projection.summaryText == nil)
        precondition(projection.originalResult == nil)
        precondition(!projection.canExtractSkill)
        precondition(!projection.canExportSkill)
        precondition(projection.exportSkill(to: temporaryURL()) == false)
    }

    private static func testLaunchConfigurationRequiresExplicitAbsolutePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let script = root.appendingPathComponent("analysis.py")
        let python = root.appendingPathComponent("python3")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: state.appendingPathComponent("config.json"))
        try Data("#!/usr/bin/env python3\n".utf8).write(to: script)
        try Data().write(to: python)

        let configuration = AnalysisPreviewConfiguration(
            stateDirectory: state,
            analysisScript: script,
            pythonExecutable: python
        )
        let validated = try configuration.validated()
        precondition(validated.stateDirectory == state)
        do {
            _ = try AnalysisPreviewConfiguration(
                stateDirectory: URL(fileURLWithPath: "relative-state"),
                analysisScript: script,
                pythonExecutable: python
            ).validated()
            preconditionFailure("relative state paths must be rejected")
        } catch {
            // Expected validation failure.
        }
    }

    private static func decode(_ string: String) -> AnalysisSnapshot {
        do {
            return try JSONDecoder().decode(AnalysisSnapshot.self, from: Data(string.utf8))
        } catch {
            preconditionFailure("snapshot fixture must decode: \(error)")
        }
    }

    private static func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("analysis-privacy-\(UUID().uuidString).md")
    }

    private static let snapshotJSON = #"""
    {
      "schema_version": 1,
      "session_id": "session-a",
      "enabled": true,
      "source_error": null,
      "updated_at_ms": 100,
      "source": {"status": "complete", "truncated": false, "line_count": 8, "parsed_lines": 8},
      "usage": {"requirement_calls": 2, "summary_calls": 1, "skill_calls": 1, "total_calls": 4},
      "turns": [
        {
          "turn_id": "turn-1",
          "sequence": 1,
          "user_text": "older request",
          "requirement": {"status": "succeeded", "text": "Older need", "revision": 1, "job_id": "job-req-1", "error": null},
          "summary": {"status": "succeeded", "text": "Older summary", "job_id": "job-sum-1", "error": null},
          "original_result": "Older final",
          "skills": []
        },
        {
          "turn_id": "turn-2",
          "sequence": 2,
          "user_text": "new request",
          "requirement": {"status": "failed", "text": "Build a preview", "revision": 2, "job_id": "job-req-2", "error": "invalid_output", "caveats": ["constraint is inferred"]},
          "summary": {"status": "succeeded", "text": "The parent described the preview.", "job_id": "job-sum-2", "error": null},
          "original_result": "The parent described the preview.",
          "skills": [{"job_id": "job-skill-2", "status": "succeeded", "name": "preview-skill", "description": "Draft preview", "markdown": "# Preview Skill", "caveats": ["tool evidence unavailable"]}]
        }
      ]
    }
    """#
}

private final class RecordingAnalysisRunner: ConversationAnalysisCommandRunning {
    var commands: [[String]] = []
    func run(arguments: [String], completion: @escaping (Result<AnalysisCommandResult, Error>) -> Void) {
        commands.append(arguments)
        completion(.success(AnalysisCommandResult(exitCode: 0)))
    }
    func cancel() {}
}
