import SwiftUI

public struct FlowPilotUpdateView: View {
    @ObservedObject private var service = FlowPilotUpdateService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerSection

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 10) {
                    versionCard
                    autoUpdateCard
                    releaseNotesSection
                    feedbackMessageSection
                }
                .padding(.horizontal, 1)
            }
            .frame(maxHeight: 230)

            if service.isRestartRequired {
                restartSection
            }

            Divider()
                .opacity(0.35)

            actionButtons
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            service.refreshFromDisk()
            service.requestCachedCheck()
        }
    }

    private var headerSection: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: service.isRestartRequired ? "arrow.clockwise.circle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(service.isRestartRequired ? .orange : .cyan)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Software Update", "软件更新"))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text(service.statusText)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
        }
    }

    private var versionCard: some View {
        VStack(spacing: 6) {
            versionRow(
                title: L("Current", "当前版本"),
                value: service.snapshot.currentVersion.map { "v\($0)" } ?? "—"
            )
            versionRow(
                title: L("Latest", "最新版本"),
                value: service.snapshot.latestVersion.map { "v\($0)" } ?? "—"
            )
            versionRow(
                title: L("Channel", "更新通道"),
                value: service.snapshot.channel?.capitalized ?? "Stable"
            )
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var autoUpdateCard: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Automatic Updates", "自动更新"))
                    .font(.system(size: 10, weight: .bold))
                Text(L("Automatically download, install, and restart", "发现新版本时自动下载安装并重启"))
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if service.isChangingAutoUpdate {
                ProgressView().controlSize(.mini)
            }
            Toggle("", isOn: Binding(
                get: { service.isAutoUpdateEnabled },
                set: { service.setAutoUpdateEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(SleekSwitchToggleStyle(tint: .cyan, width: 32, height: 18))
            .disabled(
                service.isChangingAutoUpdate
                || service.isInstalling
                || service.isRestartingFlowPilot
                || service.isAutoRestartScheduled
            )
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
    }

    @ViewBuilder
    private var releaseNotesSection: some View {
        if let notes = service.snapshot.releaseNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L("What's New", "更新内容"))
                        .font(.system(size: 10, weight: .bold))
                    Spacer()
                    if let urlString = service.snapshot.releaseURL, let url = URL(string: urlString) {
                        Link(destination: url) {
                            HStack(spacing: 2) {
                                Text(L("Changelog", "更新日志"))
                                Image(systemName: "arrow.up.right")
                            }
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundColor(.cyan)
                        }
                    }
                }

                ScrollView(.vertical, showsIndicators: true) {
                    Text(notes)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(height: 96)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.035))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }

    @ViewBuilder
    private var feedbackMessageSection: some View {
        if let error = service.actionError, !error.isEmpty {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9.5))
                    .foregroundColor(.orange)
                    .padding(.top, 1)
                ScrollView(.vertical, showsIndicators: true) {
                    Text(error)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 52)
            }
            .padding(7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.orange.opacity(0.08))
            )
        } else if let message = service.actionMessage, !message.isEmpty {
            Text(message)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var restartSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.orange)
                Text(restartExplanation)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                if service.isFlowPilotRestartRequired {
                    Button {
                        service.restartFlowPilot()
                    } label: {
                        HStack(spacing: 4) {
                            if service.isRestartingFlowPilot || service.isAutoRestartScheduled {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(service.isAutoRestartScheduled ? L("Restarting…", "正在重启…") : L("Restart FlowPilot", "重启 FlowPilot"))
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        service.isRestartingFlowPilot
                        || service.isAutoRestartScheduled
                        || service.isAcknowledgingRestart
                        || service.isInstalling
                        || service.isChecking
                    )
                }

                if service.isCodexRestartRequired {
                    Button {
                        service.acknowledgeRestart()
                    } label: {
                        HStack(spacing: 4) {
                            if service.isAcknowledgingRestart {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "checkmark.circle")
                            }
                            Text(L("I've restarted Codex", "我已重启 Codex"))
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        service.isAcknowledgingRestart
                        || service.isRestartingFlowPilot
                        || service.isAutoRestartScheduled
                        || service.isInstalling
                        || service.isChecking
                    )
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.07))
        )
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            Button {
                service.checkNow()
            } label: {
                HStack(spacing: 4) {
                    if service.isChecking {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(L("Check Again", "重新检查"))
                }
                .font(.system(size: 10, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.bordered)
            .disabled(
                service.isChecking
                || service.isInstalling
                || service.isAcknowledgingRestart
                || service.isRestartingFlowPilot
                || service.isAutoRestartScheduled
            )

            Button {
                service.installUpdate()
            } label: {
                HStack(spacing: 4) {
                    if service.isInstalling {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                    }
                    Text(service.isInstalling ? L("Updating…", "更新中…") : L("Update Now", "立即更新"))
                }
                .font(.system(size: 10, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                service.isInstalling
                || service.isChecking
                || service.isAcknowledgingRestart
                || service.isRestartingFlowPilot
                || service.isAutoRestartScheduled
                || service.snapshot.updateAvailable != true
                || service.snapshot.artifactAvailable == false
            )
        }
    }

    private var restartExplanation: String {
        if service.isFlowPilotRestartRequired && service.isCodexRestartRequired {
            return L(
                "The new files are installed. Restart FlowPilot to load the new app binary, and fully restart Codex to activate updated FlowPilot policy and hook snapshots.",
                "新文件已经安装。请重启 FlowPilot 载入新的 App 程序，并完整重启 Codex 以激活新的 FlowPilot 策略和 Hook 快照。"
            )
        }
        if service.isFlowPilotRestartRequired {
            return L(
                "The updated FlowPilot binary is installed. Restart FlowPilot to load it.",
                "新的 FlowPilot 程序已经安装。请重启 FlowPilot 以载入新版本。"
            )
        }
        return L(
            "Fully restart Codex to activate updated FlowPilot policy and hook snapshots.",
            "请完整重启 Codex，以激活新的 FlowPilot 策略和 Hook 快照。"
        )
    }

    private func versionRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .lineLimit(1)
        }
    }
}