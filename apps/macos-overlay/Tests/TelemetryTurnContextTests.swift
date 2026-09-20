import Foundation

func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryTurnContextTests {
    static func main() throws {
        try testPublishedSnapshotRoundTrips()
        try testLegacySnapshotRemainsReadableWithoutPublishedLabels()
        try testQueryExcludesUnpublishedNewRuns()
        testPublicationOrderingAndNotifications()
        print("Turn context model/query tests passed")
    }

    private static func testPublishedSnapshotRoundTrips() throws {
        let json = """
        {"schema_version":1,"session_id":"chat-a","turn_id":"turn-2",
         "publication_required":true,
         "turn_context":{"schema_version":1,"session_id":"chat-a","turn_id":"turn-2",
           "goal":{"text":"本轮目标","source":"flow-pilot","recorded_at_ms":100},
           "orchestration":{"origin":"compiled","revision":2,"execution_plan":{
             "schema_version":11,"strategy":"quality","worker_budget":{"max":3},
             "notes":["保留原始计划",{"nested":true}],"nullable":null}}},
         "result":{"text":"结果","source":"parent_final","turn_id":"turn-2","truncated":false},
         "publication":{"revision":1,"completed_at_ms":200}}
        """
        let run = try JSONDecoder().decode(TaskRun.self, from: Data(json.utf8))
        precondition(run.id == "chat-a--turn-2")
        precondition(run.turnContext?.goal?.text == "本轮目标")
        precondition(run.result?.source == "parent_final")
        precondition(run.publication?.revision == 1)
        precondition(run.publishedGoal == "本轮目标")
        precondition(run.publishedConclusion == "结果")
        let spacedJSON = json.replacingOccurrences(of: "\"结果\"", with: "\"  结果  \"")
        let spaced = try JSONDecoder().decode(TaskRun.self, from: Data(spacedJSON.utf8))
        precondition(spaced.publishedConclusion == "  结果  ", "Published result must preserve exact parent text")

        guard case let .object(plan)? = run.turnContext?.orchestration?.executionPlan,
              case let .array(notes)? = plan["notes"],
              case .object? = notes.last,
              case .null? = plan["nullable"] else {
            throw TestError("full execution plan JSON was not preserved")
        }

        let encoded = try JSONEncoder().encode(run)
        let decoded = try JSONDecoder().decode(TaskRun.self, from: encoded)
        precondition(decoded.turnContext?.orchestration?.revision == 2)
        precondition(decoded.publication?.completedAtMs == 200)
        precondition(decoded.id == run.id)
    }

    private static func testLegacySnapshotRemainsReadableWithoutPublishedLabels() throws {
        let json = """
        {"session_id":"legacy","turn_id":"turn-1","finished_at_ms":20,
         "summary_info":{"goal":"old transcript goal","conclusion":"old transcript conclusion"},
         "summary":"legacy summary"}
        """
        let run = try JSONDecoder().decode(TaskRun.self, from: Data(json.utf8))
        precondition(run.id == "legacy--turn-1")
        precondition(run.turnContext == nil)
        precondition(run.result == nil)
        precondition(run.publication == nil)
        precondition(run.publishedGoal == nil)
        precondition(run.publishedConclusion == nil)
    }

    private static func testQueryExcludesUnpublishedNewRuns() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-context-query-\(UUID().uuidString)", isDirectory: true)
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let encoder = JSONEncoder()
        let complete = TaskRun(
            sessionId: "published", turnId: "turn-1", finishedAtMs: 20,
            status: "completed",
            publication: PublicationInfo(revision: 1, completedAtMs: 20)
        )
        let pending = TaskRun(
            sessionId: "pending", turnId: "turn-2", startedAtMs: 30,
            status: "running", publicationRequired: true
        )
        try encoder.encode(complete).write(to: runs.appendingPathComponent("complete.json"))
        try encoder.encode(pending).write(to: runs.appendingPathComponent("pending.json"))
        let legacyRunning = TaskRun(sessionId: "legacy-running", turnId: "turn-1", startedAtMs: 40, status: "running")
        try encoder.encode(legacyRunning).write(to: runs.appendingPathComponent("legacy-running.json"))

        let engine = TelemetryQueryEngine(customRoot: root)
        precondition(engine.hasActiveRun())
        let loaded = engine.loadAllRuns()
        precondition(loaded.map(\.sessionId) == ["published"])
    }

    private static func testPublicationOrderingAndNotifications() {
        var gate = PublishedTurnGate()
        let first = TaskRun(sessionId: "chat", turnId: "1", finishedAtMs: 10, status: "completed", publication: PublicationInfo(revision: 1, completedAtMs: 10))
        let second = TaskRun(sessionId: "chat", turnId: "2", finishedAtMs: 20, status: "completed", publication: PublicationInfo(revision: 1, completedAtMs: 20))
        precondition(gate.accept(first, notify: false).refresh)
        precondition(gate.accept(first, notify: true).notify)
        precondition(!gate.accept(first, notify: true).notify)
        precondition(gate.accept(second, notify: true).refresh)
        precondition(!gate.accept(first, notify: false).refresh)
        var late = second
        late.publication = PublicationInfo(revision: 2, completedAtMs: 20)
        precondition(gate.accept(late, notify: true).refresh)
        precondition(!gate.accept(late, notify: true).notify)
        var startup = PublishedTurnGate()
        startup.seed(first)
        precondition(startup.accept(first, notify: true).notify)
        var raced = PublishedTurnGate()
        precondition(raced.accept(late, notify: false).refresh)
        precondition(raced.accept(late, notify: true).notify)
        precondition(!raced.accept(late, notify: true).notify)
        let older = raced.accept(first, notify: true)
        precondition(older.notify && !older.refresh)
        var legacy = PublishedTurnGate()
        let old = TaskRun(sessionId: "old", turnId: "old", finishedAtMs: 1)
        precondition(legacy.accept(old, notify: true).refresh)
        precondition(!legacy.accept(old, notify: true).notify)
    }

    private struct TestError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
