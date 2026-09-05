import Foundation

// TelemetryData.swift references the app localization helper in an unrelated
// display-only property. Keep this regression test isolated from UI/Combine.
func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryQueryEngineConcurrencyTests {
    private struct QuerySnapshot: Equatable {
        let runStems: [String]
        let chatSignatures: [String]
        let filteredRunStems: [String]
        let totalRuns: Int
        let delegatedRuns: Int
        let directRuns: Int
        let totalDurationMs: Double
        let totalTokens: Int
        let parentTokens: Int
        let workerTokens: Int
        let modelSignatures: [String]
        let projectSignatures: [String]
    }

    private final class FailureRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var messages: [String] = []

        func append(_ message: String) {
            lock.lock()
            messages.append(message)
            lock.unlock()
        }

        var firstMessage: String? {
            lock.lock()
            defer { lock.unlock() }
            return messages.first
        }
    }

    // DispatchQueue's @Sendable closure cannot prove that this intentionally
    // synchronized reference is safe, so keep the test's crossing explicit.
    private final class EngineBox: @unchecked Sendable {
        let engine: TelemetryQueryEngine

        init(_ engine: TelemetryQueryEngine) {
            self.engine = engine
        }
    }

    static func main() {
        testConcurrentQueriesRemainStable()
        print("Telemetry query engine concurrency regression tests passed")
    }

    private static func testConcurrentQueriesRemainStable() {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("telemetry-query-engine-\(UUID().uuidString)", isDirectory: true)
        let runsDirectory = root.appendingPathComponent("runs", isDirectory: true)

        do {
            try fileManager.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
            try writeTelemetryRuns(to: runsDirectory)
        } catch {
            preconditionFailure("unable to create telemetry fixtures: \(error)")
        }
        defer { try? fileManager.removeItem(at: root) }

        let engine = TelemetryQueryEngine(customRoot: root)
        let expected = makeSnapshot(engine: engine, project: "telemetry-alpha")

        precondition(expected.runStems.count == 12, "fixture should contain 12 runs")
        precondition(expected.chatSignatures.count == 4, "fixture should contain 4 chat sessions")
        precondition(expected.filteredRunStems.count == 6, "project filter should select 6 runs")
        precondition(expected.totalRuns == 12)
        precondition(expected.delegatedRuns == 4)
        precondition(expected.directRuns == 8)
        precondition(expected.totalDurationMs == 12_000)
        precondition(expected.totalTokens == 1_484)
        precondition(expected.parentTokens == 1_266)
        precondition(expected.workerTokens == 218)
        precondition(expected.modelSignatures == [
            "model-parent:12:1266:parent",
            "model-worker:4:218:worker",
        ])
        precondition(expected.projectSignatures == [
            "telemetry-beta:6:748:2",
            "telemetry-alpha:6:736:2",
        ])

        let engineBox = EngineBox(engine)
        let failures = FailureRecorder()
        let startGate = DispatchGroup()
        let workers = DispatchGroup()
        let workerCount = 8
        let iterations = 30

        startGate.enter()
        for workerIndex in 0..<workerCount {
            workers.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { workers.leave() }
                startGate.wait()

                for iteration in 0..<iterations {
                    let snapshot = makeSnapshot(
                        engine: engineBox.engine,
                        project: "telemetry-alpha"
                    )
                    if snapshot != expected {
                        failures.append(
                            "worker \(workerIndex), iteration \(iteration) returned an unstable result"
                        )
                        return
                    }
                }
            }
        }
        startGate.leave()
        workers.wait()

        precondition(
            failures.firstMessage == nil,
            failures.firstMessage ?? "concurrent telemetry query failed"
        )
    }

    private static func writeTelemetryRuns(to runsDirectory: URL) throws {
        let nowMs = Date().timeIntervalSince1970 * 1000
        let encoder = JSONEncoder()

        for index in 0..<12 {
            let parentTokens = 100 + index
            let workerTokens = 50 + index
            let sessionIndex = index / 3
            let project = index.isMultiple(of: 2) ? "telemetry-alpha" : "telemetry-beta"
            let workers: [ParticipantInfo]?
            if index.isMultiple(of: 3) {
                workers = [
                    ParticipantInfo(
                        agentId: "worker-\(index)",
                        name: "Worker \(index)",
                        agentType: "worker",
                        model: "model-worker",
                        status: "completed",
                        usage: TokenUsage(
                            totalTokens: workerTokens,
                            promptTokens: 30 + index,
                            completionTokens: 20
                        )
                    )
                ]
            } else {
                workers = nil
            }

            let run = TaskRun(
                sessionId: "session-\(sessionIndex)",
                turnId: "turn-\(index)",
                startedAtMs: nowMs - Double(12 - index) * 1000,
                finishedAtMs: nowMs - Double(11 - index) * 1000,
                status: "completed",
                thread: ThreadInfo(
                    name: "session-\(sessionIndex)",
                    preview: "stable telemetry run \(index)",
                    cwd: "/tmp/\(project)",
                    gitInfo: GitInfo(branch: "main")
                ),
                cwd: "/tmp/\(project)",
                summary: "stable telemetry run \(index)",
                parent: ParticipantInfo(
                    name: "Parent",
                    agentType: "orchestrator",
                    model: "model-parent",
                    status: "completed",
                    usage: TokenUsage(
                        totalTokens: parentTokens,
                        promptTokens: parentTokens - 20,
                        completionTokens: 20
                    )
                ),
                workers: workers
            )
            let data = try encoder.encode(run)
            let fileURL = runsDirectory.appendingPathComponent("run-\(index).json")
            try data.write(to: fileURL, options: .atomic)
        }
    }

    private static func makeSnapshot(
        engine: TelemetryQueryEngine,
        project: String
    ) -> QuerySnapshot {
        let runs = engine.loadAllRuns()
        let chats = engine.fetchChatHistory(limit: 0)
        let filteredRuns = engine.fetchHistory(limit: 0, project: project)
        let stats = engine.computeStats(days: 30)

        return QuerySnapshot(
            runStems: runs.map { $0.fileStem ?? "" },
            chatSignatures: chats.map { chat in
                "\(chat.sessionId):\(chat.runs.count):\(chat.latestRun?.fileStem ?? "")"
            },
            filteredRunStems: filteredRuns.map { $0.fileStem ?? "" },
            totalRuns: stats.totalRuns,
            delegatedRuns: stats.delegatedRuns,
            directRuns: stats.directRuns,
            totalDurationMs: stats.totalDurationMs,
            totalTokens: stats.totalTokens,
            parentTokens: stats.parentTokens,
            workerTokens: stats.workerTokens,
            modelSignatures: stats.models.map {
                "\($0.name):\($0.calls):\($0.tokens):\($0.roles.joined(separator: ","))"
            },
            projectSignatures: stats.projects.map {
                "\($0.name):\($0.runs):\($0.tokens):\($0.delegated)"
            }
        )
    }
}
