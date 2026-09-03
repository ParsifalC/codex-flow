import Foundation
import Darwin

public struct AccountQuotaWindow: Identifiable {
    public let id: String
    public let durationMinutes: Int?
    public let usedPercent: Double?
    public let resetsAt: Date?

    public var remainingPercent: Double? {
        guard let usedPercent else { return nil }
        return max(0, min(100, 100 - usedPercent))
    }

    public var displayName: String {
        guard let mins = durationMinutes else { return L("Usage window", "额度窗口") }
        switch mins {
        case 300: return L("5 hour limit", "5 小时额度")
        case 10080: return L("Weekly limit", "每周额度")
        default:
            if mins < 60 { return "\(mins)m" }
            if mins < 1440 { return "\(mins / 60)h" }
            return "\(mins / 1440)d"
        }
    }

    public var compactName: String {
        guard let mins = durationMinutes else { return "—" }
        if mins == 300 { return "5h" }
        if mins == 10080 { return L("Weekly", "每周") }
        if mins < 60 { return "\(mins)m" }
        if mins < 1440 { return "\(mins / 60)h" }
        return "\(mins / 1440)d"
    }
}

public struct AccountResetCredit: Identifiable {
    public let id: String
    public let status: String?
    public let expiresAt: Date?
    public let title: String?
}

public struct AccountSnapshot {
    public let accountType: String?
    public let email: String?
    public let planType: String?
    public let requiresOpenAIAuth: Bool?
    public let quotaWindows: [AccountQuotaWindow]
    public let resetCreditCount: Int?
    public let resetCredits: [AccountResetCredit]
    public let hasCredits: Bool?
    public let unlimitedCredits: Bool?
    public let creditsBalance: String?
    public let spendControlReached: Bool?
    public let rateLimitReachedType: String?
    public let fetchedAt: Date

    public var fiveHourWindow: AccountQuotaWindow? {
        quotaWindows.first { $0.durationMinutes == 300 }
    }

    public var weeklyWindow: AccountQuotaWindow? {
        quotaWindows.first { $0.durationMinutes == 10080 }
    }

    public var orderedWindows: [AccountQuotaWindow] {
        var result: [AccountQuotaWindow] = []
        if let fiveHourWindow { result.append(fiveHourWindow) }
        if let weeklyWindow { result.append(weeklyWindow) }
        let knownIds = Set(result.map(\.id))
        result.append(contentsOf: quotaWindows.filter { !knownIds.contains($0.id) }.sorted {
            ($0.durationMinutes ?? Int.max) < ($1.durationMinutes ?? Int.max)
        })
        return result
    }

    /// True when Codex returned no account, quota, credit, or auth facts. A
    /// successful but empty response is distinct from a transport/RPC error so
    /// the Account view can render an explicit empty state.
    public var isEmpty: Bool {
        accountType == nil && email == nil && planType == nil &&
            requiresOpenAIAuth == nil && quotaWindows.isEmpty &&
            resetCreditCount == nil && resetCredits.isEmpty &&
            hasCredits == nil && unlimitedCredits == nil &&
            creditsBalance == nil && spendControlReached == nil &&
            rateLimitReachedType == nil
    }

    public var nearestResetCreditExpiry: Date? {
        resetCredits.compactMap(\.expiresAt).filter { $0 > Date() }.min()
    }
}

private final class AccountAppServerRPC {
    private final class Pending {
        let semaphore: DispatchSemaphore
        var result: [String: Any]?
        var error: Error?

        init() {
            semaphore = DispatchSemaphore(value: 0)
        }
    }

    private enum RPCError: LocalizedError {
        case deadlineExceeded(String)
        case processExited(Int32, String)
        case transport(String, String)
        case invalidResponse(String, String)
        case server(String, String?, String, String?)

        var errorDescription: String? {
            switch self {
            case let .deadlineExceeded(method):
                return "Codex \(method) timed out before the account request completed."
            case let .processExited(status, detail):
                let suffix = detail.isEmpty ? "" : " — \(detail)"
                return "Codex app-server exited with status \(status)\(suffix)."
            case let .transport(method, detail):
                return "Codex \(method) transport failed: \(detail)."
            case let .invalidResponse(method, detail):
                return "Codex \(method) returned an invalid response: \(detail)."
            case let .server(method, code, message, data):
                var value = "Codex \(method) failed"
                if let code, !code.isEmpty { value += " (\(code))" }
                value += ": \(message)"
                if let data, !data.isEmpty { value += " — \(data)" }
                return value
            }
        }
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errorOutput = Pipe()
    private let lock = NSLock()
    private let stderrReadLock = NSLock()
    private let deadline: Date
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var requestMethods: [Int: String] = [:]
    private var buffer = Data()
    private var stderrBuffer = Data()
    private var started = false
    private var terminalError: Error?

    init(deadline: Date) throws {
        self.deadline = deadline
        Self.configureProcess(process)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errorOutput

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self else { return }
            if data.isEmpty {
                // A child can close stdout before it finishes flushing stderr;
                // let the termination handler capture the final CLI/auth text.
                // If it has already exited, mark EOF immediately so waiters do
                // not depend on a readability callback ordering.
                if !self.process.isRunning {
                    self.markTerminal(nil)
                }
            } else {
                self.receive(data)
            }
        }
        errorOutput.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.receiveStderr(from: handle)
        }
        process.terminationHandler = { [weak self] process in
            self?.drainStderr()
            let detail = self?.stderrText() ?? ""
            self?.markTerminal(RPCError.processExited(process.terminationStatus, detail))
        }

        do {
            try process.run()
            lock.lock()
            started = true
            lock.unlock()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errorOutput.fileHandleForReading.readabilityHandler = nil
            throw NSError(
                domain: "FlowPilot.Account",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unable to start Codex app-server: \(error.localizedDescription)"]
            )
        }
    }

    deinit { close() }

    func initialize() throws {
        _ = try request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "codex-flow", "title": "FlowPilot Account", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ]
        )
        try notify(method: "initialized", params: nil)
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval = 4.0) throws -> [String: Any] {
        let item = Pending()
        let id: Int

        lock.lock()
        guard started, process.isRunning else {
            let error = terminalError ?? RPCError.transport(method, "process is not running")
            lock.unlock()
            throw error
        }
        id = nextId
        nextId += 1
        pending[id] = item
        requestMethods[id] = method
        lock.unlock()

        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }

        do {
            try send(payload, method: method, timeout: timeout)
        } catch {
            lock.lock()
            pending.removeValue(forKey: id)
            requestMethods.removeValue(forKey: id)
            lock.unlock()
            throw error
        }

        let remaining = min(timeout, max(0, deadline.timeIntervalSinceNow))
        guard remaining > 0 else {
            lock.lock()
            pending.removeValue(forKey: id)
            requestMethods.removeValue(forKey: id)
            lock.unlock()
            throw stopAfterTimeout()
        }

        guard item.semaphore.wait(timeout: .now() + remaining) == .success else {
            lock.lock()
            pending.removeValue(forKey: id)
            requestMethods.removeValue(forKey: id)
            let detail = terminalError
            lock.unlock()
            let timeoutError = stopAfterTimeout()
            if let detail { throw detail }
            throw timeoutError
        }

        lock.lock()
        let response = pending.removeValue(forKey: id)
        requestMethods.removeValue(forKey: id)
        let result = response?.result
        let responseError = response?.error
        lock.unlock()

        if let responseError { throw responseError }
        guard let result else {
            throw RPCError.invalidResponse(method, "missing result")
        }
        return result
    }

    func notify(method: String, params: [String: Any]?) throws {
        var payload: [String: Any] = ["method": method]
        if let params { payload["params"] = params }
        try send(payload, method: method, timeout: 1.0)
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        errorOutput.fileHandleForReading.readabilityHandler = nil

        lock.lock()
        let wasStarted = started
        started = false
        if terminalError == nil, wasStarted {
            terminalError = RPCError.transport("app-server", "connection closed")
        }
        let waiting = Array(pending.values)
        let failure = terminalError
        for item in waiting {
            if item.error == nil {
                item.error = failure ?? RPCError.transport("app-server", "connection closed")
            }
        }
        lock.unlock()

        for item in waiting {
            item.semaphore.signal()
        }

        // Closing the writer also releases a synchronous pipe write that may
        // be blocked because a broken/aborted child stopped reading stdin.
        input.fileHandleForWriting.closeFile()

        if process.isRunning {
            process.terminate()
            let grace = max(0, min(0.2, deadline.timeIntervalSinceNow))
            if grace > 0 {
                let end = Date().addingTimeInterval(grace)
                while process.isRunning && Date() < end {
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
            if process.isRunning {
                _ = kill(process.processIdentifier, SIGKILL)
            }
        }
        if wasStarted {
            // Process.waitUntilExit() is intentionally moved off the caller's
            // path. A broken child must never make AccountSnapshotService's
            // cleanup unbounded after the request deadline has expired. The
            // wait also gives a naturally exited child time to finish its
            // termination handler before pipe handles are closed.
            waitForExit(timeout: 0.2)
        }

        output.fileHandleForReading.closeFile()
        stderrReadLock.lock()
        errorOutput.fileHandleForReading.closeFile()
        stderrReadLock.unlock()
    }

    private func waitForExit(timeout: TimeInterval) {
        guard process.processIdentifier > 0 else { return }
        let completed = DispatchSemaphore(value: 0)
        let child = process
        DispatchQueue.global(qos: .utility).async {
            child.waitUntilExit()
            completed.signal()
        }
        let boundedTimeout = max(0, timeout)
        _ = completed.wait(timeout: .now() + boundedTimeout)
    }

    private func send(_ object: [String: Any], method: String, timeout: TimeInterval) throws {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else {
            throw RPCError.invalidResponse(method, "request is not valid JSON")
        }
        data.append(0x0A)

        lock.lock()
        let isStarted = started && process.isRunning
        let knownError = terminalError
        lock.unlock()
        guard isStarted else {
            throw knownError ?? RPCError.transport(method, "process is not running")
        }

        let writeLock = NSLock()
        var writeResult: Result<Void, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async { [input] in
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
                writeLock.lock()
                writeResult = .success(())
                writeLock.unlock()
            } catch {
                writeLock.lock()
                writeResult = .failure(error)
                writeLock.unlock()
            }
            semaphore.signal()
        }

        let remaining = min(timeout, max(0, deadline.timeIntervalSinceNow))
        guard remaining > 0, semaphore.wait(timeout: .now() + remaining) == .success else {
            throw stopAfterTimeout()
        }

        writeLock.lock()
        let result = writeResult
        writeLock.unlock()
        if case let .failure(error) = result {
            let detail = stderrText()
            throw RPCError.transport(method, detail.isEmpty ? error.localizedDescription : detail)
        }
        guard result != nil else {
            throw RPCError.transport(method, "pipe write did not complete")
        }
    }

    private func receive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        let newline = Data([0x0A])
        var lines: [Data] = []
        while let range = buffer.range(of: newline) {
            lines.append(buffer.subdata(in: buffer.startIndex..<range.lowerBound))
            buffer.removeSubrange(buffer.startIndex...range.lowerBound)
        }
        lock.unlock()

        for line in lines where !line.isEmpty {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                // Keep protocol noise available to the eventual transport
                // error rather than silently discarding it.
                lock.lock()
                if stderrBuffer.isEmpty { stderrBuffer.append(line) }
                lock.unlock()
                continue
            }
            guard let idNumber = object["id"] as? NSNumber else { continue }
            let id = idNumber.intValue
            lock.lock()
            guard let item = pending[id] else {
                lock.unlock()
                continue
            }
            if let errorObject = object["error"] as? [String: Any] {
                item.error = rpcError(errorObject, method: requestMethods[id] ?? "request \(id)")
            } else if let result = object["result"] as? [String: Any] {
                item.result = result
            } else if object["result"] is NSNull {
                // A successful JSON-RPC null result is an empty payload, not a
                // transport failure. The Account view can then show its empty
                // state while retaining the distinction from a missing reply.
                item.result = [:]
            } else {
                item.error = RPCError.invalidResponse(requestMethods[id] ?? "request \(id)", "missing result or error")
            }
            item.semaphore.signal()
            lock.unlock()
        }
    }

    private func receiveStderr(from handle: FileHandle) {
        stderrReadLock.lock()
        let data = handle.availableData
        stderrReadLock.unlock()
        guard !data.isEmpty else { return }
        lock.lock()
        stderrBuffer.append(data)
        lock.unlock()
    }

    private func drainStderr() {
        stderrReadLock.lock()
        defer { stderrReadLock.unlock() }
        while true {
            let data = errorOutput.fileHandleForReading.availableData
            guard !data.isEmpty else { return }
            lock.lock()
            stderrBuffer.append(data)
            lock.unlock()
        }
    }

    private func rpcError(_ object: [String: Any], method: String) -> Error {
        let code: String?
        if let value = object["code"] as? NSNumber {
            code = value.stringValue
        } else {
            code = object["code"] as? String
        }
        let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "unknown JSON-RPC error"
        var data: String?
        if let value = object["data"] as? String {
            data = value
        } else if let value = object["data"],
                  let encoded = try? JSONSerialization.data(withJSONObject: value),
                  let text = String(data: encoded, encoding: .utf8) {
            data = text
        }
        return RPCError.server(method, code, message, data)
    }

    private func markTerminal(_ error: Error?) {
        lock.lock()
        guard terminalError == nil else {
            lock.unlock()
            return
        }
        let failure = error ?? RPCError.processExited(process.terminationStatus, stderrTextLocked())
        terminalError = failure
        let waiting = Array(pending.values)
        for item in waiting { item.error = failure }
        lock.unlock()
        for item in waiting { item.semaphore.signal() }
    }

    @discardableResult
    private func stopAfterTimeout() -> Error {
        lock.lock()
        if terminalError == nil {
            let detail = stderrTextLocked()
            terminalError = detail.isEmpty
                ? RPCError.deadlineExceeded("app-server")
                : RPCError.transport("app-server", "request timed out: \(detail)")
        }
        started = false
        let waiting = Array(pending.values)
        let failure = terminalError
        for item in waiting { item.error = failure }
        lock.unlock()
        for item in waiting {
            item.semaphore.signal()
        }
        input.fileHandleForWriting.closeFile()
        if process.isRunning {
            process.terminate()
            _ = kill(process.processIdentifier, SIGKILL)
        }
        return failure ?? RPCError.deadlineExceeded("app-server")
    }

    private func stderrTextLocked() -> String {
        String(data: stderrBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func stderrText() -> String {
        lock.lock()
        let value = stderrTextLocked()
        lock.unlock()
        return value
    }

    private static func configureProcess(_ process: Process) {
        let environment = ProcessInfo.processInfo.environment

        // Keep parity with the Python telemetry app-server adapter. This is
        // especially useful for tests and non-standard Codex installations.
        if let override = environment["CODEX_FLOW_APP_SERVER_COMMAND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Avoid a login shell here: startup files can print to stdout and
            // corrupt the JSONL app-server stream before the first RPC reply.
            process.arguments = ["-c", override]
            process.environment = environment
            return
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        func expandedPath(_ value: String) -> String {
            (value as NSString).expandingTildeInPath
        }
        let codexHome = environment["CODEX_HOME"]
            .map { URL(fileURLWithPath: expandedPath($0)) }
            ?? home.appendingPathComponent(".codex")

        // Finder and Login Items normally inherit a minimal PATH. Honor any
        // explicit PATH entries first, then probe installation locations. The
        // nvm paths are enumerated rather than tied to one Node version, so a
        // versioned upgrade keeps working after a relaunch from launchd.
        var candidates: [URL] = []
        var searchDirectories: [URL] = []
        func appendDirectory(_ directory: URL) {
            guard !searchDirectories.contains(where: { $0.path == directory.path }) else { return }
            searchDirectories.append(directory)
        }
        func appendCandidate(_ candidate: URL) {
            guard !candidates.contains(where: { $0.path == candidate.path }) else { return }
            candidates.append(candidate)
        }

        if let explicit = environment["CODEX_FLOW_CODEX_PATH"]?
           .trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            let explicitURL = URL(fileURLWithPath: expandedPath(explicit))
            appendDirectory(explicitURL.deletingLastPathComponent())
            appendCandidate(explicitURL)
        }

        if let path = environment["PATH"] {
            for item in path.split(separator: ":") {
                let directory = URL(fileURLWithPath: String(item))
                appendDirectory(directory)
                appendCandidate(directory.appendingPathComponent("codex"))
            }
        }

        let conventionalDirectories = [
            home.appendingPathComponent(".local/bin"),
            home.appendingPathComponent(".npm-global/bin"),
            home.appendingPathComponent("Library/pnpm"),
            home.appendingPathComponent(".volta/bin"),
            home.appendingPathComponent(".bun/bin"),
            codexHome.appendingPathComponent("bin"),
            home.appendingPathComponent("Applications/ChatGPT.app/Contents/Resources"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources"),
            URL(fileURLWithPath: "/usr/bin"),
            URL(fileURLWithPath: "/bin")
        ]
        conventionalDirectories.forEach(appendDirectory)
        conventionalDirectories.forEach { appendCandidate($0.appendingPathComponent("codex")) }

        let nvmRoots = [
            environment["NVM_DIR"].map { URL(fileURLWithPath: expandedPath($0)) },
            home.appendingPathComponent(".nvm"),
            home.appendingPathComponent(".config/nvm")
        ].compactMap { $0 }
        for root in nvmRoots {
            appendDirectory(root.appendingPathComponent("current/bin"))
            appendDirectory(root.appendingPathComponent("default/bin"))
            appendCandidate(root.appendingPathComponent("current/bin/codex"))
            appendCandidate(root.appendingPathComponent("default/bin/codex"))
            let versions = (try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("versions/node"),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ))?.sorted { Self.nvmVersionComesFirst($0, $1) } ?? []
            for version in versions {
                let directory = version.appendingPathComponent("bin")
                appendDirectory(directory)
                appendCandidate(directory.appendingPathComponent("codex"))
            }
        }

        if let prefix = environment["npm_config_prefix"] ?? environment["PREFIX"] {
            let directory = URL(fileURLWithPath: expandedPath(prefix)).appendingPathComponent("bin")
            appendDirectory(directory)
            appendCandidate(directory.appendingPathComponent("codex"))
        }

        if let installedCodex = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) {
            process.executableURL = installedCodex
            process.arguments = ["app-server"]
            var launchEnvironment = environment
            // npm-installed Codex launchers commonly use ``#!/usr/bin/env
            // node``. Include every discovered nvm/bin directory so the
            // launcher and its Node runtime resolve under launchd as well.
            let path = searchDirectories.map(\.path).joined(separator: ":")
            if !path.isEmpty { launchEnvironment["PATH"] = path }
            process.environment = launchEnvironment
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["codex", "app-server"]
            var launchEnvironment = environment
            let path = searchDirectories.map(\.path).joined(separator: ":")
            if !path.isEmpty { launchEnvironment["PATH"] = path }
            process.environment = launchEnvironment
        }
    }

    private static func nvmVersionComesFirst(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = nvmVersionKey(lhs)
        let right = nvmVersionKey(rhs)
        for index in 0..<max(left.count, right.count) {
            let leftPart = index < left.count ? left[index] : 0
            let rightPart = index < right.count ? right[index] : 0
            if leftPart != rightPart { return leftPart > rightPart }
        }
        return lhs.lastPathComponent > rhs.lastPathComponent
    }

    private static func nvmVersionKey(_ url: URL) -> [Int] {
        url.lastPathComponent
            .split(whereSeparator: { !$0.isNumber })
            .compactMap { Int($0) }
    }
}

public enum AccountSnapshotService {
    /// Keep the complete account flow bounded, including process startup,
    /// writes, endpoint waits, EOF, and child cleanup.
    public static let outerTimeout: TimeInterval = 10.0

    public static func load() throws -> AccountSnapshot {
        let deadline = Date().addingTimeInterval(outerTimeout)
        let rpc = try AccountAppServerRPC(deadline: deadline)
        defer { rpc.close() }

        try rpc.initialize()

        var accountResponse: [String: Any]?
        var limitsResponse: [String: Any]?
        var failures: [String] = []

        do {
            accountResponse = try rpc.request(method: "account/read", params: ["refreshToken": false])
        } catch {
            accountResponse = nil
            let message = error.localizedDescription
            if !message.isEmpty && !failures.contains(message) { failures.append(message) }
        }

        do {
            limitsResponse = try rpc.request(method: "account/rateLimits/read", params: nil)
        } catch {
            limitsResponse = nil
            let message = error.localizedDescription
            if !message.isEmpty && !failures.contains(message) { failures.append(message) }
        }

        if !failures.isEmpty {
            throw NSError(
                domain: "FlowPilot.Account",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: " ")]
            )
        }

        guard accountResponse != nil || limitsResponse != nil else {
            throw NSError(
                domain: "FlowPilot.Account",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: L("Account data is unavailable from Codex.", "Codex 暂未返回账户数据。")]
            )
        }
        return try parse(accountResponse: accountResponse, limitsResponse: limitsResponse, now: Date())
    }

    /// Pure response parsing is public so fixture tests can exercise API
    /// compatibility without launching a real Codex process.
    public static func parse(
        accountResponse: [String: Any]?,
        limitsResponse: [String: Any]?,
        now: Date = Date()
    ) throws -> AccountSnapshot {
        guard accountResponse != nil || limitsResponse != nil else {
            throw NSError(
                domain: "FlowPilot.Account",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: L("Account data is unavailable from Codex.", "Codex 暂未返回账户数据。")]
            )
        }

        let account = accountResponse?["account"] as? [String: Any]
        let requiresAuth = boolValue(
            accountResponse?["requiresOpenAIAuth"] ?? accountResponse?["requiresOpenaiAuth"]
        )

        let legacy = limitsResponse?["rateLimits"] as? [String: Any]
        let byId = limitsResponse?["rateLimitsByLimitId"] as? [String: Any]
        let codex = byId?["codex"] as? [String: Any]
        let windows = parseQuotaWindows(codex: codex, legacy: legacy)

        // Codex is authoritative when a field exists, while legacy values fill
        // holes in an incomplete multi-bucket response.
        let mergedSnapshot = mergedDictionary(primary: codex, fallback: legacy)
        let resetSummary = limitsResponse?["rateLimitResetCredits"] as? [String: Any]
        let resetCount = intValue(resetSummary?["availableCount"])
        let resetCredits: [AccountResetCredit]
        if let rawCredits = resetSummary?["credits"] as? [[String: Any]] {
            resetCredits = rawCredits.compactMap { raw -> AccountResetCredit? in
                guard let id = stringValue(raw["id"]), !id.isEmpty else { return nil }
                return AccountResetCredit(
                    id: id,
                    status: stringValue(raw["status"]),
                    expiresAt: dateValue(raw["expiresAt"]),
                    title: stringValue(raw["title"])
                )
            }
        } else {
            // Do not synthesize credits from availableCount. An omitted credits
            // list is different from an explicitly empty list to API clients;
            // this model keeps the list empty while preserving the authoritative
            // nullable count above.
            resetCredits = []
        }

        let credits = mergedSnapshot?["credits"] as? [String: Any]
        let plan = stringValue(account?["planType"]) ?? stringValue(mergedSnapshot?["planType"])
        return AccountSnapshot(
            accountType: stringValue(account?["type"]),
            email: stringValue(account?["email"]),
            planType: plan,
            requiresOpenAIAuth: requiresAuth,
            quotaWindows: windows,
            resetCreditCount: resetCount,
            resetCredits: resetCredits,
            hasCredits: boolValue(credits?["hasCredits"]),
            unlimitedCredits: boolValue(credits?["unlimited"]),
            creditsBalance: stringValue(credits?["balance"]),
            spendControlReached: boolValue(mergedSnapshot?["spendControlReached"]),
            rateLimitReachedType: stringValue(mergedSnapshot?["rateLimitReachedType"]),
            fetchedAt: now
        )
    }

    private struct QuotaCandidate {
        let slot: String
        let sourceRank: Int
        let duration: Int?
        let used: Double?
        let reset: Date?
    }

    private static func parseQuotaWindows(
        codex: [String: Any]?,
        legacy: [String: Any]?
    ) -> [AccountQuotaWindow] {
        var candidates: [QuotaCandidate] = []
        for slot in ["primary", "secondary"] {
            let codexRaw = codex?[slot] as? [String: Any]
            let legacyRaw = legacy?[slot] as? [String: Any]
            guard let merged = mergedDictionary(primary: codexRaw, fallback: legacyRaw), !merged.isEmpty else {
                continue
            }
            let duration = firstIntValue(in: codexRaw, fallback: legacyRaw, keys: ["windowDurationMins", "windowMinutes", "window_duration_mins"])
            let used = firstDoubleValue(in: codexRaw, fallback: legacyRaw, keys: ["usedPercent", "used_percent"])
            let reset = firstDateValue(in: codexRaw, fallback: legacyRaw, keys: ["resetsAt", "resets_at"])
            guard duration != nil || used != nil || reset != nil else { continue }
            candidates.append(QuotaCandidate(
                slot: slot,
                sourceRank: codexRaw == nil ? 1 : 0,
                duration: duration,
                used: used,
                reset: reset
            ))
        }

        // A duplicate response can expose the same logical window as both
        // primary and secondary. Prefer codex over legacy and primary over
        // secondary, while retaining same-reset windows when durations differ.
        var selected: [String: QuotaCandidate] = [:]
        for candidate in candidates {
            let key = logicalWindowKey(candidate)
            guard let existing = selected[key] else {
                selected[key] = candidate
                continue
            }
            let candidateRank = (candidate.sourceRank, candidate.slot == "primary" ? 0 : 1)
            let existingRank = (existing.sourceRank, existing.slot == "primary" ? 0 : 1)
            if candidateRank < existingRank {
                selected[key] = candidate
            }
        }

        return selected.values.map { candidate in
            AccountQuotaWindow(
                id: stableWindowID(candidate),
                durationMinutes: candidate.duration,
                usedPercent: candidate.used,
                resetsAt: candidate.reset
            )
        }.sorted {
            let leftDuration = $0.durationMinutes ?? Int.max
            let rightDuration = $1.durationMinutes ?? Int.max
            if leftDuration != rightDuration { return leftDuration < rightDuration }
            return $0.id < $1.id
        }
    }

    private static func logicalWindowKey(_ candidate: QuotaCandidate) -> String {
        let duration = candidate.duration.map(String.init) ?? "unknown"
        if let reset = candidate.reset {
            let millis = Int64((reset.timeIntervalSince1970 * 1000.0).rounded())
            return "duration=\(duration)|reset=\(millis)"
        }
        // When reset is missing, keep distinct unknown slots apart unless they
        // have the same duration and slot identity. This avoids collapsing all
        // malformed/partial windows into one row.
        return "duration=\(duration)|reset=none|slot=\(candidate.slot)"
    }

    private static func stableWindowID(_ candidate: QuotaCandidate) -> String {
        let duration = candidate.duration.map(String.init) ?? "unknown"
        if let reset = candidate.reset {
            let millis = Int64((reset.timeIntervalSince1970 * 1000.0).rounded())
            return "quota-\(duration)-\(millis)"
        }
        return "quota-\(duration)-\(candidate.slot)"
    }

    private static func mergedDictionary(
        primary: [String: Any]?,
        fallback: [String: Any]?
    ) -> [String: Any]? {
        guard primary != nil || fallback != nil else { return nil }
        var result = fallback ?? [:]
        for (key, value) in primary ?? [:] where !(value is NSNull) {
            result[key] = value
        }
        return result
    }

    private static func firstIntValue(
        in primary: [String: Any]?,
        fallback: [String: Any]?,
        keys: [String]
    ) -> Int? {
        for key in keys {
            if let value = primary?[key], let parsed = intValue(value) { return parsed }
        }
        for key in keys {
            if let value = fallback?[key], let parsed = intValue(value) { return parsed }
        }
        return nil
    }

    private static func firstDoubleValue(
        in primary: [String: Any]?,
        fallback: [String: Any]?,
        keys: [String]
    ) -> Double? {
        for key in keys {
            if let value = primary?[key], let parsed = doubleValue(value) { return parsed }
        }
        for key in keys {
            if let value = fallback?[key], let parsed = doubleValue(value) { return parsed }
        }
        return nil
    }

    private static func firstDateValue(
        in primary: [String: Any]?,
        fallback: [String: Any]?,
        keys: [String]
    ) -> Date? {
        for key in keys {
            if let value = primary?[key], let parsed = dateValue(value) { return parsed }
        }
        for key in keys {
            if let value = fallback?[key], let parsed = dateValue(value) { return parsed }
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !(value is Bool) { return number.intValue }
        if let value = value as? String { return Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(value is Bool) { return number.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let value = value as? String {
            switch value.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        if let raw = doubleValue(value), raw > 0 {
            return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000.0 : raw)
        }
        if let value = value as? String {
            return ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}

public func formatAccountDate(_ date: Date) -> String {
    formatLocalDateTime(date)
}
