import Foundation

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

    public var nearestResetCreditExpiry: Date? {
        resetCredits.compactMap(\.expiresAt).filter { $0 > Date() }.min()
    }
}

private final class AccountAppServerRPC {
    private struct Pending {
        let semaphore: DispatchSemaphore
        var result: [String: Any]?
    }

    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: Pending] = [:]
    private var buffer = Data()
    private var started = false

    init() throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["codex", "app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data)
        }
        try process.run()
        started = true
    }

    deinit { close() }

    func initialize() -> Bool {
        let response = request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "codex-flow", "title": "FlowPilot Account", "version": "1"],
                "capabilities": ["experimentalApi": true]
            ],
            timeout: 4.0
        )
        guard response != nil else { return false }
        notify(method: "initialized", params: nil)
        return true
    }

    func request(method: String, params: [String: Any]?, timeout: TimeInterval = 4.0) -> [String: Any]? {
        lock.lock()
        let id = nextId
        nextId += 1
        let semaphore = DispatchSemaphore(value: 0)
        pending[id] = Pending(semaphore: semaphore, result: nil)
        lock.unlock()

        var payload: [String: Any] = ["id": id, "method": method]
        if let params { payload["params"] = params }
        guard send(payload) else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            return nil
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            return nil
        }

        lock.lock()
        let result = pending.removeValue(forKey: id)?.result
        lock.unlock()
        return result
    }

    func notify(method: String, params: [String: Any]?) {
        var payload: [String: Any] = ["method": method]
        if let params { payload["params"] = params }
        _ = send(payload)
    }

    func close() {
        guard started else { return }
        started = false
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
    }

    private func send(_ object: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(object),
              var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            return true
        } catch {
            return false
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
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let idNumber = object["id"] as? NSNumber else { continue }
            let id = idNumber.intValue
            let result = object["result"] as? [String: Any]
            lock.lock()
            if var item = pending[id] {
                item.result = result
                pending[id] = item
                item.semaphore.signal()
            }
            lock.unlock()
        }
    }
}

public enum AccountSnapshotService {
    public static func load() throws -> AccountSnapshot {
        let rpc = try AccountAppServerRPC()
        defer { rpc.close() }

        guard rpc.initialize() else {
            throw error(L("Codex app-server did not respond.", "Codex app-server 未响应。"), code: 1)
        }

        let accountResponse = rpc.request(method: "account/read", params: ["refreshToken": false])
        let limitsResponse = rpc.request(method: "account/rateLimits/read", params: nil)
        guard accountResponse != nil || limitsResponse != nil else {
            throw error(L("Account data is unavailable from Codex.", "Codex 暂未返回账户数据。"), code: 2)
        }

        let account = accountResponse?["account"] as? [String: Any]
        let requiresAuth = (accountResponse?["requiresOpenaiAuth"] as? NSNumber)?.boolValue
        let fallbackSnapshot = limitsResponse?["rateLimits"] as? [String: Any]
        let byId = limitsResponse?["rateLimitsByLimitId"] as? [String: Any]
        let codexSnapshot = (byId?["codex"] as? [String: Any]) ?? fallbackSnapshot ?? [:]

        var windows: [AccountQuotaWindow] = []
        for slot in ["primary", "secondary"] {
            guard let raw = codexSnapshot[slot] as? [String: Any] else { continue }
            let duration = intValue(raw["windowDurationMins"] ?? raw["windowMinutes"])
            windows.append(AccountQuotaWindow(
                id: "\(slot)-\(duration ?? 0)",
                durationMinutes: duration,
                usedPercent: doubleValue(raw["usedPercent"]),
                resetsAt: dateValue(raw["resetsAt"])
            ))
        }

        let resetSummary = limitsResponse?["rateLimitResetCredits"] as? [String: Any]
        let resetCount = intValue(resetSummary?["availableCount"])
        let rawCredits = resetSummary?["credits"] as? [[String: Any]] ?? []
        let resetCredits = rawCredits.compactMap { raw -> AccountResetCredit? in
            guard let id = raw["id"] as? String else { return nil }
            return AccountResetCredit(
                id: id,
                status: raw["status"] as? String,
                expiresAt: dateValue(raw["expiresAt"]),
                title: raw["title"] as? String
            )
        }

        let credits = codexSnapshot["credits"] as? [String: Any]
        let plan = (account?["planType"] as? String) ?? (codexSnapshot["planType"] as? String)
        return AccountSnapshot(
            accountType: account?["type"] as? String,
            email: account?["email"] as? String,
            planType: plan,
            requiresOpenAIAuth: requiresAuth,
            quotaWindows: windows,
            resetCreditCount: resetCount,
            resetCredits: resetCredits,
            hasCredits: (credits?["hasCredits"] as? NSNumber)?.boolValue,
            unlimitedCredits: (credits?["unlimited"] as? NSNumber)?.boolValue,
            creditsBalance: credits?["balance"] as? String,
            spendControlReached: (codexSnapshot["spendControlReached"] as? NSNumber)?.boolValue,
            rateLimitReachedType: codexSnapshot["rateLimitReachedType"] as? String,
            fetchedAt: Date()
        )
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func dateValue(_ value: Any?) -> Date? {
        guard let raw = doubleValue(value), raw > 0 else { return nil }
        return Date(timeIntervalSince1970: raw > 1_000_000_000_000 ? raw / 1000.0 : raw)
    }

    private static func error(_ message: String, code: Int) -> NSError {
        NSError(domain: "FlowPilot.Account", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

public func formatAccountDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.timeZone = TimeZone.current
    let currentYear = Calendar.current.component(.year, from: Date())
    let targetYear = Calendar.current.component(.year, from: date)
    formatter.dateFormat = currentYear == targetYear ? "MM-dd HH:mm" : "yyyy-MM-dd HH:mm"
    return formatter.string(from: date)
}
