import Foundation

#if canImport(Darwin)
import Darwin
#endif

public final class TelemetryWatcher {
    public struct RecoveryCommand {
        public let executable: URL
        public let arguments: [String]

        public init(executable: URL, arguments: [String]) {
            self.executable = executable
            self.arguments = arguments
        }
    }

    public typealias SnapshotLoader = (URL) -> TaskRun?
    public typealias RecoveryRunner = (RecoveryCommand) -> Void

    public let state: OverlayState

    private let telemetryURL: URL
    private let dirURL: URL
    private let environment: [String: String]
    private let homeDirectory: URL
    private let snapshotLoader: SnapshotLoader
    private let recoveryRunner: RecoveryRunner

    // All DispatchSource handles and their bookkeeping live on this queue.
    // Filesystem event callbacks never mutate watcher state from their source
    // queue or from the main thread.
    private let watcherQueue = DispatchQueue(label: "com.parsifalc.codex-flow.telemetry-watcher", qos: .utility)
    private let watcherQueueKey = DispatchSpecificKey<Void>()
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileSourceURL: URL?
    private var dirSource: DispatchSourceFileSystemObject?
    private var watchedDirectoryURL: URL?
    private var pendingReload: DispatchWorkItem?
    private var lastModifiedTime: Date = .distantPast
    private var recoveryComplete = false

    public init(
        state: OverlayState,
        telemetryPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        snapshotLoader: SnapshotLoader? = nil,
        recoveryRunner: RecoveryRunner? = nil
    ) {
        self.state = state
        self.environment = environment
        self.homeDirectory = homeDirectory

        if let path = telemetryPath {
            self.telemetryURL = URL(fileURLWithPath: path)
            self.dirURL = self.telemetryURL.deletingLastPathComponent()
        } else {
            let codexHome = environment["CODEX_HOME"] ?? homeDirectory.appendingPathComponent(".codex").path
            self.dirURL = URL(fileURLWithPath: codexHome)
                .appendingPathComponent("codex-flow")
                .appendingPathComponent("telemetry")
            self.telemetryURL = self.dirURL.appendingPathComponent("last.json")
        }

        self.snapshotLoader = snapshotLoader ?? Self.decodeSnapshot
        self.recoveryRunner = recoveryRunner ?? { command in
            Self.runRecovery(command, environment: environment)
        }
        watcherQueue.setSpecific(key: watcherQueueKey, value: ())

        // Recovery is best effort and silent. The first snapshot it reads is
        // marked as recovered so a later IPC hint cannot re-notify it.
        recoverLastThenLoad()
        startWatching()
    }

    deinit {
        stopWatching()
    }

    /// Starts passive, kernel-driven file and directory monitoring without
    /// creating telemetry state when telemetry is disabled or not installed.
    public func startWatching() {
        runOnWatcherQueueSync { [self] in
            startWatchingOnQueue()
        }
    }

    public func stopWatching() {
        runOnWatcherQueueSync { [self] in
            stopWatchingOnQueue()
        }
    }

    public func checkAndReloadIfModified() {
        runOnWatcherQueueSync { [self] in
            checkAndReloadIfModifiedOnQueue(force: false)
        }
    }

    public func loadLatestData() {
        runOnWatcherQueueAsync { [self] in
            loadLatestDataOnQueue()
        }
    }

    private func startWatchingOnQueue() {
        configureDirectorySourceOnQueue()
        configureFileSourceOnQueue()
    }

    private func stopWatchingOnQueue() {
        pendingReload?.cancel()
        pendingReload = nil

        fileSource?.cancel()
        fileSource = nil
        fileSourceURL = nil

        dirSource?.cancel()
        dirSource = nil
        watchedDirectoryURL = nil
    }

    private func configureDirectorySourceOnQueue() {
        let desiredURL = directoryToWatchOnQueue().standardizedFileURL
        if watchedDirectoryURL?.standardizedFileURL == desiredURL,
           dirSource != nil {
            return
        }

        dirSource?.cancel()
        dirSource = nil
        watchedDirectoryURL = nil

        let directoryFD = open(desiredURL.path, O_EVTONLY)
        guard directoryFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: directoryFD,
            eventMask: [.write, .extend, .attrib, .link, .rename, .delete],
            queue: watcherQueue
        )
        source.setEventHandler { [weak self] in
            self?.handleFileOrDirectoryChangedOnQueue()
        }
        source.setCancelHandler {
            close(directoryFD)
        }
        watchedDirectoryURL = desiredURL
        dirSource = source
        source.resume()
    }

    private func configureFileSourceOnQueue() {
        let fileExists = FileManager.default.fileExists(atPath: telemetryURL.path)
        if !fileExists {
            fileSource?.cancel()
            fileSource = nil
            fileSourceURL = nil
            return
        }
        if fileSourceURL?.standardizedFileURL == telemetryURL.standardizedFileURL,
           fileSource != nil {
            return
        }

        fileSource?.cancel()
        fileSource = nil
        fileSourceURL = nil

        let fileFD = open(telemetryURL.path, O_EVTONLY)
        guard fileFD >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: watcherQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let eventData = source.data
            if eventData.contains(.delete) || eventData.contains(.rename) {
                self.fileSource?.cancel()
                self.fileSource = nil
                self.fileSourceURL = nil
            }
            self.handleFileOrDirectoryChangedOnQueue()
        }
        source.setCancelHandler {
            close(fileFD)
        }
        fileSourceURL = telemetryURL
        fileSource = source
        source.resume()
    }

    private func handleFileOrDirectoryChangedOnQueue() {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.checkAndReloadIfModifiedOnQueue(force: true)
            self.configureDirectorySourceOnQueue()
            self.configureFileSourceOnQueue()
            self.pendingReload = nil
        }
        pendingReload = work
        watcherQueue.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func checkAndReloadIfModifiedOnQueue(force: Bool) {
        guard recoveryComplete else { return }
        guard FileManager.default.fileExists(atPath: telemetryURL.path) else {
            configureDirectorySourceOnQueue()
            configureFileSourceOnQueue()
            return
        }

        if !force {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: telemetryURL.path),
                  let modificationDate = attributes[.modificationDate] as? Date,
                  modificationDate > lastModifiedTime else {
                return
            }
            lastModifiedTime = modificationDate
        } else if let attributes = try? FileManager.default.attributesOfItem(atPath: telemetryURL.path),
                  let modificationDate = attributes[.modificationDate] as? Date {
            lastModifiedTime = max(lastModifiedTime, modificationDate)
        }

        loadLatestDataOnQueue()
    }

    private func loadLatestDataOnQueue() {
        guard recoveryComplete else { return }
        let url = telemetryURL
        let loader = snapshotLoader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self,
                  let run = loader(url),
                  run.publication != nil else {
                return
            }
            DispatchQueue.main.async {
                self.state.update(run: run)
            }
        }
    }

    private func recoverLastThenLoad() {
        let loader = snapshotLoader
        let url = telemetryURL
        let runner = recoveryRunner
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            self.recoverLastSnapshot(using: runner)
            self.watcherQueue.async {
                // Reads triggered during recovery are deferred. Read once after
                // recovery, then release queued filesystem/manual refreshes.
                if let run = loader(url), run.publication != nil {
                    DispatchQueue.main.async {
                        self.state.update(run: run, notificationTriggered: false, recovery: true)
                    }
                }
                self.recoveryComplete = true
            }
        }
    }

    private func recoverLastSnapshot(using runner: RecoveryRunner) {
        guard let command = Self.resolveRecoveryCommand(
            environment: environment,
            homeDirectory: homeDirectory
        ) else {
            return
        }
        runner(command)
    }

    private func directoryToWatchOnQueue() -> URL {
        if isDirectory(dirURL) {
            return dirURL
        }

        var candidate = dirURL
        while !isDirectory(candidate) {
            let parent = candidate.deletingLastPathComponent()
            if parent == candidate {
                return candidate
            }
            candidate = parent
        }
        return candidate
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func runOnWatcherQueueSync(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: watcherQueueKey) != nil {
            work()
        } else {
            watcherQueue.sync(execute: work)
        }
    }

    private func runOnWatcherQueueAsync(_ work: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: watcherQueueKey) != nil {
            work()
        } else {
            watcherQueue.async(execute: work)
        }
    }

    private static func decodeSnapshot(_ url: URL) -> TaskRun? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TaskRun.self, from: data)
    }

    private static func runRecovery(_ command: RecoveryCommand, environment: [String: String]) {
        let process = Process()
        process.environment = environment
        process.executableURL = command.executable
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Recovery is best effort; the watcher still reads last.json.
        }
    }

    static func resolveRecoveryCommand(
        environment: [String: String],
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> RecoveryCommand? {
        let codexHomePath = environment["CODEX_HOME"]
            ?? homeDirectory.appendingPathComponent(".codex").path
        let stateDirectory = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("codex-flow")

        if let explicit = nonBlank(environment["CODEX_FLOW_BIN"]) {
            let executable = URL(fileURLWithPath: explicit)
            if fileManager.isExecutableFile(atPath: executable.path) {
                return RecoveryCommand(
                    executable: executable,
                    arguments: ["telemetry", "recover-last", "--quiet"]
                )
            }
        }

        let metadataURL = stateDirectory.appendingPathComponent("bin_dir")
        if let metadata = try? String(contentsOf: metadataURL, encoding: .utf8),
           let binDirectory = nonBlank(metadata),
           binDirectory.hasPrefix("/") {
            let executable = URL(fileURLWithPath: binDirectory)
                .appendingPathComponent("codex-flow")
            if fileManager.isExecutableFile(atPath: executable.path) {
                return RecoveryCommand(
                    executable: executable,
                    arguments: ["telemetry", "recover-last", "--quiet"]
                )
            }
        }

        let telemetryScript = stateDirectory.appendingPathComponent("telemetry.py")
        guard fileManager.isReadableFile(atPath: telemetryScript.path) else { return nil }
        guard let interpreter = pythonInterpreter(
            for: telemetryScript,
            environment: environment,
            fileManager: fileManager
        ) else {
            return nil
        }

        return RecoveryCommand(
            executable: interpreter.executable,
            arguments: interpreter.prefixArguments + [telemetryScript.path, "recover-last", "--quiet"]
        )
    }

    private static func pythonInterpreter(
        for script: URL,
        environment: [String: String],
        fileManager: FileManager
    ) -> (executable: URL, prefixArguments: [String])? {
        for key in ["CODEX_FLOW_PYTHON", "PYTHON"] {
            if let path = nonBlank(environment[key]) {
                let executable = URL(fileURLWithPath: path)
                if fileManager.isExecutableFile(atPath: executable.path) {
                    return (executable, [])
                }
            }
        }

        guard let firstLine = try? String(contentsOf: script, encoding: .utf8)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .first,
              firstLine.hasPrefix("#!") else {
            return nil
        }

        let shebang = firstLine.dropFirst(2)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let interpreter = shebang.first else { return nil }

        if interpreter == "/usr/bin/env", shebang.count >= 2 {
            // Preserve the script's own interpreter declaration. `/usr/bin/env`
            // is a stable system executable; it resolves the installed Python
            // selected by the user's environment without guessing a CLI path.
            return (URL(fileURLWithPath: interpreter), [shebang[1]])
        }

        let executable = URL(fileURLWithPath: interpreter)
        guard fileManager.isExecutableFile(atPath: executable.path) else { return nil }
        return (executable, [])
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
