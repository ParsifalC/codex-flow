import Foundation

func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryWorkerTokenTests {
    static func main() {
        testSingleRunWithWorkers()
        testRunWithZeroWorkers()
        testChatSessionWorkerAggregation()
        print("Telemetry worker token regression tests passed")
    }

    private static func testSingleRunWithWorkers() {
        let parentUsage = TokenUsage(
            totalTokens: 1_500_000,
            promptTokens: 1_490_000,
            completionTokens: 10_000,
            cachedPromptTokens: 1_400_000,
            reasoningOutputTokens: 5_000
        )
        let parent = ParticipantInfo(
            agentId: "p-1",
            agentType: "parent",
            model: "gpt-5.6-sol",
            usageDelta: parentUsage
        )

        let workerUsage = TokenUsage(
            totalTokens: 500_000,
            promptTokens: 495_000,
            completionTokens: 5_000,
            cachedPromptTokens: 450_000,
            reasoningOutputTokens: 2_000
        )
        let worker1 = ParticipantInfo(
            agentId: "w-1",
            agentType: "worker-implementer",
            model: "gpt-5.6-luna",
            usage: workerUsage
        )

        let run = TaskRun(
            sessionId: "sess-1",
            turnId: "turn-1",
            status: "completed",
            parent: parent,
            workers: [worker1]
        )

        precondition(run.totalTokens == 2_000_000, "Total tokens should be 2.0M, got \(run.totalTokens)")
        precondition(run.workerTotalTokens == 500_000, "Worker tokens should be 500k, got \(run.workerTotalTokens)")
        precondition(run.parentTotalTokens == 1_500_000, "Parent tokens should be 1.5M, got \(run.parentTotalTokens)")
        precondition(run.formattedWorkerTokens == "500.0k", "Formatted worker tokens: \(run.formattedWorkerTokens)")
        precondition(abs(run.workerTokenShare - 0.25) < 0.001, "Worker share should be 25%")
        precondition(run.formattedWorkerSharePercent == "25.0%", "Worker share formatted should be 25.0%")
    }

    private static func testRunWithZeroWorkers() {
        let parentUsage = TokenUsage(
            totalTokens: 676_000,
            promptTokens: 670_000,
            completionTokens: 6_000
        )
        let parent = ParticipantInfo(
            agentId: "p-2",
            agentType: "parent",
            model: "gpt-5.6-sol",
            usageDelta: parentUsage
        )

        let run = TaskRun(
            sessionId: "sess-2",
            turnId: "turn-2",
            status: "completed",
            parent: parent,
            workers: []
        )

        precondition(run.totalTokens == 676_000)
        precondition(run.workerTotalTokens == 0)
        precondition(run.parentTotalTokens == 676_000)
        precondition(run.formattedWorkerTokens == "0")
        precondition(run.workerTokenShare == 0.0)
        precondition(run.formattedWorkerSharePercent == "0.0%")
    }

    private static func testChatSessionWorkerAggregation() {
        let parentUsage1 = TokenUsage(totalTokens: 8_000_000, promptTokens: 7_900_000, completionTokens: 100_000)
        let workerUsage1 = TokenUsage(totalTokens: 2_000_000, promptTokens: 1_950_000, completionTokens: 50_000)
        let run1 = TaskRun(
            sessionId: "sess-chat",
            turnId: "turn-c1",
            status: "completed",
            parent: ParticipantInfo(agentId: "p1", model: "gpt-5.6-sol", usageDelta: parentUsage1),
            workers: [ParticipantInfo(agentId: "w1", model: "gpt-5.6-luna", usage: workerUsage1)]
        )

        let parentUsage2 = TokenUsage(totalTokens: 10_000_000, promptTokens: 9_900_000, completionTokens: 100_000)
        let run2 = TaskRun(
            sessionId: "sess-chat",
            turnId: "turn-c2",
            status: "completed",
            parent: ParticipantInfo(agentId: "p2", model: "gpt-5.6-sol", usageDelta: parentUsage2),
            workers: []
        )

        let chat = ChatSession(
            sessionId: "sess-chat",
            projectName: "codex-flow",
            title: "Test Chat",
            runs: [run2, run1]
        )

        precondition(chat.totalTokens == 20_000_000, "Chat total tokens should be 20M, got \(chat.totalTokens)")
        precondition(chat.workerTotalTokens == 2_000_000, "Chat worker tokens should be 2M, got \(chat.workerTotalTokens)")
        precondition(chat.parentTotalTokens == 18_000_000, "Chat parent tokens should be 18M, got \(chat.parentTotalTokens)")
        precondition(chat.formattedWorkerTokens == "2.0M", "Chat formatted worker tokens should be 2.0M, got \(chat.formattedWorkerTokens)")
        precondition(abs(chat.workerTokenShare - 0.10) < 0.001, "Chat worker share should be 10%")
        precondition(chat.formattedWorkerSharePercent == "10.0%")
    }
}
