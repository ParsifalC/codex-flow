import AppKit
import Foundation

@main
struct OverlayTurnNavigationTests {
    static func main() {
        testRunsAreOrderedOldestToNewestAndBoundariesAreSafe()
        testEmptySingleAndLegacyTurns()
        testCompositeIdentitySelectsTheCorrectTurn()
        testStateKeepsSelectedTurnWhenHistoryRefreshes()
        print("Overlay turn navigation tests passed")
    }

    private static func testRunsAreOrderedOldestToNewestAndBoundariesAreSafe() {
        let newest = makeRun(session: "session-a", turn: "turn-3", finishedAt: 300)
        let oldest = makeRun(session: "session-a", turn: "turn-1", finishedAt: 100)
        let middle = makeRun(session: "session-a", turn: "turn-2", finishedAt: 200)
        let navigation = TurnNavigation(runs: [newest, oldest, middle], selectedIdentity: oldest.id)

        precondition(navigation.runs.map(\.id) == [oldest.id, middle.id, newest.id])
        precondition(navigation.currentRun?.id == oldest.id)
        precondition(!navigation.canMovePrevious)
        precondition(navigation.canMoveNext)
        precondition(navigation.moved(by: -1).currentRun?.id == oldest.id)
        precondition(navigation.moved(by: 1).currentRun?.id == middle.id)
        precondition(navigation.moved(by: 3).currentRun?.id == newest.id)
        precondition(navigation.moved(by: 3).canMoveNext == false)
    }

    private static func testEmptySingleAndLegacyTurns() {
        let empty = TurnNavigation(runs: [])
        precondition(empty.currentRun == nil && !empty.canMovePrevious && !empty.canMoveNext)
        precondition(empty.moved(by: 1).currentRun == nil)
        var legacy = makeRun(session: "legacy", turn: "old", finishedAt: 10)
        legacy.publication = nil
        let single = TurnNavigation(runs: [legacy], selectedIdentity: legacy.id)
        precondition(single.currentRun?.id == legacy.id, "Legacy history must remain navigable")
        precondition(!single.canMovePrevious && !single.canMoveNext)
        var pending = makeRun(session: "legacy", turn: "pending", finishedAt: 20)
        pending.publication = nil
        pending.publicationRequired = true
        let mixed = TurnNavigation(runs: [pending, legacy], selectedIdentity: legacy.id)
        precondition(mixed.runs.map(\.id) == [legacy.id], "Unpublished required records stay hidden")
    }

    private static func testCompositeIdentitySelectsTheCorrectTurn() {
        let sameTurnName = makeRun(session: "session-a", turn: "turn-1", finishedAt: 100)
        let differentSession = makeRun(session: "session-b", turn: "turn-1", finishedAt: 200)
        let navigation = TurnNavigation(
            runs: [sameTurnName, differentSession],
            selectedIdentity: sameTurnName.id
        )

        precondition(navigation.currentRun?.id == "session-a--turn-1")
        precondition(navigation.runs.count == 1)
    }

    private static func testStateKeepsSelectedTurnWhenHistoryRefreshes() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overlay-turn-state-\(UUID().uuidString)")
        let runsDirectory = root.appendingPathComponent("codex-flow/telemetry/runs")
        try! FileManager.default.createDirectory(at: runsDirectory, withIntermediateDirectories: true)
        let previousHome = getenv("CODEX_HOME").map { String(cString: $0) }
        setenv("CODEX_HOME", root.path, 1)
        defer {
            if let previousHome { setenv("CODEX_HOME", previousHome, 1) } else { unsetenv("CODEX_HOME") }
            try? FileManager.default.removeItem(at: root)
        }

        let old = makeRun(session: "session-a", turn: "turn-1", finishedAt: 100)
        let middle = makeRun(session: "session-a", turn: "turn-2", finishedAt: 200)
        let latest = makeRun(session: "session-a", turn: "turn-3", finishedAt: 300)
        let other = makeRun(session: "session-b", turn: "turn-1", finishedAt: 400)
        let otherLatest = makeRun(session: "session-b", turn: "turn-2", finishedAt: 500)
        // Older conversations must retain their full turn navigation even when
        // they fall outside the fifteen-item recent-conversation menu.
        let newerChats = (1...16).map { makeRun(session: "newer-\($0)", turn: "one", finishedAt: 1000 + Double($0)) }
        for run in [old, middle, latest, other, otherLatest] + newerChats {
            try! JSONEncoder().encode(run).write(to: runsDirectory.appendingPathComponent("\(run.id).json"))
        }

        let suite = "flowpilot-turn-state-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = OverlayState(readDefaults: defaults)
        state.update(run: latest, recovery: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        state.inspect(run: old)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))

        precondition(state.selectedRun?.id == old.id)
        precondition(state.turnNavigation.runs.map(\.id) == [old.id, middle.id, latest.id])
        state.moveTurn(by: 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.selectedRun?.id == middle.id)

        state.inspect(run: other)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(state.selectedRun?.id == other.id)
        precondition(state.turnNavigation.runs.map(\.id) == [other.id, otherLatest.id])
        state.jumpToLive()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(state.selectedRun?.id == latest.id)
        precondition(state.turnNavigation.runs.map(\.id) == [old.id, middle.id, latest.id])

        // last.json/IPC can reach the UI before the history directory catches up.
        let incoming = makeRun(session: "session-a", turn: "turn-4", finishedAt: 600)
        state.update(run: incoming, recovery: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        state.jumpToLive()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(state.selectedRun?.id == incoming.id)
        precondition(state.turnNavigation.currentRun?.id == incoming.id, "Footer must include the displayed snapshot even before its history file exists")
        precondition(state.turnNavigation.runs.count == 4)

        state.inspect(run: old)
        state.isExpanded = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let notification = makeRun(session: "session-b", turn: "turn-3", finishedAt: 700)
        state.update(run: notification, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(state.selectedRun?.id == old.id, "Completion notifications must not interrupt manual history browsing")
        precondition(state.hasUnreadResult, "The unseen completion must stay unread")
        state.selectTab(.inspector)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.hasUnreadResult, "Returning to an old turn must not acknowledge the new result")
        state.jumpToLive()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(state.selectedRun?.id == notification.id && !state.hasUnreadResult)

        state.inspect(run: old)
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let delayed = makeRun(session: "session-a", turn: "delayed", finishedAt: 650)
        state.update(run: delayed, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(state.selectedRun?.id == old.id)
        precondition(state.latestRun?.id == notification.id, "An older completion cannot replace latest")
        precondition(state.hasUnreadResult, "An out-of-order completion must retain an unread indication")
        state.collapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        precondition(state.hasUnreadResult, "Collapsing must not acknowledge a delayed completion")
        state.openLatest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.selectedRun?.id == delayed.id, "Opening the new-result bubble must show the unread delayed turn, even before its history file exists")
        precondition(!state.hasUnreadResult, "Opening the delayed result acknowledges it")
        precondition(state.latestRun?.id == notification.id, "Viewing an unread turn must not roll back latest")

        // Multiple arrivals must remain individually reachable and acknowledged.
        let delayedA = makeRun(session: "session-c", turn: "delayed-a", finishedAt: 610)
        let delayedB = makeRun(session: "session-d", turn: "delayed-b", finishedAt: 620)
        state.update(run: delayedB, notificationTriggered: true)
        state.update(run: delayedA, notificationTriggered: true)
        var revisedA = delayedA
        revisedA.publication = PublicationInfo(revision: 2, completedAtMs: delayedA.finishedAtMs)
        state.update(run: revisedA)
        state.update(run: delayedA, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        state.openLatest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.selectedRun?.id == delayedB.id && state.hasUnreadResult)
        state.collapse()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        state.openLatest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.selectedRun?.id == delayedA.id && !state.hasUnreadResult)
        precondition(state.selectedRun?.publicationRevision == 2, "Pending results retain late revisions without being downgraded by duplicate notifications")
        state.openLatest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(state.selectedRun?.id == notification.id, "Without unread results the bubble still opens latest")

        let cached = makeRun(session: "cached-chat", turn: "pending", finishedAt: 640)
        let anchor = makeRun(session: "cached-chat", turn: "anchor", finishedAt: 630)
        for run in [cached, anchor] {
            try! JSONEncoder().encode(run).write(to: runsDirectory.appendingPathComponent("\(run.id).json"))
        }
        state.inspect(run: anchor)
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        var revised = cached
        revised.publication = PublicationInfo(revision: 2, completedAtMs: cached.finishedAtMs)
        state.update(run: revised, notificationTriggered: true)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        state.openLatest()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(state.selectedRun?.id == cached.id && state.selectedRun?.publicationRevision == 2,
                     "Opening unread results must replace an older cached revision in the selected conversation")

        testHistoryFiltersIndividualTurns(state: state, directory: runsDirectory)
    }

    private static func testHistoryFiltersIndividualTurns(state: OverlayState, directory: URL) {
        let today = Date().timeIntervalSince1970 * 1000
        var older = makeRun(session: "filter-chat", turn: "older-match", finishedAt: today - 172_800_000)
        older.startedAtMs = today - 172_900_000
        older.turnContext = TurnContext(goal: TurnGoal(text: "unique-search-match"))
        older.cwd = "/tmp/filter-project"
        var current = makeRun(session: "filter-chat", turn: "current-other", finishedAt: today)
        current.startedAtMs = today - 1000
        current.cwd = older.cwd
        // A turn can start yesterday but finish today; filtering and ordering
        // must use its completion timestamp, like the query layer does.
        var overnight = makeRun(session: "filter-chat", turn: "overnight", finishedAt: today - 1)
        overnight.startedAtMs = older.startedAtMs
        overnight.cwd = older.cwd
        for run in [older, current, overnight] {
            try! JSONEncoder().encode(run).write(to: directory.appendingPathComponent("\(run.id).json"))
        }
        state.selectedProject = "filter-project"
        state.isTodayOnly = true
        state.loadHistory()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(state.historyRuns.map(\.id) == [current.id, overnight.id], "Today must filter individual turns, including overnight completions but excluding older turns in the same chat")
        state.isTodayOnly = false
        state.searchQuery = "unique-search-match"
        state.loadHistory()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(state.historyRuns.map(\.id) == [older.id], "Search must not include unrelated turns from a matching conversation")
        state.isTodayOnly = true
        state.loadHistory()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        precondition(state.historyRuns.isEmpty, "Today and search must both match the same turn")
    }

    private static func makeRun(session: String, turn: String, finishedAt: Double) -> TaskRun {
        TaskRun(
            sessionId: session,
            turnId: turn,
            finishedAtMs: finishedAt,
            status: "completed",
            publication: PublicationInfo(revision: 1, completedAtMs: finishedAt)
        )
    }
}
