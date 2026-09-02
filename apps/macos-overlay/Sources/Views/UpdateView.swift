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
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                    Text(L(
                        "The update is installed. Fully restart Codex to activate updated FlowPilot policy and hook snapshots.",
                        "更新已经安装。请完整重启 Codex，以激活新的 FlowPilot 策略和 Hook 快照。"
                    ))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
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
                .disabled(service.isChecking || service.isInstalling)

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
