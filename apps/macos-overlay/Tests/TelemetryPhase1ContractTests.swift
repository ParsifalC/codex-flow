import Foundation

func L(_ english: String, _ chinese: String) -> String { english }

@main
struct TelemetryPhase1ContractTests {
    static func main() {
        testAllocatedQuotaDeltaSeparation()
        testChatSessionAttributionStatus()
        testDailyUsageReadsSummarySnapshot()
        testCrossMidnightPendingProducesNilQuotaDelta()
        testMultiBucketDailyUsageSeparation()
        testMissingAccountIdentityYieldsNil()
        testExplicitMissingIdentityDoesNotUseCachedActiveAccount()
        testMissingBucketWithMultipleBucketsYieldsNil()
        print("Telemetry Phase 1 contract tests passed successfully!")
    }

    private static func testAllocatedQuotaDeltaSeparation() {
        let runWithoutAlloc = TaskRun(
            sessionId: "sess-1",
            turnId: "turn-1",
            status: "completed",
            quotaChangeDuringRun: [
                QuotaWindow(slot: "primary", usedPercent: 30.0, windowDurationMins: 10_080, deltaPercentagePoints: 24.0)
            ]
        )

        // Must strictly separate observed vs canonical
        precondition(runWithoutAlloc.observedAccountDelta == 24.0, "observedAccountDelta should be raw weekly delta")
        precondition(runWithoutAlloc.allocatedQuotaDelta == nil, "allocatedQuotaDelta should be nil")
        precondition(runWithoutAlloc.canonicalQuotaDelta == nil, "canonicalQuotaDelta MUST be nil when allocation missing, NO fallback to observedAccountDelta!")

        let runWithAlloc = TaskRun(
            sessionId: "sess-1",
            turnId: "turn-1",
            status: "completed",
            quotaChangeDuringRun: [
                QuotaWindow(slot: "primary", usedPercent: 30.0, windowDurationMins: 10_080, deltaPercentagePoints: 24.0)
            ],
            allocatedQuotaDelta: 17.5
        )

        precondition(runWithAlloc.observedAccountDelta == 24.0)
        precondition(runWithAlloc.allocatedQuotaDelta == 17.5)
        precondition(runWithAlloc.canonicalQuotaDelta == 17.5)
    }

    private static func testChatSessionAttributionStatus() {
        let runA = TaskRun(
            sessionId: "sess-partial",
            turnId: "turn-a",
            status: "completed",
            quotaChangeDuringRun: [
                QuotaWindow(slot: "primary", usedPercent: 5.0, windowDurationMins: 10_080, deltaPercentagePoints: 2.0)
            ],
            allocatedQuotaDelta: 2.0
        )
        let runB = TaskRun(
            sessionId: "sess-partial",
            turnId: "turn-b",
            status: "completed",
            quotaChangeDuringRun: [
                QuotaWindow(slot: "primary", usedPercent: 30.0, windowDurationMins: 10_080, deltaPercentagePoints: 24.0)
            ],
            allocatedQuotaDelta: nil // Missing allocation
        )

        let partialChat = ChatSession(
            sessionId: "sess-partial",
            projectName: "test-proj",
            title: "Partial chat",
            lastActiveAtMs: 1000,
            runs: [runA, runB]
        )

        precondition(partialChat.isPartiallyAttributed == true, "ChatSession should be partially attributed")
        precondition(partialChat.isFullyAttributed == false, "ChatSession should NOT be fully attributed")
        precondition(partialChat.totalQuotaDelta == 2.0, "totalQuotaDelta should sum only allocated runs")
        precondition(partialChat.observedAccountDelta == 26.0, "observedAccountDelta should sum raw deltas")

        let fullyAllocatedChat = ChatSession(
            sessionId: "sess-full",
            projectName: "test-proj",
            title: "Full chat",
            lastActiveAtMs: 1000,
            runs: [runA]
        )
        precondition(fullyAllocatedChat.isPartiallyAttributed == false)
        precondition(fullyAllocatedChat.isFullyAttributed == true)
        precondition(fullyAllocatedChat.totalQuotaDelta == 2.0)
    }

    private static func testDailyUsageReadsSummarySnapshot() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runsDir = tempDir.appendingPathComponent("runs")
        try! FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())

        let summaryURL = tempDir.appendingPathComponent("quota_summary.json")
        let summaryJSON = """
        {
            "revision": 42,
            "active_account_id": "acc-1",
            "exported_at_ms": 1788855500000,
            "timezone": "Asia/Shanghai",
            "cycle_summaries": [],
            "daily_usage": [
                {
                    "account_id": "acc-1",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 10.0,
                    "coverage_status": "complete",
                    "cross_midnight_pending_pp": 0.0,
                    "unattributed_pp": 0.0
                },
                {
                    "account_id": "acc-2",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 20.0,
                    "coverage_status": "complete",
                    "cross_midnight_pending_pp": 0.0,
                    "unattributed_pp": 0.0
                }
            ],
            "session_allocations": {}
        }
        """
        try! summaryJSON.write(to: summaryURL, atomically: true, encoding: .utf8)

        let engine = TelemetryQueryEngine(customRoot: tempDir)
        let summary = engine.loadQuotaSummary()
        precondition(summary != nil)
        precondition(summary?.revision == 42)
        precondition(summary?.activeAccountId == "acc-1")
        precondition(summary?.dailyUsage?.count == 2)

        // Both dimensions must be explicit, even when the summary has an active account.
        let dailyUsagesAcc1 = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-1", bucketId: "secondary")
        precondition(dailyUsagesAcc1.first?.quotaDelta == 10.0, "Should use explicit acc-1 secondary delta")

        // Explicit accountId and bucketId matching active account
        let dailyUsagesExplicitAcc1 = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-1", bucketId: "secondary")
        precondition(dailyUsagesExplicitAcc1.first?.quotaDelta == 10.0, "Should match explicit acc-1 delta")

        // Inconsistent accountId (caller asks for acc-2 while active is acc-1) MUST return nil (unknown)
        let dailyUsagesInconsistent = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-2", bucketId: "secondary")
        precondition(dailyUsagesInconsistent.first?.quotaDelta == nil, "Inconsistent accountId must return nil to prevent showing wrong/stale account data")
    }

    private static func testCrossMidnightPendingProducesNilQuotaDelta() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runsDir = tempDir.appendingPathComponent("runs")
        try! FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())

        let summaryURL = tempDir.appendingPathComponent("quota_summary.json")
        let summaryJSON = """
        {
            "revision": 43,
            "active_account_id": "acc-test",
            "exported_at_ms": 1788855500000,
            "daily_usage": [
                {
                    "account_id": "acc-test",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 0.0,
                    "cross_midnight_pending_pp": 10.0,
                    "coverage_status": "has_cross_midnight_pending"
                }
            ]
        }
        """
        try! summaryJSON.write(to: summaryURL, atomically: true, encoding: .utf8)

        let engine = TelemetryQueryEngine(customRoot: tempDir)
        let dailyUsages = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-test", bucketId: "secondary")
        let todayUsage = dailyUsages.first
        precondition(todayUsage?.quotaDelta == nil, "quotaDelta MUST be nil when has_cross_midnight_pending with 0 intraday delta")
        precondition(todayUsage?.crossMidnightPendingPp == 10.0, "crossMidnightPendingPp should be 10.0")
        precondition(todayUsage?.coverageStatus == "has_cross_midnight_pending")
    }

    private static func testMultiBucketDailyUsageSeparation() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runsDir = tempDir.appendingPathComponent("runs")
        try! FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())

        let summaryURL = tempDir.appendingPathComponent("quota_summary.json")
        let summaryJSON = """
        {
            "revision": 44,
            "active_account_id": "acc-1",
            "exported_at_ms": 1788855500000,
            "daily_usage": [
                {
                    "account_id": "acc-1",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 12.0,
                    "coverage_status": "complete",
                    "cross_midnight_pending_pp": 0.0
                },
                {
                    "account_id": "acc-1",
                    "bucket_id": "primary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 18.0,
                    "coverage_status": "complete",
                    "cross_midnight_pending_pp": 0.0
                }
            ]
        }
        """
        try! summaryJSON.write(to: summaryURL, atomically: true, encoding: .utf8)

        let engine = TelemetryQueryEngine(customRoot: tempDir)
        // Request secondary bucket explicitly
        let dailySec = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-1", bucketId: "secondary")
        precondition(dailySec.first?.quotaDelta == 12.0, "Should return secondary bucket delta 12.0")

        // Request primary bucket explicitly
        let dailyPri = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-1", bucketId: "primary")
        precondition(dailyPri.first?.quotaDelta == 18.0, "Should return primary bucket delta 18.0 without mixing or overwriting")
    }

    private static func testMissingAccountIdentityYieldsNil() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let runsDir = tempDir.appendingPathComponent("runs")
        try! FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())

        let summaryURL = tempDir.appendingPathComponent("quota_summary.json")
        // No active_account_id in summary
        let summaryJSON = """
        {
            "revision": 45,
            "active_account_id": null,
            "exported_at_ms": 1788855500000,
            "daily_usage": [
                {
                    "account_id": "acc-anon",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 10.0,
                    "coverage_status": "complete"
                }
            ]
        }
        """
        try! summaryJSON.write(to: summaryURL, atomically: true, encoding: .utf8)

        let engine = TelemetryQueryEngine(customRoot: tempDir)
        // No accountId provided, activeAccountId is null -> MUST NOT pick arbitrary account
        let dailyUsages = engine.computeDailyQuotaUsage(days: 1, accountId: nil, bucketId: "secondary")
        precondition(dailyUsages.first?.quotaDelta == nil, "Missing account identity must yield nil quotaDelta, NEVER arbitrary account data!")
    }

    private static func testExplicitMissingIdentityDoesNotUseCachedActiveAccount() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())
        let summaryJSON = """
        {
            "revision": 46,
            "active_account_id": "old-account",
            "daily_usage": [
                {
                    "account_id": "old-account",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 11.0,
                    "coverage_status": "complete"
                }
            ]
        }
        """
        try! summaryJSON.write(to: tempDir.appendingPathComponent("quota_summary.json"), atomically: true, encoding: .utf8)

        let engine = TelemetryQueryEngine(customRoot: tempDir)
        let nilIdentity = engine.computeDailyQuotaUsage(days: 1, accountId: nil, bucketId: "secondary")
        let blankIdentity = engine.computeDailyQuotaUsage(days: 1, accountId: " \t", bucketId: "secondary")
        precondition(nilIdentity.first?.quotaDelta == nil, "Nil snapshot identity must not use cached active account")
        precondition(blankIdentity.first?.quotaDelta == nil, "Blank snapshot identity must not use cached active account")
    }

    private static func testMissingBucketWithMultipleBucketsYieldsNil() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let todayFormatter = DateFormatter()
        todayFormatter.dateFormat = "yyyy-MM-dd"
        let todayStr = todayFormatter.string(from: Date())
        let summaryJSON = """
        {
            "revision": 47,
            "active_account_id": "acc-1",
            "daily_usage": [
                {
                    "account_id": "acc-1",
                    "bucket_id": "secondary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 11.0,
                    "coverage_status": "complete"
                },
                {
                    "account_id": "acc-1",
                    "bucket_id": "primary",
                    "date": "\(todayStr)",
                    "observed_delta_pp": 22.0,
                    "coverage_status": "complete"
                }
            ]
        }
        """
        try! summaryJSON.write(to: tempDir.appendingPathComponent("quota_summary.json"), atomically: true, encoding: .utf8)

        let engine = TelemetryQueryEngine(customRoot: tempDir)
        let nilBucket = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-1", bucketId: nil)
        let blankBucket = engine.computeDailyQuotaUsage(days: 1, accountId: "acc-1", bucketId: " \t")
        precondition(nilBucket.first?.quotaDelta == nil, "Missing bucket identity must not select secondary")
        precondition(blankBucket.first?.quotaDelta == nil, "Blank bucket identity must not select secondary")
    }
}
