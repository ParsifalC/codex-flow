import Foundation
import Combine

public enum AppLanguage: String {
    case zh
    case en
}

public final class AppLocalization: ObservableObject {
    public static let shared = AppLocalization()

    @Published public private(set) var language: AppLanguage
    private var refreshTimer: Timer?

    private init() {
        language = Self.resolveLanguage()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let resolved = Self.resolveLanguage()
            if resolved != self.language {
                self.language = resolved
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
    }

    public func text(_ english: String, _ chinese: String) -> String {
        language == .zh ? chinese : english
    }

    public static func resolveLanguage() -> AppLanguage {
        let env = ProcessInfo.processInfo.environment
        if let rawOverride = env["CODEX_FLOW_LANGUAGE"], !rawOverride.isEmpty {
            return resolve(normalize(rawOverride) ?? "auto")
        }
        return resolve(configuredLanguage())
    }

    public static func configuredLanguage() -> String {
        let env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome = env["CODEX_HOME"] ?? home.appendingPathComponent(".codex").path
        let policy = URL(fileURLWithPath: codexHome).appendingPathComponent("codex-flow.toml")
        guard let text = try? String(contentsOf: policy, encoding: .utf8) else { return "auto" }

        var inUI = false
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inUI = line == "[ui]"
                continue
            }
            guard inUI else { continue }
            let noComment = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let eq = noComment.firstIndex(of: "=") else { continue }
            let key = noComment[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "language" else { continue }
            let rawValue = noComment[noComment.index(after: eq)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return normalize(rawValue) ?? "auto"
        }
        return "auto"
    }

    public static func systemLanguage() -> AppLanguage {
        for candidate in Locale.preferredLanguages {
            if let normalized = normalize(candidate), normalized != "auto" {
                return normalized == "zh" ? .zh : .en
            }
        }

        let env = ProcessInfo.processInfo.environment
        for key in ["LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"] {
            if let normalized = normalize(env[key]), normalized != "auto" {
                return normalized == "zh" ? .zh : .en
            }
        }
        return .en
    }

    private static func resolve(_ normalized: String) -> AppLanguage {
        switch normalized {
        case "zh": return .zh
        case "en": return .en
        default: return systemLanguage()
        }
    }

    private static func normalize(_ raw: String?) -> String? {
        let value = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        if value.isEmpty || ["auto", "system", "default"].contains(value) { return "auto" }
        if value == "zh" || value.hasPrefix("zh-") || value.hasPrefix("chinese") { return "zh" }
        if value == "en" || value.hasPrefix("en-") || value.hasPrefix("english") { return "en" }
        return nil
    }
}

private enum FlowPilotDateFormatters {
    static let lock = NSLock()
    static let clock = make("HH:mm")
    static let dateTime = make("MM-dd HH:mm")
    static let fullDateTime = make("yyyy-MM-dd HH:mm")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        return formatter
    }

    static func string(from date: Date, format: DateFormatter) -> String {
        lock.lock()
        defer { lock.unlock() }
        // Locale and time zone can change while a long-running menu-bar app is
        // alive, so refresh those lightweight properties while reusing the
        // expensive formatter instances themselves.
        format.locale = Locale.current
        format.timeZone = TimeZone.current
        return format.string(from: date)
    }
}

@inline(__always)
public func L(_ english: String, _ chinese: String) -> String {
    AppLocalization.shared.text(english, chinese)
}

/// User-facing local date/time with a calendar date. Same-year timestamps stay
/// compact; cross-year timestamps include the year to avoid ambiguity.
public func formatLocalDateTime(_ date: Date) -> String {
    let currentYear = Calendar.current.component(.year, from: Date())
    let targetYear = Calendar.current.component(.year, from: date)
    let formatter = currentYear == targetYear
        ? FlowPilotDateFormatters.dateTime
        : FlowPilotDateFormatters.fullDateTime
    return FlowPilotDateFormatters.string(from: date, format: formatter)
}

public func localizedRole(_ role: String) -> String {
    switch role.lowercased() {
    case "parent": return L("parent", "父 Agent")
    case "worker", "subagent": return L("worker", "Worker")
    default: return role
    }
}

public extension OverlayTab {
    var localizedTitle: String {
        switch self {
        case .inspector: return L("Inspector", "任务")
        case .history: return L("History", "历史")
        case .analytics: return L("Analytics", "统计")
        }
    }
}

public extension QuotaWindow {
    /// User-facing reset time deliberately includes a calendar date. A bare
    /// clock time is ambiguous for weekly windows and was especially confusing
    /// around midnight/year boundaries.
    var localizedFormattedResetsAt: String? {
        guard let r = resetsAt, r > 0 else { return nil }
        let date = Date(timeIntervalSince1970: r > 1_000_000_000_000 ? r / 1000.0 : r)
        if date <= Date() {
            return L("resets now", "立即重置")
        }

        let value = formatLocalDateTime(date)
        return L("resets \(value)", "\(value) 重置")
    }
}

public extension TaskRun {
    var localizedFormattedDate: String {
        guard let s = startedAtMs else { return "--:--" }
        let date = Date(timeIntervalSince1970: s / 1000.0)
        if Calendar.current.isDateInToday(date) {
            let value = FlowPilotDateFormatters.string(from: date, format: FlowPilotDateFormatters.clock)
            return L("Today \(value)", "今天 \(value)")
        }
        return FlowPilotDateFormatters.string(from: date, format: FlowPilotDateFormatters.dateTime)
    }
}

public extension ChatSession {
    var localizedRunsSummary: String {
        let count = runs.count
        return count == 1 ? L("1 session", "1 次会话") : L("\(count) sessions", "\(count) 轮会话")
    }
}
