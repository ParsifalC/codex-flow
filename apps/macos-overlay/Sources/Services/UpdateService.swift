import Foundation
import SwiftUI

public struct FlowPilotUpdateSnapshot: Codable, Equatable {
    public var schema: Int?
    public var status: String?
    public var currentVersion: String?
    public var latestVersion: String?
    public var channel: String?
    public var updateAvailable: Bool?
    public var checkedAt: String?
    public var restartRequired: Bool?
    public var mandatory: Bool?
    public var releaseURL: String?
    public var releaseNotes: String?
    public var artifactAvailable: Bool?
    public var lastError: String?
    public var progress: Double?

    enum CodingKeys: String, CodingKey {
        case schema, status, channel, mandatory, progress
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case updateAvailable = "update_available"
        case checkedAt = "checked_at"
        case restartRequired = "restart_required"
        case releaseURL = "release_url"
        case releaseNotes = "release_notes"
        case artifactAvailable = "artifact_available"
        case lastError = "last_error"
    }

    public static let empty = FlowPilotUpdateSnapshot()
}

@MainActor
public final class FlowPilotUpdateService: ObservableObject {
    public static let shared = FlowPilotUpdateService()

    @Published public private(set) var snapshot: FlowPilotUpdateSnapshot = .empty
    @Published public private(set) var isChecking = false
    @Published public private(set) var isInstalling = false
    @Published public private(set) var actionError: String?
    @Published public private(set) var actionMessage: String?

    private var timer: Timer?
    private let workerQueue = DispatchQueue(label: "codex-flow.update-service", qos: .utility)

    private init() {
        refreshFromDisk()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshFromDisk()
            }
        }
        requestCachedCheck()
    }

    deinit {
        timer?.invalidate()
    }

    public var hasUpdateBadge: Bool {
        (snapshot.updateAvailable ?? false) || (snapshot.restartRequired ?? false)
    }

    public var isRestartRequired: Bool {
        snapshot.restartRequired ?? false
    }

    public var displayVersion: String? {
        if snapshot.updateAvailable == true {
            return snapshot.latestVersion
        }
        return snapshot.currentVersion
    }

    public var statusText: String {
        if isInstalling {
            return L("Installing update…", "正在安装更新…")
        }
        if isChecking {
            return L("Checking for updates…", "正在检查更新…")
        }
        if snapshot.restartRequired == true {
            return L("Update installed · restart Codex", "更新已安装 · 请重启 Codex")
        }
        if snapshot.updateAvailable == true, let latest = snapshot.latestVersion {
            return L("v\(latest) is available", "v\(latest) 可更新")
        }
        if snapshot.status == "latest", let current = snapshot.currentVersion {
            return L("v\(current) is up to date", "v\(current) 已是最新版本")
        }
        if let error = snapshot.lastError, !error.isEmpty {
            return L("Unable to check for updates", "暂时无法检查更新")
        }
        return L("Update status unknown", "更新状态未知")
    }

    public func refreshFromDisk() {
        let url = updateStateURL
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(FlowPilotUpdateSnapshot.self, from: data) else {
            return
        }
        if decoded != snapshot {
            snapshot = decoded
        }
    }

    public func requestCachedCheck() {
        runUpdater(arguments: ["update", "--check", "--quiet"], mode: .backgroundCheck)
    }

    public func checkNow() {
        actionError = nil
        actionMessage = nil
        isChecking = true
        runUpdater(arguments: ["update", "--check", "--force", "--quiet"], mode: .foregroundCheck)
    }

    public func installUpdate() {
        guard !isInstalling else { return }
        actionError = nil
        actionMessage = nil
        isInstalling = true
        runUpdater(arguments: ["update"], mode: .install)
    }

    private enum RunMode {
        case backgroundCheck
        case foregroundCheck
        case install
    }

    private func runUpdater(arguments: [String], mode: RunMode) {
        guard let executable = codexFlowExecutable else {
            if mode != .backgroundCheck {
                actionError = L("codex-flow CLI was not found in the installed bin directory.", "未在安装目录中找到 codex-flow CLI。")
                isChecking = false
                isInstalling = false
            }
            return
        }

        workerQueue.async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            var output = ""
            var exitCode: Int32 = -1
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                exitCode = process.terminationStatus
                output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            } catch {
                output = error.localizedDescription
            }

            Task { @MainActor in
                guard let self else { return }
                self.refreshFromDisk()
                switch mode {
                case .backgroundCheck:
                    break
                case .foregroundCheck:
                    self.isChecking = false
                    if exitCode != 0 {
                        self.actionError = output.isEmpty ? L("Update check failed.", "检查更新失败。") : output
                    } else {
                        self.actionMessage = self.statusText
                    }
                case .install:
                    self.isInstalling = false
                    if exitCode != 0 {
                        self.actionError = output.isEmpty ? L("Update failed.", "更新失败。") : output
                    } else {
                        self.actionMessage = output.isEmpty ? L("Update completed.", "更新完成。") : output
                    }
                }
            }
        }
    }

    private var updateStateURL: URL {
        stateDirectory.appendingPathComponent("state/update.json")
    }

    private var stateDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let value = env["CODEX_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value).appendingPathComponent("codex-flow", isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/codex-flow", isDirectory: true)
    }

    private var codexFlowExecutable: URL? {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let value = env["CODEX_FLOW_BIN_DIR"], !value.isEmpty {
            candidates.append(URL(fileURLWithPath: value).appendingPathComponent("codex-flow"))
        }
        let binState = stateDirectory.appendingPathComponent("bin_dir")
        if let data = try? Data(contentsOf: binState),
           let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            candidates.append(URL(fileURLWithPath: value).appendingPathComponent("codex-flow"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex-flow"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/codex-flow"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/codex-flow"))
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }
}
