import AppKit
import Foundation
import SwiftUI

public struct PetSettingsCard: View {
    @ObservedObject private var localization = AppLocalization.shared
    @ObservedObject private var state: OverlayState
    @State private var entries: [PetCatalogEntry] = []
    @State private var selectedID: String = "default"
    @State private var isLoading = false
    @State private var applyingID: String?
    @State private var message: String?
    @State private var isError = false

    public init(state: OverlayState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 5) {
                Label(L("Pet appearance", "宠物外观"), systemImage: "pawprint.fill")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.84))
                Spacer()
                if isLoading {
                    ProgressView().controlSize(.mini)
                }
                Button(action: refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .disabled(isLoading || applyingID != nil)
                .accessibilityLabel(L("Refresh pet list", "刷新宠物列表"))
            }

            Text(L(
                "Click to switch instantly. Built-in pets work offline.",
                "点击切换，立即生效；内置宠物无需下载。"
            ))
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.7))

            if isLoading && entries.isEmpty {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(L("Reading installed pets…", "正在读取已安装宠物…"))
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, minHeight: 54)
            } else if entries.isEmpty, let message {
                VStack(alignment: .leading, spacing: 7) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundColor(.orange.opacity(0.88))
                    Button(L("Retry", "重试"), action: refresh)
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(OverlayTheme.accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 7), count: 3), spacing: 7) {
                    ForEach(PetCatalogParser.ordered(entries)) { entry in
                        petOption(entry)
                    }
                }
            }

            if let message, !entries.isEmpty {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isError ? .orange : .green)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
        )
        .onAppear(perform: refresh)
    }

    @ViewBuilder
    private func petOption(_ entry: PetCatalogEntry) -> some View {
        let isSelected = selectedID == entry.id
        Button {
            select(entry)
        } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    PetThumbnail(entry: entry)
                        .frame(height: 58)
                    if applyingID == entry.id {
                        ProgressView().controlSize(.mini)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(OverlayTheme.accent)
                    }
                }
                Text(entry.id == "default" ? L("Original bubble", "原始悬浮球") : entry.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(entry.id == "dasheng" ? L("Default", "默认") : (entry.id == "default" ? L("Classic", "经典") : (entry.preset ? L("Built-in", "内置") : L("Custom", "自定义"))))
                    .font(.system(size: 10))
                    .foregroundColor(entry.id == "dasheng" ? OverlayTheme.accent : OverlayTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(9)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(isSelected ? OverlayTheme.accent.opacity(0.1) : Color.white.opacity(0.025))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11)
                            .stroke(isSelected ? OverlayTheme.accent.opacity(0.38) : Color.white.opacity(0.06), lineWidth: 0.8)
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isLoading || applyingID != nil)
        .help("\(entry.description) (\(entry.id))")
        .accessibilityLabel(L("Use \(entry.displayName)", "使用 \(entry.displayName)"))
        .accessibilityValue(isSelected ? L("Selected", "已选择") : "")
    }

    private func refresh() {
        guard !isLoading, applyingID == nil else { return }
        isLoading = true
        isError = false
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let parsed = try PetCatalogService.list()
                DispatchQueue.main.async {
                    entries = parsed
                    selectedID = parsed.first(where: { $0.current })?.id ?? state.petResource?.id ?? "default"
                    isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    isLoading = false
                    isError = true
                    message = error.localizedDescription
                }
            }
        }
    }

    private func select(_ entry: PetCatalogEntry) {
        guard applyingID == nil, selectedID != entry.id else { return }
        applyingID = entry.id
        isError = false
        message = nil
        let id = entry.id
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try PetCatalogService.select(id)
                DispatchQueue.main.async {
                    state.reloadPetAsync { outcome in
                        applyingID = nil
                        if outcome.accepted {
                            selectedID = outcome.selectedID
                            message = L("Using \(entry.displayName).", "正在使用 \(entry.displayName)。")
                            isError = false
                        } else {
                            selectedID = ""
                            isError = true
                            message = outcome.error ?? L("The selected pet could not be loaded.", "无法加载所选宠物。")
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    applyingID = nil
                    isError = true
                    message = error.localizedDescription
                }
            }
        }
    }
}

private struct PetThumbnail: View {
    let entry: PetCatalogEntry
    @State private var image: CGImage?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1, orientation: .up)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .padding(4)
            } else if entry.id == "default" {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(OverlayTheme.accent.opacity(0.78))
            } else if isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundColor(OverlayTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: load)
    }

    private func load() {
        guard entry.id != "default", image == nil, !isLoading else { return }
        isLoading = true
        let id = entry.id
        DispatchQueue.global(qos: .utility).async {
            let loaded = try? PetResourceStore().thumbnail(for: id)
            DispatchQueue.main.async {
                guard entry.id == id else { return }
                image = loaded ?? nil
                isLoading = false
            }
        }
    }
}
