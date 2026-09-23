import Foundation
import Combine

public enum AnalysisPreviewConfigurationError: LocalizedError {
    case missingArgument(String)
    case unknownArgument(String)
    case nonAbsolutePath(String)
    case missingPath(String)
    case notDirectory(URL)
    case invalidConfig(URL)

    public var errorDescription: String? {
        switch self {
        case let .missingArgument(name): return "Missing value for \(name)."
        case let .unknownArgument(name): return "Unknown analysis-preview option \(name)."
        case let .nonAbsolutePath(name): return "\(name) must be an absolute path."
        case let .missingPath(path): return "Analysis preview path does not exist: \(path)."
        case let .notDirectory(url): return "Analysis preview state path is not a directory: \(url.path)."
        case let .invalidConfig(url): return "Analysis preview config is not a JSON object: \(url.path)."
        }
    }
}

public struct AnalysisPreviewConfiguration: Equatable {
    public let stateDirectory: URL
    public let analysisScript: URL
    public let pythonExecutable: URL

    public init(stateDirectory: URL, analysisScript: URL, pythonExecutable: URL) {
        self.stateDirectory = stateDirectory
        self.analysisScript = analysisScript
        self.pythonExecutable = pythonExecutable
    }

    public func validated(fileManager: FileManager = .default) throws -> AnalysisPreviewConfiguration {
        let paths: [(String, URL)] = [
            ("--state-dir", stateDirectory),
            ("--analysis-script", analysisScript),
            ("--python", pythonExecutable)
        ]
        for (name, url) in paths {
            guard url.isFileURL, url.path.hasPrefix("/") else {
                throw AnalysisPreviewConfigurationError.nonAbsolutePath(name)
            }
        }

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: stateDirectory.path, isDirectory: &isDirectory) else {
            throw AnalysisPreviewConfigurationError.missingPath(stateDirectory.path)
        }
        guard isDirectory.boolValue else {
            throw AnalysisPreviewConfigurationError.notDirectory(stateDirectory)
        }

        let configURL = stateDirectory.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw AnalysisPreviewConfigurationError.missingPath(configURL.path)
        }
        guard let configData = try? Data(contentsOf: configURL),
              let object = try? JSONSerialization.jsonObject(with: configData),
              object is [String: Any] else {
            throw AnalysisPreviewConfigurationError.invalidConfig(configURL)
        }

        for (_, url) in paths.dropFirst() {
            guard fileManager.fileExists(atPath: url.path) else {
                throw AnalysisPreviewConfigurationError.missingPath(url.path)
            }
        }
        return self
    }

    public var viewURL: URL { stateDirectory.appendingPathComponent("view.json") }
}

public struct AnalysisCommandResult {
    public let exitCode: Int32
    public let errorSummary: String?

    public init(exitCode: Int32, errorSummary: String? = nil) {
        self.exitCode = exitCode
        self.errorSummary = errorSummary
    }
}

public protocol ConversationAnalysisCommandRunning: AnyObject {
    func run(arguments: [String], completion: @escaping (Result<AnalysisCommandResult, Error>) -> Void)
    func cancel()
}

private enum AnalysisCommandError: LocalizedError {
    case start(String)
    case exited(Int32, String?)
    case cancelled

    var errorDescription: String? {
        switch self {
        case let .start(detail): return "Could not start analysis command: \(detail)"
        case let .exited(code, detail):
            if let detail, !detail.isEmpty { return "Analysis command exited with status \(code): \(detail)" }
            return "Analysis command exited with status \(code)."
        case .cancelled: return "Analysis command was cancelled."
        }
    }
}

/// Direct argv runner used by preview actions. Stdout is drained and discarded
/// so model/transcript text cannot leak into the UI or logs.
public final class AnalysisCommandRunner: ConversationAnalysisCommandRunning {
    private let configuration: AnalysisPreviewConfiguration
    private let lock = NSLock()
    private var process: Process?
    private var finished = false
    private var completion: ((Result<AnalysisCommandResult, Error>) -> Void)?
    private var stderrData = Data()

    public init(configuration: AnalysisPreviewConfiguration) {
        self.configuration = configuration
    }

    public func run(arguments: [String], completion: @escaping (Result<AnalysisCommandResult, Error>) -> Void) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        let arguments = [configuration.analysisScript.path] + arguments

        lock.lock()
        if self.process != nil {
            lock.unlock()
            completion(.failure(AnalysisCommandError.start("another command is still running")))
            return
        }
        self.process = process
        self.finished = false
        self.completion = completion
        self.stderrData.removeAll(keepingCapacity: true)
        lock.unlock()

        process.executableURL = configuration.pythonExecutable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        // Keep both pipes drained for the entire lifetime of the child. The
        // backend may emit structured progress on stdout and diagnostics on
        // stderr; neither stream is shown to the user.
        stdout.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStderr(data)
        }
        process.terminationHandler = { [weak self] process in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            self?.finish(exitCode: process.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            finish(error: AnalysisCommandError.start(error.localizedDescription))
        }
    }

    public func cancel() {
        lock.lock()
        let process = self.process
        lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
    }

    private func appendStderr(_ data: Data) {
        lock.lock()
        if stderrData.count < 4096 {
            stderrData.append(data.prefix(4096 - stderrData.count))
        }
        lock.unlock()
    }

    private func finish(exitCode: Int32) {
        lock.lock()
        let detail = conciseStderrLocked()
        lock.unlock()
        if exitCode == 0 {
            finish(result: .success(AnalysisCommandResult(exitCode: exitCode)))
        } else {
            finish(result: .failure(AnalysisCommandError.exited(exitCode, detail)))
        }
    }

    private func finish(error: Error) {
        finish(result: .failure(error))
    }

    private func finish(result: Result<AnalysisCommandResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let callback = completion
        completion = nil
        process = nil
        lock.unlock()
        callback?(result)
    }

    private func conciseStderrLocked() -> String? {
        guard let text = String(data: stderrData, encoding: .utf8) else { return nil }
        let concise = text
            .split(whereSeparator: { $0.isNewline })
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .last ?? ""
        guard !concise.isEmpty else { return nil }
        return String(concise.prefix(500))
    }
}

public struct AnalysisPreviewLaunchArguments {
    public let configuration: AnalysisPreviewConfiguration

    public init(arguments: [String]) throws {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard ["--state-dir", "--analysis-script", "--python"].contains(option) else {
                throw AnalysisPreviewConfigurationError.unknownArgument(option)
            }
            let valueIndex = index + 1
            guard valueIndex < arguments.count, !arguments[valueIndex].isEmpty,
                  !arguments[valueIndex].hasPrefix("--") else {
                throw AnalysisPreviewConfigurationError.missingArgument(option)
            }
            guard arguments[valueIndex].hasPrefix("/") else {
                throw AnalysisPreviewConfigurationError.nonAbsolutePath(option)
            }
            values[option] = arguments[valueIndex]
            index += 2
        }
        guard let state = values["--state-dir"],
              let script = values["--analysis-script"],
              let python = values["--python"] else {
            throw AnalysisPreviewConfigurationError.missingArgument("--state-dir, --analysis-script, and --python")
        }
        configuration = AnalysisPreviewConfiguration(
            stateDirectory: URL(fileURLWithPath: state),
            analysisScript: URL(fileURLWithPath: script),
            pythonExecutable: URL(fileURLWithPath: python)
        )
    }
}

public final class ConversationAnalysisService: ObservableObject {
    @Published public private(set) var projection: ConversationAnalysisProjection
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var commandErrorMessage: String?
    @Published public private(set) var isWatching = false

    public let configuration: AnalysisPreviewConfiguration
    private let runner: ConversationAnalysisCommandRunning
    private let readQueue = DispatchQueue(label: "com.codex.flow.analysis-preview.read", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var lastViewData: Data?

    public init(
        configuration: AnalysisPreviewConfiguration,
        runner: ConversationAnalysisCommandRunning? = nil
    ) {
        self.configuration = configuration
        self.runner = runner ?? AnalysisCommandRunner(configuration: configuration)
        projection = ConversationAnalysisProjection(snapshot: AnalysisSnapshot())
    }

    deinit { stop() }

    public func start() {
        guard !isWatching else { return }
        do {
            _ = try configuration.validated()
        } catch {
            publishError(error.localizedDescription)
            return
        }
        isWatching = true
        reload(force: true)

        let timer = DispatchSource.makeTimerSource(queue: readQueue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.reload(force: false) }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
        runner.cancel()
        if isWatching { isWatching = false }
    }

    public func reloadNow() {
        reload(force: true)
    }

    public func select(turnID: String) {
        applyOnMain { [weak self] in
            _ = self?.projection.select(turnID: turnID)
        }
    }

    public func selectLatest() {
        applyOnMain { [weak self] in self?.projection.selectLatest() }
    }

    @discardableResult
    public func performForTurn(_ command: String, sessionID: String?, turnID: String?, kind: AnalysisJobKind? = nil) -> Bool {
        guard let scoped = projection.snapshot.projection(sessionID: sessionID, turnID: turnID,
                    privacyMode: projection.privacyMode), !scoped.privacyMode, scoped.snapshot.enabled,
              let turnID else { return false }
        if command == "retry", let kind, let jobID = scoped.retryJobID(for: kind) {
            execute(["retry", "--state-dir", configuration.stateDirectory.path, "--job-id", jobID], completion: nil)
        } else if command == "extract-skill" || command == "analyze-turn" {
            execute([command, "--state-dir", configuration.stateDirectory.path, "--turn-id", turnID], completion: nil)
        } else { return false }
        return true
    }

    public func exportDraft(_ markdown: String, sessionID: String?, turnID: String?, jobID: String?, to url: URL) -> Bool {
        guard let scoped = projection.snapshot.projection(sessionID: sessionID, turnID: turnID,
                    privacyMode: projection.privacyMode), scoped.canExportSkill,
              scoped.selectedSkill?.jobID == jobID, !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        do { try Data(markdown.utf8).write(to: url, options: .atomic); return true }
        catch { return false }
    }

    public func setPrivacyMode(_ enabled: Bool) {
        applyOnMain { [weak self] in self?.projection.setPrivacyMode(enabled) }
    }

    @discardableResult
    public func analyzeSelectedTurn(completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard !projection.privacyMode, let turnID = projection.selectedTurnID else { return false }
        execute(["analyze-turn", "--state-dir", configuration.stateDirectory.path, "--turn-id", turnID], completion: completion)
        return true
    }

    @discardableResult
    public func extractSkill(completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard projection.canExtractSkill, let turnID = projection.selectedTurnID else { return false }
        execute(["extract-skill", "--state-dir", configuration.stateDirectory.path, "--turn-id", turnID], completion: completion)
        return true
    }

    @discardableResult
    public func retry(kind: AnalysisJobKind, completion: ((Result<Void, Error>) -> Void)? = nil) -> Bool {
        guard !projection.privacyMode,
              let jobID = projection.retryJobID(for: kind) else { return false }
        execute(["retry", "--state-dir", configuration.stateDirectory.path, "--job-id", jobID], completion: completion)
        return true
    }

    @discardableResult
    public func exportSelectedSkill(to url: URL) -> Bool {
        guard !projection.privacyMode else { return false }
        return projection.exportSkill(to: url)
    }

    @discardableResult
    public func exportSkillDraft(_ markdown: String, to url: URL) -> Bool {
        guard !projection.privacyMode,
              projection.canExportSkill,
              !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        do {
            try Data(markdown.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func execute(
        _ arguments: [String],
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        runner.run(arguments: arguments) { [weak self] result in
            switch result {
            case .success:
                self?.applyOnMain { self?.commandErrorMessage = nil }
                self?.reload(force: true)
                completion?(.success(()))
            case let .failure(error):
                self?.publishCommandError(error.localizedDescription)
                completion?(.failure(error))
            }
        }
    }

    private func reload(force: Bool) {
        readQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try Data(contentsOf: self.configuration.viewURL)
                if !force, data == self.lastViewData { return }
                let snapshot = try JSONDecoder().decode(AnalysisSnapshot.self, from: data)
                self.lastViewData = data
                self.applyOnMain {
                    self.projection.update(snapshot: snapshot)
                    self.errorMessage = nil
                }
            } catch {
                // A missing/partial view should not erase a useful snapshot
                // already on screen. The backend's source_error remains visible
                // when its next complete atomic replacement arrives.
                self.publishError(self.concise(error))
            }
        }
    }

    private func applyOnMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() }
        else { DispatchQueue.main.async(execute: body) }
    }

    private func publishError(_ message: String) {
        applyOnMain { [weak self] in self?.errorMessage = message }
    }

    private func publishCommandError(_ message: String) {
        applyOnMain { [weak self] in self?.commandErrorMessage = message }
    }

    private func concise(_ error: Error) -> String {
        String(error.localizedDescription.split(whereSeparator: { $0.isNewline }).first ?? "Analysis snapshot could not be loaded.")
    }
}
