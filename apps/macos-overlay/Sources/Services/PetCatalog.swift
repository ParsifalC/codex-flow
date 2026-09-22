import Foundation

/// The small, display-only record returned by `codex-flow pets list --json`.
///
/// The CLI owns installation and selection persistence. The native view only
/// uses this metadata to render choices and delegates changes back to the CLI.
public struct PetCatalogEntry: Decodable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String
    public let version: Int
    public let spritesheetPath: String?
    public let current: Bool
    public let preset: Bool
    public let packagePath: String?

    public init(
        id: String,
        displayName: String,
        description: String = "",
        version: Int = 1,
        spritesheetPath: String? = nil,
        current: Bool = false,
        preset: Bool = false,
        packagePath: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.version = version
        self.spritesheetPath = spritesheetPath
        self.current = current
        self.preset = preset
        self.packagePath = packagePath
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case description
        case spriteVersionNumber
        case spritesheetPath
        case current
        case preset
        case packagePath
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName) ?? id
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        version = try Self.decodeVersion(from: container)
        spritesheetPath = try container.decodeIfPresent(String.self, forKey: .spritesheetPath)
        current = try container.decodeIfPresent(Bool.self, forKey: .current) ?? false
        preset = try container.decodeIfPresent(Bool.self, forKey: .preset) ?? false
        packagePath = try container.decodeIfPresent(String.self, forKey: .packagePath)
    }

    private static func decodeVersion(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> Int {
        try container.decodeIfPresent(Int.self, forKey: .spriteVersionNumber) ?? 1
    }
}

public enum PetCatalogError: LocalizedError {
    case invalidOutput
    case invalidEntry(String)

    public var errorDescription: String? {
        switch self {
        case .invalidOutput:
            return L("codex-flow returned an invalid pet catalog.", "codex-flow 返回了无效的宠物列表。")
        case .invalidEntry(let id):
            return L("Pet metadata is invalid: \(id)", "宠物元数据无效：\(id)")
        }
    }
}

public enum PetCatalogParser {
    public static let presetOrder = [
        "dasheng",
        "deepseek",
        "doraemon",
        "lulu-capybara-2",
        "noir-webling"
    ]

    public static func parse(_ output: String) throws -> [PetCatalogEntry] {
        guard let data = output.data(using: .utf8) else {
            throw PetCatalogError.invalidOutput
        }
        let entries: [PetCatalogEntry]
        do {
            entries = try JSONDecoder().decode([PetCatalogEntry].self, from: data)
        } catch {
            throw PetCatalogError.invalidOutput
        }

        var ids = Set<String>()
        for entry in entries {
            guard !entry.id.isEmpty,
                  entry.id != ".",
                  entry.id != "..",
                  entry.id != "current",
                  entry.id != "installed",
                  !entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  entry.version == 1 || entry.version == 2,
                  entry.id.utf8.allSatisfy({ byte in
                      (byte >= 48 && byte <= 57) ||
                      (byte >= 65 && byte <= 90) ||
                      (byte >= 97 && byte <= 122) ||
                      byte == 45 || byte == 46 || byte == 95
                  }),
                  ids.insert(entry.id).inserted else {
                throw PetCatalogError.invalidEntry(entry.id)
            }
        }
        return entries
    }

    /// Keep the built-in choices stable even when a custom package was
    /// installed before the catalog command was added. Dasheng is first and
    /// the original bubble is always available as the final choice.
    public static func ordered(_ entries: [PetCatalogEntry]) -> [PetCatalogEntry] {
        let presetRanks = Dictionary(uniqueKeysWithValues: presetOrder.enumerated().map { ($1, $0) })
        let presets = entries
            .filter { $0.id != "default" && ($0.preset || presetRanks[$0.id] != nil) }
            .sorted { lhs, rhs in
                let left = presetRanks[lhs.id] ?? presetOrder.count
                let right = presetRanks[rhs.id] ?? presetOrder.count
                return left == right ? lhs.id < rhs.id : left < right
            }
        let custom = entries
            .filter { !($0.preset || presetRanks[$0.id] != nil) && $0.id != "default" }
            .sorted { lhs, rhs in
                let left = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                return left == .orderedSame ? lhs.id < rhs.id : left == .orderedAscending
            }

        let defaultEntry = entries.first(where: { $0.id == "default" }) ?? PetCatalogEntry(
            id: "default",
            displayName: L("Original bubble", "原始悬浮球"),
            description: L("Use the original FlowPilot bubble.", "使用原始 FlowPilot 悬浮球。"),
            current: false,
            preset: false
        )
        return presets + custom + [defaultEntry]
    }
}

/// Synchronous CLI operations, called only from background work by the UI.
/// Injection keeps the command contract testable without changing user state.
enum PetCatalogService {
    typealias Runner = ([String]) throws -> String

    static func list(run: Runner = command) throws -> [PetCatalogEntry] {
        try PetCatalogParser.parse(run(["pets", "list", "--json"]))
    }

    static func select(_ id: String, run: Runner = command) throws {
        _ = try run(["pets", "use", id])
    }

    private static func command(_ arguments: [String]) throws -> String {
        try FlowPilotCommand.run(arguments).stdout
    }
}
