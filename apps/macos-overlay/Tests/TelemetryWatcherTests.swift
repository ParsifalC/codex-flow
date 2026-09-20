import Foundation

func L(_ english: String, _ chinese: String) -> String { english }

public final class OverlayState {
    public struct Update {
        public let run: TaskRun
        public let notificationTriggered: Bool
        public let recovery: Bool
    }

    private let lock = NSLock()
    private var recordedUpdates: [Update] = []

    public var updates: [Update] {
        lock.lock()
        defer { lock.unlock() }
        return recordedUpdates
    }

    public func update(run: TaskRun, notificationTriggered: Bool = false, recovery: Bool = false) {
        lock.lock()
        recordedUpdates.append(Update(
            run: run,
            notificationTriggered: notificationTriggered,
            recovery: recovery
        ))
        lock.unlock()
    }
}

final class RecoveryCommandCapture {
    private let lock = NSLock()
    private var capturedCommand: TelemetryWatcher.RecoveryCommand?

    func record(_ command: TelemetryWatcher.RecoveryCommand) {
        lock.lock()
        capturedCommand = command
        lock.unlock()
    }

    var command: TelemetryWatcher.RecoveryCommand? {
        lock.lock()
        defer { lock.unlock() }
        return capturedCommand
    }
}

@main
struct TelemetryWatcherTests {
    static func main() throws {
        try testDoesNotCreateMissingTelemetryDirectory()
        try testRecoveryUsesInstalledBinDirectoryMetadata()
        try testRecoveryUsesInstalledTelemetryScriptAndPython()
        try testStartupRecoveryIsSilent()
        try testReadsWaitForRecovery()
        try testAtomicRenameRefreshesWithoutIPC()
        try testMissingDirectoryReattachesAndRefreshesWithoutIPC()
        print("Telemetry watcher integration tests passed")
    }

    private static func testDoesNotCreateMissingTelemetryDirectory() throws {
        let root = try temporaryRoot("watcher-no-dir")
        defer { try? FileManager.default.removeItem(at: root) }

        let telemetryURL = root
            .appendingPathComponent("codex-flow")
            .appendingPathComponent("telemetry")
            .appendingPathComponent("last.json")
        let state = OverlayState()
        let watcher = TelemetryWatcher(
            state: state,
            telemetryPath: telemetryURL.path,
            environment: [:],
            homeDirectory: root,
            snapshotLoader: decodeSnapshot,
            recoveryRunner: { _ in }
        )
        defer { watcher.stopWatching() }

        precondition(!FileManager.default.fileExists(atPath: telemetryURL.deletingLastPathComponent().path))
    }

    private static func testRecoveryUsesInstalledBinDirectoryMetadata() throws {
        let root = try temporaryRoot("watcher-recovery-bin")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex-home")
        let stateDirectory = codexHome.appendingPathComponent("codex-flow")
        let binDirectory = root.appendingPathComponent("active-bin")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let executable = binDirectory.appendingPathComponent("codex-flow")
        let invocationLog = root.appendingPathComponent("recovery-invocation.log")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$0\" \"$@\" \"$CODEX_HOME\" > '\(invocationLog.path)'\n"
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        try Data((binDirectory.path + "\n").utf8).write(to: stateDirectory.appendingPathComponent("bin_dir"))

        let environment = ["CODEX_HOME": codexHome.path]
        guard let command = TelemetryWatcher.resolveRecoveryCommand(
            environment: environment,
            homeDirectory: root
        ) else {
            throw TestError(message: "installed bin_dir metadata did not resolve")
        }
        precondition(command.executable.path == executable.path)
        precondition(command.arguments == ["telemetry", "recover-last", "--quiet"])

        let capture = RecoveryCommandCapture()
        let missingLast = root
            .appendingPathComponent("missing")
            .appendingPathComponent("telemetry")
            .appendingPathComponent("last.json")
        let watcher = TelemetryWatcher(
            state: OverlayState(),
            telemetryPath: missingLast.path,
            environment: environment,
            homeDirectory: root,
            snapshotLoader: decodeSnapshot,
            recoveryRunner: capture.record
        )
        defer { watcher.stopWatching() }
        precondition(waitUntil { capture.command != nil })
        precondition(capture.command?.executable.path == executable.path)
        precondition(capture.command?.arguments == ["telemetry", "recover-last", "--quiet"])

        let actualWatcher = TelemetryWatcher(
            state: OverlayState(),
            telemetryPath: missingLast.path,
            environment: environment,
            homeDirectory: root,
            snapshotLoader: decodeSnapshot
        )
        defer { actualWatcher.stopWatching() }
        precondition(waitUntil { FileManager.default.fileExists(atPath: invocationLog.path) })
        let invocation = try String(contentsOf: invocationLog, encoding: .utf8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
        precondition(invocation == [executable.path, "telemetry", "recover-last", "--quiet", codexHome.path])
    }

    private static func testRecoveryUsesInstalledTelemetryScriptAndPython() throws {
        let root = try temporaryRoot("watcher-recovery-python")
        defer { try? FileManager.default.removeItem(at: root) }

        let codexHome = root.appendingPathComponent("codex-home")
        let stateDirectory = codexHome.appendingPathComponent("codex-flow")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        let telemetry = stateDirectory.appendingPathComponent("telemetry.py")
        let python = root.appendingPathComponent("python3")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: telemetry)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: python)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: telemetry.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

        let environment = [
            "CODEX_HOME": codexHome.path,
            "CODEX_FLOW_PYTHON": python.path
        ]
        guard let command = TelemetryWatcher.resolveRecoveryCommand(
            environment: environment,
            homeDirectory: root
        ) else {
            throw TestError(message: "installed telemetry.py did not resolve")
        }
        precondition(command.executable.path == python.path)
        precondition(command.arguments == [telemetry.path, "recover-last", "--quiet"])
    }

    private static func testStartupRecoveryIsSilent() throws {
        let root = try temporaryRoot("watcher-startup")
        defer { try? FileManager.default.removeItem(at: root) }
        let telemetryDirectory = root.appendingPathComponent("telemetry")
        try FileManager.default.createDirectory(at: telemetryDirectory, withIntermediateDirectories: true)
        let lastURL = telemetryDirectory.appendingPathComponent("last.json")
        try encode(publishedRun(session: "startup", turn: "1", completedAt: 1), to: lastURL)

        let state = OverlayState()
        let watcher = TelemetryWatcher(
            state: state,
            telemetryPath: lastURL.path,
            environment: [:],
            homeDirectory: root,
            snapshotLoader: decodeSnapshot,
            recoveryRunner: { _ in }
        )
        defer { watcher.stopWatching() }

        precondition(waitUntil { state.updates.count >= 1 })
        guard let first = state.updates.first else {
            throw TestError(message: "startup recovery did not load last.json")
        }
        precondition(first.recovery)
        precondition(!first.notificationTriggered)
    }

    private static func testReadsWaitForRecovery() throws {
        let root = try temporaryRoot("watcher-recovery-barrier")
        defer { try? FileManager.default.removeItem(at: root) }
        let last = root.appendingPathComponent("last.json")
        try encode(publishedRun(session: "recovery", turn: "old", completedAt: 1), to: last)
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let state = OverlayState()
        let watcher = TelemetryWatcher(
            state: state, telemetryPath: last.path,
            environment: ["CODEX_FLOW_BIN": "/usr/bin/true"], homeDirectory: root,
            snapshotLoader: decodeSnapshot,
            recoveryRunner: { _ in started.signal(); release.wait() }
        )
        defer { watcher.stopWatching() }
        precondition(started.wait(timeout: .now() + 2) == .success)
        let restored = publishedRun(session: "recovery", turn: "new", completedAt: 2)
        try atomicReplace(restored, at: last)
        watcher.loadLatestData()
        watcher.checkAndReloadIfModified()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let prematureRead = !state.updates.isEmpty
        release.signal()
        precondition(!prematureRead, "Snapshot reads must wait for startup recovery")
        precondition(waitUntil { !state.updates.isEmpty })
        precondition(state.updates.first?.run.id == restored.id)
        precondition(state.updates.first?.recovery == true)
    }

    private static func testAtomicRenameRefreshesWithoutIPC() throws {
        let root = try temporaryRoot("watcher-atomic")
        defer { try? FileManager.default.removeItem(at: root) }
        let telemetryDirectory = root.appendingPathComponent("telemetry")
        try FileManager.default.createDirectory(at: telemetryDirectory, withIntermediateDirectories: true)
        let lastURL = telemetryDirectory.appendingPathComponent("last.json")
        try encode(publishedRun(session: "atomic", turn: "1", completedAt: 1), to: lastURL)

        let state = OverlayState()
        let watcher = TelemetryWatcher(
            state: state,
            telemetryPath: lastURL.path,
            environment: [:],
            homeDirectory: root,
            snapshotLoader: decodeSnapshot,
            recoveryRunner: { _ in }
        )
        defer { watcher.stopWatching() }
        precondition(waitUntil { state.updates.count >= 1 })

        let next = publishedRun(session: "atomic", turn: "2", completedAt: 2)
        try atomicReplace(next, at: lastURL)
        precondition(waitUntil { state.updates.contains { $0.run.id == next.id } })
    }

    private static func testMissingDirectoryReattachesAndRefreshesWithoutIPC() throws {
        let root = try temporaryRoot("watcher-missing-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        let telemetryDirectory = root.appendingPathComponent("nested/telemetry")
        let lastURL = telemetryDirectory.appendingPathComponent("last.json")
        let state = OverlayState()
        let watcher = TelemetryWatcher(
            state: state,
            telemetryPath: lastURL.path,
            environment: [:],
            homeDirectory: root,
            snapshotLoader: decodeSnapshot,
            recoveryRunner: { _ in }
        )
        defer { watcher.stopWatching() }

        precondition(!FileManager.default.fileExists(atPath: telemetryDirectory.path))
        try FileManager.default.createDirectory(at: telemetryDirectory, withIntermediateDirectories: true)
        let run = publishedRun(session: "missing-dir", turn: "1", completedAt: 3)
        try encode(run, to: lastURL)
        precondition(waitUntil { state.updates.contains { $0.run.id == run.id } })
    }

    private static func decodeSnapshot(_ url: URL) -> TaskRun? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaskRun.self, from: data)
    }

    private static func publishedRun(session: String, turn: String, completedAt: Double) -> TaskRun {
        TaskRun(
            sessionId: session,
            turnId: turn,
            finishedAtMs: completedAt,
            status: "completed",
            publication: PublicationInfo(revision: 1, completedAtMs: completedAt)
        )
    }

    private static func encode(_ run: TaskRun, to url: URL) throws {
        try JSONEncoder().encode(run).write(to: url, options: .atomic)
    }

    private static func atomicReplace(_ run: TaskRun, at url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".last-\(UUID().uuidString).json")
        try encode(run, to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    private static func temporaryRoot(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func waitUntil(
        timeout: TimeInterval = 3,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private struct TestError: Error {
        let message: String
    }
}
