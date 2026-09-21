import Foundation

// TelemetryData.swift references the app localization helper in an unrelated
// display-only property. Keep this regression test isolated from UI/Combine.
func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryQuotaSelectionTests {
    static func main() {
        testTaskMetrics()
        testTurnWeeklyEvidence()
        testUnknownWeeklyRemaining()
        testCanonicalDeltaUsesWeeklyWindow()
        testWindowOrderDoesNotChangeSemantics()
        testMissingWeeklyWindowDoesNotFallBackToFiveHour()
        testRemainingMetricsStayExplicit()
        testFallbackDeltaComputedFromBeforeAndAfter()
        testTranscriptQuotaEstimateIsExplicit()
        print("Telemetry quota selection regression tests passed")
    }

    private static func testTaskMetrics() {
        var run = TaskRun(sessionId: "metrics", turnId: "turn", status: "completed",
            parent: ParticipantInfo(usage: TokenUsage(totalTokens: 9999), usageDelta: TokenUsage(totalTokens: 300)),
            workers: [ParticipantInfo(usageDelta: TokenUsage(promptTokens: 60, completionTokens: 40))],
            quotaBefore: [QuotaWindow(usedPercent: 40, windowDurationMins: 10_080)],
            quotaAfter: [QuotaWindow(usedPercent: 46, windowDurationMins: 10_080)],
            allocatedQuotaDelta: 0.1234)
        let tokens = TurnTokenBreakdown(run: run)
        precondition(tokens.totalTokens == 400 && tokens.parentTokens == 300 && tokens.workerTokens == 100)
        precondition(tokens.parentShare == 0.75 && tokens.workerShare == 0.25, "Shares use turn deltas and include all workers")
        var quota = TurnWeeklyQuotaSummary(run: run)
        precondition(quota.displayConsumption == 0.1234 && !quota.usesObservedFallback, "Task attribution must win over account movement without losing precision")
        run.allocatedQuotaDelta = 0
        precondition(TurnWeeklyQuotaSummary(run: run).displayConsumption == 0, "Known zero is not missing attribution")
        run.allocatedQuotaDelta = nil
        quota = TurnWeeklyQuotaSummary(run: run)
        precondition(quota.displayConsumption == 6 && quota.usesObservedFallback)
        run.workersList = []
        precondition(TurnTokenBreakdown(run: run).parentShare == 1)
        run.parent = ParticipantInfo(usageDelta: TokenUsage(totalTokens: 0))
        precondition(TurnTokenBreakdown(run: run).parentShare == nil, "Zero usage has no percentage split")
        run.parent = nil
        precondition(TurnTokenBreakdown(run: run).totalTokens == nil, "Missing usage is not a measured zero")
    }

    private static func testTurnWeeklyEvidence() {
        var run = TaskRun(sessionId: "weekly", turnId: "turn", status: "completed",
            quotaBefore: [QuotaWindow(usedPercent: 40, windowDurationMins: 10_080, resetsAt: 100)],
            quotaAfter: [QuotaWindow(usedPercent: 46, windowDurationMins: 10_080, resetsAt: 100)],
            allocatedQuotaDelta: 2)
        var summary = TurnWeeklyQuotaSummary(run: run)
        precondition(summary.beforeRemaining == 60 && summary.afterRemaining == 54)
        precondition(summary.allocatedConsumption == 2 && summary.observedConsumption == 6)
        run.allocatedQuotaDelta = nil
        run.quotaAfter = nil
        summary = TurnWeeklyQuotaSummary(run: run)
        precondition(summary.beforeRemaining == 60 && summary.afterRemaining == nil)
        precondition(summary.allocatedConsumption == nil && summary.observedConsumption == nil)
        run.quotaAfter = [QuotaWindow(usedPercent: 5, windowDurationMins: 10_080, resetsAt: 200)]
        summary = TurnWeeklyQuotaSummary(run: run)
        precondition(summary.didReset && summary.observedConsumption == nil)
        run.quotaAfter = [QuotaWindow(usedPercent: 35, windowDurationMins: 10_080, resetsAt: 100)]
        run.quotaAfterSource = "transcript_estimate"
        summary = TurnWeeklyQuotaSummary(run: run)
        precondition(summary.observedConsumption == -5 && summary.isEstimated)
        run.quotaBefore = nil
        run.quotaAfter = [QuotaWindow(usedPercent: 35, windowDurationMins: 300)]
        summary = TurnWeeklyQuotaSummary(run: run)
        precondition(summary.beforeRemaining == nil && summary.afterRemaining == nil)
    }

    private static func testUnknownWeeklyRemaining() {
        let run = makeRun([QuotaWindow(windowDurationMins: 10_080)])
        precondition(run.weeklyQuotaRemaining == nil, "Missing usage must not appear as 100% remaining")
    }

    private static func testTranscriptQuotaEstimateIsExplicit() {
        let before = [
            QuotaWindow(slot: "primary", usedPercent: 0.0, windowDurationMins: 10_080)
        ]
        let after = [
            QuotaWindow(slot: "primary", usedPercent: 18.0, windowDurationMins: 10_080)
        ]
        let estimated = TaskRun(
            sessionId: "quota-test-transcript",
            turnId: UUID().uuidString,
            status: "completed",
            quotaBefore: before,
            quotaAfter: after,
            quotaAfterSource: "transcript_estimate"
        )

        precondition(estimated.isQuotaEstimated)
        precondition(estimated.observedAccountDelta == 18.0)
        precondition(estimated.canonicalQuotaDelta == nil)
    }

    private static func testFallbackDeltaComputedFromBeforeAndAfter() {
        let before = [
            QuotaWindow(slot: "primary", usedPercent: 20.0, windowDurationMins: 300),
            QuotaWindow(slot: "secondary", usedPercent: 40.0, windowDurationMins: 10_080)
        ]
        let after = [
            QuotaWindow(slot: "primary", usedPercent: 25.0, windowDurationMins: 300),
            QuotaWindow(slot: "secondary", usedPercent: 46.0, windowDurationMins: 10_080)
        ]
        let run = TaskRun(
            sessionId: "quota-test-fallback",
            turnId: UUID().uuidString,
            status: "completed",
            quotaBefore: before,
            quotaAfter: after
        )

        precondition(run.shortWindowQuotaDelta == 5.0)
        precondition(run.weeklyQuotaDelta == 6.0)
        precondition(run.observedAccountDelta == 6.0)
        // Contract 1: canonicalQuotaDelta strictly returns allocatedQuotaDelta; nil when missing
        precondition(run.canonicalQuotaDelta == nil)
        let weeklyWindow = run.effectiveQuotaWindows.first { $0.windowDurationMins == 10_080 }
        precondition(weeklyWindow?.deltaPercentagePoints == 6.0)

        // When allocation is provided, canonicalQuotaDelta returns it
        let runWithAlloc = TaskRun(
            sessionId: "quota-test-alloc",
            turnId: UUID().uuidString,
            status: "completed",
            quotaBefore: before,
            quotaAfter: after,
            allocatedQuotaDelta: 6.0
        )
        precondition(runWithAlloc.canonicalQuotaDelta == 6.0)
    }

    private static func makeRun(_ windows: [QuotaWindow], allocated: Double? = nil) -> TaskRun {
        TaskRun(
            sessionId: "quota-test",
            turnId: UUID().uuidString,
            status: "completed",
            quotaChangeDuringRun: windows,
            allocatedQuotaDelta: allocated
        )
    }

    private static func testCanonicalDeltaUsesWeeklyWindow() {
        let runWithoutAlloc = makeRun([
            QuotaWindow(
                slot: "primary",
                usedPercent: 24.0,
                windowDurationMins: 300,
                deltaPercentagePoints: 4.0
            ),
            QuotaWindow(
                slot: "secondary",
                usedPercent: 40.8,
                windowDurationMins: 10_080,
                deltaPercentagePoints: 0.8
            ),
        ])

        precondition(runWithoutAlloc.shortWindowQuotaDelta == 4.0)
        precondition(runWithoutAlloc.weeklyQuotaDelta == 0.8)
        precondition(runWithoutAlloc.observedAccountDelta == 0.8)
        // Missing allocation strictly returns nil, never falls back to 0.8
        precondition(runWithoutAlloc.canonicalQuotaDelta == nil)

        // With allocation
        let runWithAlloc = makeRun([
            QuotaWindow(
                slot: "secondary",
                usedPercent: 40.8,
                windowDurationMins: 10_080,
                deltaPercentagePoints: 0.8
            ),
        ], allocated: 0.8)
        precondition(runWithAlloc.canonicalQuotaDelta == 0.8)
    }

    private static func testWindowOrderDoesNotChangeSemantics() {
        let run = makeRun([
            QuotaWindow(
                slot: "secondary",
                usedPercent: 40.8,
                windowDurationMins: 10_080,
                deltaPercentagePoints: 0.8
            ),
            QuotaWindow(
                slot: "primary",
                usedPercent: 24.0,
                windowDurationMins: 300,
                deltaPercentagePoints: 4.0
            ),
        ], allocated: 0.8)

        precondition(run.shortWindowQuotaDelta == 4.0)
        precondition(run.weeklyQuotaDelta == 0.8)
        precondition(run.observedAccountDelta == 0.8)
        precondition(run.canonicalQuotaDelta == 0.8)
    }

    private static func testMissingWeeklyWindowDoesNotFallBackToFiveHour() {
        let run = makeRun([
            QuotaWindow(
                slot: "primary",
                usedPercent: 24.0,
                windowDurationMins: 300,
                deltaPercentagePoints: 4.0
            ),
        ])

        precondition(run.shortWindowQuotaDelta == 4.0)
        precondition(run.weeklyQuotaDelta == nil)
        precondition(run.canonicalQuotaDelta == nil)
        precondition(run.primaryQuotaDelta == nil)
    }

    private static func testRemainingMetricsStayExplicit() {
        let run = makeRun([
            QuotaWindow(
                slot: "primary",
                usedPercent: 24.0,
                windowDurationMins: 300,
                deltaPercentagePoints: 4.0
            ),
            QuotaWindow(
                slot: "secondary",
                usedPercent: 40.8,
                windowDurationMins: 10_080,
                deltaPercentagePoints: 0.8
            ),
        ])

        precondition(run.shortWindowQuotaRemaining == 76.0)
        precondition(run.weeklyQuotaRemaining == 59.2)
        // Preserve the legacy UI meaning of primary remaining as the short window.
        precondition(run.primaryQuotaRemaining == 76.0)
    }
}
