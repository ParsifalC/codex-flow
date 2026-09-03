import Foundation

// TelemetryData.swift references the app localization helper in an unrelated
// display-only property. Keep this regression test isolated from UI/Combine.
func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryQuotaSelectionTests {
    static func main() {
        testCanonicalDeltaUsesWeeklyWindow()
        testWindowOrderDoesNotChangeSemantics()
        testMissingWeeklyWindowDoesNotFallBackToFiveHour()
        testRemainingMetricsStayExplicit()
        print("Telemetry quota selection regression tests passed")
    }

    private static func makeRun(_ windows: [QuotaWindow]) -> TaskRun {
        TaskRun(
            sessionId: "quota-test",
            turnId: UUID().uuidString,
            status: "completed",
            quotaChangeDuringRun: windows
        )
    }

    private static func testCanonicalDeltaUsesWeeklyWindow() {
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

        precondition(run.shortWindowQuotaDelta == 4.0)
        precondition(run.weeklyQuotaDelta == 0.8)
        precondition(run.canonicalQuotaDelta == 0.8)
        precondition(run.primaryQuotaDelta == 0.8)
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
        ])

        precondition(run.shortWindowQuotaDelta == 4.0)
        precondition(run.weeklyQuotaDelta == 0.8)
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
