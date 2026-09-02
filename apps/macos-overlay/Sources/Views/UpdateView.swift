import SwiftUI

public struct FlowPilotUpdateView: View {
    @ObservedObject private var service = FlowPilotUpdateService.shared

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            if let notes = service.snapshot.releaseNotes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("What's New", "更新内容"))
                        .font(.system(size: 10, weight: .bold))
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(notes)
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 110)
                }
            }

            if let error = service.actionError, !error.isEmpty {
                Text(error)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = service.actionMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if service.isRestartRequired {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundColor(.orange)
                        Text(restartExplanation)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 6) {
                        if service.isFlowPilotRestartRequired {
                            Button {
                                service.restartFlowPilot()
                            } label: {
                                HStack(spacing: 4) {
                                    if service.isRestartingFlowPilot {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text(L("Restart FlowPilot", "重启 FlowPilot"))
                                }
                                .font(.system(size: 9.5, weight: .semibold))
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                service.isRestartingFlowPilot
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
                                || service.isInstalling
                                || service.isChecking
                            )
                        }
                    }
                }
            }

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
                    || service.snapshot.updateAvailable != true
                    || service.snapshot.artifactAvailable == false
                )
            }
        }
        .padding(14)
        .frame(width: 330)
        .onAppear {
            service.refreshFromDisk()
            service.requestCachedCheck()
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