import Foundation

private final class CommandCapture {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

/// Shared CLI bridge for preferences; drains both output streams concurrently.
enum FlowPilotCommand {
    struct CommandResult {
        let stdout: String
    }

    static func run(
        _ arguments: [String],
        acceptedExitCodes: Set<Int32> = [0]
    ) throws -> CommandResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? home.appendingPathComponent(".codex")

        // FlowPilot is commonly launched by Finder or a login item, where the
        // process PATH does not include ~/.local/bin. Resolve the CLI locations
        // used by install.sh directly before falling back to PATH lookup.
        var candidates: [URL] = []
        if let configuredBinDir = environment["CODEX_FLOW_BIN_DIR"], !configuredBinDir.isEmpty {
            candidates.append(URL(fileURLWithPath: configuredBinDir).appendingPathComponent("codex-flow"))
        }
        candidates.append(home.appendingPathComponent(".local/bin/codex-flow"))
        candidates.append(codexHome.appendingPathComponent("codex-flow/bin/codex-flow"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex-flow"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex-flow"))

        if let installedCLI = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            process.executableURL = installedCLI
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex-flow"] + arguments
        }

        let stdoutCapture = CommandCapture()
        let stderrCapture = CommandCapture()
        let stdoutEOF = DispatchSemaphore(value: 0)
        let stderrEOF = DispatchSemaphore(value: 0)

        process.standardOutput = output
        process.standardError = error
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stdoutEOF.signal()
            } else {
                stdoutCapture.append(data)
            }
        }
        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                stderrEOF.signal()
            } else {
                stderrCapture.append(data)
            }
        }
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            error.fileHandleForReading.readabilityHandler = nil
        }

        try process.run()
        process.waitUntilExit()

        // stdout/stderr are drained concurrently while the process runs, so a
        // verbose child cannot fill a pipe and deadlock waitUntilExit(). Give
        // the EOF callbacks a bounded moment to flush their final chunks.
        _ = stdoutEOF.wait(timeout: .now() + 1.0)
        _ = stderrEOF.wait(timeout: .now() + 1.0)

        let stdout = stdoutCapture.string()
        let stderr = stderrCapture.string()
        guard acceptedExitCodes.contains(process.terminationStatus) else {
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(domain: "FlowPilot.Command", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: detail.isEmpty
                ? L("codex-flow command failed.", "codex-flow 命令执行失败。")
                : detail])
        }
        return CommandResult(stdout: stdout)
    }
}
