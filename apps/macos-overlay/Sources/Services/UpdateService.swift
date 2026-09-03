import AppKit
import Foundation
import SwiftUI

// Shared update state bridge used by both the FlowPilot badge and update popover.
public struct FlowPilotUpdateSnapshot: Codable, Equatable, Sendable {
    public var schema: Int?
    public var status: String?
    public var currentVersion: String?
    public var latestVersion: String?
    public var channel: String?
    public var notifyCLI: Bool?
    public var notifyApp: Bool?
    public var updateAvailable: Bool?
    public var checkedAt: String?
    public var restartRequired: Bool?
    public var flowPilotRestartRequired: Bool?
    public var mandatory: Bool?
    public var releaseURL: String?
    public var releaseNotes: String?
    public var artifactAvailable: Bool?
    public var lastError: String?
    public var progress: Double?

    enum CodingKeys: String, CodingKey {
        case schema, status, channel, mandatory, progress
        case notifyCLI = "notify_cli"
        case notifyApp = "notify_app"
        case currentVersion = "current_version"
        case latestVersion = "latest_version"
        case updateAvailable = "update_available"
        case checkedAt = "checked_at"
        case restartRequired = "restart_required"
        case flowPilotRestartRequired = "flowpilot_restart_required"
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

    private static let periodicCheckInterval: TimeInterval = 30 * 60
    private static let lifecycleRefreshInterval: TimeInterval = 5 * 60

    @Published public private(set) var snapshot: FlowPilotUpdateSnapshot = .empty
    @Published public private(set) var isChecking = false
    @Published public private(set) var isInstalling = false
    @Published public private(set) var isAcknowledgingRestart = false
    @Published public private(set) var isRestartingFlowPilot = false
    @Published public private(set) var actionError: String?
    @Published public private(set) var actionMessage: String?

    private var periodicCheckTimer: Timer?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var isBackgroundCheckRunning = false
    private var lastBackgroundCheckRequestedAt: Date?

    private init() {
        refreshFromDisk()
        acknowledgeFlowPilotRestartAfterLaunchIfNeeded()
        configureLifecycleObservers()
        configurePeriodicUpdateCheck()
        requestCachedCheck()
    }

    deinit {
        periodicCheckTimer?.invalidate()
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        lifecycleObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    public var hasUpdateBadge: Bool {
        (snapshot.notifyApp ?? true) && (
            (snapshot.updateAvailable ?? false)
            || isRestartRequired
        )
    }

    // Generic UI badges/icons care whether any process still needs a restart.
    public var isRestartRequired: Bool {
        isCodexRestartRequired || isFlowPilotRestartRequired
    }

    public var isCodexRestartRequired: Bool {
        snapshot.restartRequired ?? false
    }

    public var isFlowPilotRestartRequired: Bool {
        snapshot.flowPilotRestartRequired ?? false
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
        if isFlowPilotRestartRequired && isCodexRestartRequired {
            return L("Update installed · restart FlowPilot and Codex", "更新已安装 · 请重启 FlowPilot 和 Codex")
        }
        if isFlowPilotRestartRequired {
            return L("Update installed · restart FlowPilot", "更新已安装 · 请重启 FlowPilot")
        }
        if isCodexRestartRequired {
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
        requestBackgroundCheck(force: false, minimumInterval: 0)
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

    // There is no reliable cross-platform way for this helper process to prove
    // that the Codex desktop/CLI host itself has restarted. Keep the reminder
    // explicit and let the user clear it after performing the required restart.
    public func acknowledgeRestart() {
        guard !isAcknowledgingRestart else { return }
        actionError = nil
        actionMessage = nil
        isAcknowledgingRestart = true
        runUpdater(arguments: ["update", "--ack-restart", "--quiet"], mode: .acknowledgeRestart)
    }

    private func acknowledgeFlowPilotRestartAfterLaunchIfNeeded() {
        guard snapshot.flowPilotRestartRequired == true, let executable = codexFlowExecutable else { return }
        Task.detached(priority: .utility) {
            let result = Self.executeUpdater(
                executable: executable,
                arguments: ["update", "--ack-flowpilot-restart", "--quiet"]
            )
            guard result.exitCode == 0 else { return }
            await MainActor.run {
                FlowPilotUpdateService.shared.refreshFromDisk()
            }
        }
    }

    // The OTA installer atomically replaces the FlowPilot binary on disk, but
    // the already-running process remains the old executable. Launch the newly
    // installed binary with `restart`; its existing IPC startup path shuts down
    // this process and becomes the new FlowPilot instance.
    public func restartFlowPilot() {
        guard !isRestartingFlowPilot else { return }
        actionError = nil
        actionMessage = nil
        guard let executable = flowPilotExecutable else {
            actionError = L("The updated FlowPilot binary was not found.", "未找到更新后的 FlowPilot 可执行文件。")
            return
        }
        isRestartingFlowPilot = true
        do {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["restart"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            actionMessage = L("Restarting FlowPilot with the updated binary…", "正在使用更新后的程序重启 FlowPilot…")
        } catch {
            isRestartingFlowPilot = false
            actionError = error.localizedDescription
        }
    }

    private func configurePeriodicUpdateCheck() {
        let timer = Timer.scheduledTimer(withTimeInterval: Self.periodicCheckInterval, repeats: true) { _ in
            Task { @MainActor in
                FlowPilotUpdateService.shared.requestBackgroundCheck(
                    force: true,
                    minimumInterval: Self.periodicCheckInterval
                )
            }
        }
        timer.tolerance = 2 * 60
        periodicCheckTimer = timer
    }

    private func configureLifecycleObservers() {
        let activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                FlowPilotUpdateService.shared.requestLifecycleRefresh()
            }
        }
        lifecycleObservers.append(activeObserver)

        let wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                FlowPilotUpdateService.shared.requestLifecycleRefresh()
            }
        }
        lifecycleObservers.append(wakeObserver)
    }

    private func requestLifecycleRefresh() {
        refreshFromDisk()
        requestBackgroundCheck(force: true, minimumInterval: Self.lifecycleRefreshInterval)
    }

    private func requestBackgroundCheck(force: Bool, minimumInterval: TimeInterval) {
        refreshFromDisk()
        guard !hasPendingUpdateAction else { return }
        guard !isBackgroundCheckRunning else { return }

        let now = Date()
        if minimumInterval > 0,
           let lastCheck = mostRecentCheckDate,
           now.timeIntervalSince(lastCheck) < minimumInterval {
            return
        }

        lastBackgroundCheckRequestedAt = now
        isBackgroundCheckRunning = true
        var arguments = ["update", "--check"]
        if force {
            arguments.append("--force")
        }
        arguments.append("--quiet")
        runUpdater(arguments: arguments, mode: .backgroundCheck)
    }

    private var hasPendingUpdateAction: Bool {
        (snapshot.updateAvailable ?? false)
            || isRestartRequired
    }

    private var mostRecentCheckDate: Date? {
        let persisted = snapshot.checkedAt.flatMap(Self.parseISO8601Date)
        switch (lastBackgroundCheckRequestedAt, persisted) {
        case let (runtime?, persisted?):
            return max(runtime, persisted)
        case let (runtime?, nil):
            return runtime
        case let (nil, persisted?):
            return persisted
        case (nil, nil):
            return nil
        }
    }

    private static func parseISO8601Date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private enum RunMode: Sendable {
        case backgroundCheck
        case foregroundCheck
        case install
        case acknowledgeRestart
    }

    private struct ProcessResult: Sendable {
        let exitCode: Int32
        let output: String
    }

    private func runUpdater(arguments: [String], mode: RunMode) {
        guard let executable = codexFlowExecutable else {
            if mode == .backgroundCheck {
                isBackgroundCheckRunning = false
            } else {
                actionError = L("codex-flow CLI was not found in the installed bin directory.", "未在安装目录中找到 codex-flow CLI。")
                isChecking = false
                isInstalling = false
                isAcknowledgingRestart = false
            }
            return
        }

        Task.detached(priority: .utility) {
            let result = Self.executeUpdater(executable: executable, arguments: arguments)
            await MainActor.run {
                FlowPilotUpdateService.shared.finish(mode: mode, result: result)
            }
        }
    }

    nonisolated private static func executeUpdater(executable: URL, arguments: [String]) -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ProcessResult(exitCode: process.terminationStatus, output: output)
        } catch {
            return ProcessResult(exitCode: -1, output: error.localizedDescription)
        }
    }

    private func finish(mode: RunMode, result: ProcessResult) {
        refreshFromDisk()
        switch mode {
        case .backgroundCheck:
            isBackgroundCheckRunning = false
        case .foregroundCheck:
            isChecking = false
            if result.exitCode != 0 {
                actionError = result.output.isEmpty ? L("Update check failed.", "检查更新失败。") : result.output
            } else {
                actionMessage = statusText
            }
        case .install:
            isInstalling = false
            if result.exitCode != 0 {
                actionError = result.output.isEmpty ? L("Update failed.", "更新失败。") : result.output
            } else {
                actionMessage = result.output.isEmpty ? L("Update completed.", "更新完成。") : result.output
            }
        case .acknowledgeRestart:
            isAcknowledgingRestart = false
            if result.exitCode != 0 {
                actionError = result.output.isEmpty ? L("Could not clear the restart reminder.", "无法清除重启提醒。") : result.output
            } else {
                actionMessage = L("Restart reminder cleared.", "已清除重启提醒。")
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

    private var flowPilotExecutable: URL? {
        let fm = FileManager.default
        let stateBin = stateDirectory.appendingPathComponent("bin", isDirectory: true)
        var candidates = [
            stateBin.appendingPathComponent("FlowPilot"),
            stateBin.appendingPathComponent("codex-flow-overlay"),
        ]
        if let firstArg = CommandLine.arguments.first, !firstArg.isEmpty {
            candidates.append(URL(fileURLWithPath: firstArg))
        }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
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