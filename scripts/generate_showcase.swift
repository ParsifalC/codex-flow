import Cocoa
import SwiftUI
import CoreGraphics

private enum ShowcaseMetrics {
    // Keep showcase captures aligned with OverlayRootView / OverlayWindowController.
    static let panelWidth: CGFloat = 384
    static let panelHeight: CGFloat = 490
}

@MainActor
func renderViewToPNG<V: View>(
    view: V,
    targetWidth: CGFloat? = nil,
    targetHeight: CGFloat? = nil,
    scale: CGFloat = 2.0,
    requiresLiveHosting: Bool = false,
    settleTime: TimeInterval = 0.18,
    outputPath: String
) {
    let darkView = view.preferredColorScheme(.dark)

    let sizedView: AnyView
    if let w = targetWidth, let h = targetHeight {
        sizedView = AnyView(darkView.frame(width: w, height: h))
    } else if let w = targetWidth {
        sizedView = AnyView(darkView.frame(width: w))
    } else if let h = targetHeight {
        sizedView = AnyView(darkView.frame(height: h))
    } else {
        sizedView = AnyView(darkView)
    }

    // Pure SwiftUI rendering stays the fastest path for simple assets. Views that
    // contain ScrollView / GeometryReader use live AppKit hosting below so they
    // receive the same viewport/layout lifecycle as the real overlay window.
    if !requiresLiveHosting {
        let renderer = ImageRenderer(content: sizedView)
        renderer.scale = scale

        guard let cgImage = renderer.cgImage else {
            print("❌ ImageRenderer failed for \(outputPath)")
            return
        }

        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            print("❌ Failed to encode PNG for \(outputPath)")
            return
        }

        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? pngData.write(to: url)
        print("✅ Rendered [\(cgImage.width)x\(cgImage.height)] -> \(outputPath)")
        return
    }

    let hostingView = NSHostingView(rootView: sizedView)
    let initialFitting = hostingView.fittingSize
    var width = targetWidth ?? max(initialFitting.width, 10)
    var height = targetHeight ?? max(initialFitting.height, 10)
    var contentRect = NSRect(x: 0, y: 0, width: width, height: height)
    hostingView.frame = contentRect

    let window = NSWindow(
        contentRect: contentRect,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.appearance = NSAppearance(named: .darkAqua)
    window.backgroundColor = .clear
    window.isOpaque = false
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()

    RunLoop.current.run(until: Date(timeIntervalSinceNow: settleTime))
    window.layoutIfNeeded()
    hostingView.layoutSubtreeIfNeeded()

    // Dynamic full-height surfaces need one post-layout fitting pass. Fixed
    // 384×490 window captures keep the exact production viewport dimensions.
    if targetWidth == nil || targetHeight == nil {
        let settledFitting = hostingView.fittingSize
        if targetWidth == nil { width = max(settledFitting.width, 10) }
        if targetHeight == nil { height = max(settledFitting.height, 10) }
        contentRect = NSRect(x: 0, y: 0, width: width, height: height)
        hostingView.frame = contentRect
        window.setContentSize(contentRect.size)
        window.layoutIfNeeded()
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.08))
    }

    let pixelsWide = max(1, Int((width * scale).rounded()))
    let pixelsHigh = max(1, Int((height * scale).rounded()))
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        print("❌ Failed to allocate bitmap for \(outputPath)")
        return
    }
    rep.size = NSSize(width: width, height: height)
    hostingView.cacheDisplay(in: contentRect, to: rep)

    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        print("❌ Failed to encode PNG for \(outputPath)")
        return
    }

    let url = URL(fileURLWithPath: outputPath)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    try? pngData.write(to: url)
    print("✅ Rendered live [\(rep.pixelsWide)x\(rep.pixelsHigh)] -> \(outputPath)")
}

// MARK: - Deterministic Showcase Data

private enum ShowcaseMockData {
    static var account: AccountSnapshot {
        let now = Date()
        return AccountSnapshot(
            accountType: "chatgpt",
            email: "showcase@flowpilot.dev",
            planType: "plus",
            requiresOpenAIAuth: false,
            quotaWindows: [
                AccountQuotaWindow(
                    id: "showcase-5h",
                    durationMinutes: 300,
                    usedPercent: 38,
                    resetsAt: now.addingTimeInterval(2 * 3600 + 18 * 60)
                ),
                AccountQuotaWindow(
                    id: "showcase-weekly",
                    durationMinutes: 10080,
                    usedPercent: 52,
                    resetsAt: now.addingTimeInterval(4 * 86_400 + 6 * 3600)
                )
            ],
            resetCreditCount: 3,
            resetCredits: [],
            hasCredits: true,
            unlimitedCredits: false,
            creditsBalance: "120",
            spendControlReached: false,
            rateLimitReachedType: nil,
            fetchedAt: now
        )
    }

    static let strategy = StrategyModeSnapshot(
        configured: "balanced",
        routing: "adaptive",
        valid: true,
        profiles: [
            StrategyProfileInfo(name: "efficient", description: "Minimize quota waste and expensive parent usage."),
            StrategyProfileInfo(name: "balanced", description: "Balance quality, quota, and latency."),
            StrategyProfileInfo(name: "quality", description: "Maximize correctness and independent verification."),
            StrategyProfileInfo(name: "speed", description: "Minimize wall-clock time with safe parallelism.")
        ]
    )
}

// MARK: - Account Showcase Chrome

/// Showcase-only Account surface. It mirrors the real Account tab visually but
/// deliberately consumes fixed mock snapshots so promotional rendering never
/// depends on Codex app-server, local strategy commands, or request timing.
struct AccountPromoCard: View {
    @ObservedObject var state: OverlayState
    var isFullHeight: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                FlowPilotLogoView(size: 29, showGlow: true, withBolt: false, text: "FP")
                    .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 0) {
                    Text("FlowPilot")
                        .font(.system(size: 11.5, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    Text("Account & Limits")
                        .font(.system(size: 7.8, weight: .medium, design: .rounded))
                        .foregroundColor(.cyan.opacity(0.85))
                }

                Spacer()

                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .frame(width: 23, height: 23)
                    .background(Circle().fill(Color.white.opacity(0.045)))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)

            Divider().background(Color.white.opacity(0.07))

            HStack(spacing: 4) {
                promoTab("Inspector", "bolt.fill", false)
                promoTab("History", "clock.arrow.circlepath", false)
                promoTab("Analytics", "chart.bar.xaxis", false)
                promoTab("Account", "person.crop.circle.fill", true)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Color.black.opacity(0.14))

            Divider().background(Color.white.opacity(0.06))

            ShowcaseAccountView(
                state: state,
                snapshot: ShowcaseMockData.account,
                strategy: ShowcaseMockData.strategy,
                isFullHeight: isFullHeight
            )
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.055, green: 0.062, blue: 0.085).opacity(0.98),
                            Color(red: 0.035, green: 0.041, blue: 0.058).opacity(0.98)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: .black.opacity(0.48), radius: 18, y: 8)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
        )
    }

    private func promoTab(_ title: String, _ icon: String, _ selected: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 8.8, weight: .semibold))
            Text(title)
                .font(.system(size: 9.0, weight: selected ? .bold : .medium, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundColor(selected ? .white : .white.opacity(0.52))
        .frame(maxWidth: .infinity, minHeight: 26)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.cyan.opacity(0.22) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? Color.cyan.opacity(0.32) : Color.clear, lineWidth: 0.6)
                )
        )
    }
}

private struct ShowcaseAccountView: View {
    @ObservedObject var state: OverlayState
    let snapshot: AccountSnapshot
    let strategy: StrategyModeSnapshot
    let isFullHeight: Bool

    var body: some View {
        let content = VStack(spacing: 9) {
            accountHeader
            identityCard
            quotaCard
            resetCard
            accountFactsCard
            ShowcaseStrategyModeCard(snapshot: strategy)
            ShowcaseAutostartCard()
        }
        .padding(.vertical, 2)

        return Group {
            if isFullHeight {
                content
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    content
                }
                .frame(maxHeight: 390)
            }
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 9) {
            FlowPilotLogoView(size: 42, showGlow: true, withBolt: false, text: "FP")
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text(L("Account & Limits", "账户与额度"))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text(L("Account data from Codex · strategy from FlowPilot policy", "账户数据来自 Codex · 策略来自 FlowPilot 配置"))
                    .font(.system(size: 8.5))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            Image(systemName: "arrow.clockwise")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(.cyan)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.cyan.opacity(0.12)))
        }
    }

    private var identityCard: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("CURRENT PLAN", "当前 PLAN"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(planDisplayName(snapshot.planType))
                    .font(.system(size: 16, weight: .heavy, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [.cyan, .indigo], startPoint: .leading, endPoint: .trailing))
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text(accountTypeDisplayName(snapshot.accountType))
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.07)))

                if let email = snapshot.email, !email.isEmpty {
                    HoverRevealText(
                        email,
                        font: .system(size: 8.5),
                        foregroundColor: .white.opacity(0.48),
                        lineLimit: 1,
                        privacyBlur: state.isPrivacyMode,
                        popoverWidth: 300
                    )
                    .frame(maxWidth: 190, alignment: .trailing)
                }
            }
        }
        .padding(9)
        .background(cardBackground)
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L("Current quota", "当前额度"), systemImage: "gauge.with.needle.fill")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.82))

            ForEach(snapshot.orderedWindows) { window in
                quotaRow(window)
            }
        }
        .padding(9)
        .background(cardBackground)
    }

    private func quotaRow(_ window: AccountQuotaWindow) -> some View {
        let used = window.usedPercent.map { max(0, min(100, $0)) }
        let remaining = window.remainingPercent
        let remainingFraction = max(0, min(1, (remaining ?? 0) / 100.0))
        let pressure = used ?? 0
        let accent: Color = pressure >= 85 ? .orange : (pressure >= 60 ? .yellow : .cyan)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(window.compactName)
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(accent)
                    .frame(width: 48, alignment: .leading)
                Text(window.displayName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(.white.opacity(0.72))
                Spacer()
                if let remaining {
                    Text(String(format: L("%.0f%% left", "剩余 %.0f%%"), remaining))
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(accent)
                }
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(accent)
                        .frame(width: proxy.size.width * CGFloat(remainingFraction))
                }
            }
            .frame(height: 4)

            HStack {
                if let used {
                    Text(String(format: L("Used %.0f%%", "已用 %.0f%%"), used))
                        .font(.system(size: 7.8))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
                Text(window.resetsAt.map { L("Resets \(formatAccountDate($0))", "\(formatAccountDate($0)) 重置") } ?? L("Reset time unavailable", "重置时间未返回"))
                    .font(.system(size: 7.8, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.52))
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
            }
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.025)))
    }

    private var resetCard: some View {
        HStack(spacing: 8) {
            VStack(alignment: .center, spacing: 3) {
                Text(L("RESET CREDITS AVAILABLE", "可用重置次数"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(snapshot.resetCreditCount.map(String.init) ?? "—")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundColor(.cyan)
            }

            Divider().frame(height: 30).overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("NEXT CREDIT EXPIRY", "重置次数到期"))
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.42))
                Text(L("Available on demand", "按需可用"))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.75))
            }
            Spacer()
        }
        .padding(9)
        .background(cardBackground)
    }

    private var accountFactsCard: some View {
        VStack(spacing: 5) {
            factRow(L("Credits", "Credits"), snapshot.creditsBalance.map { "\($0) credits" } ?? "—")
            factRow(L("Rate limit state", "限额状态"), L("Normal", "正常"))
            factRow(L("Spend control", "消费控制"), L("Normal", "正常"))
            factRow(L("OpenAI auth", "OpenAI 认证"), L("Not required", "不需要"))
            factRow(L("Last refreshed", "最后刷新"), formatAccountDate(snapshot.fetchedAt))
        }
        .padding(9)
        .background(cardBackground)
    }

    private func factRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.78))
                .lineLimit(1)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.white.opacity(0.04))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
    }

    private func planDisplayName(_ raw: String?) -> String {
        switch raw?.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case .some(let value): return value.replacingOccurrences(of: "_", with: " ").capitalized
        case .none: return L("Not reported", "未返回")
        }
    }

    private func accountTypeDisplayName(_ raw: String?) -> String {
        switch raw {
        case "chatgpt": return "ChatGPT"
        case "apiKey": return "API Key"
        case "amazonBedrock": return "Bedrock"
        default: return raw ?? L("Account", "账户")
        }
    }
}

private struct ShowcaseStrategyModeCard: View {
    let snapshot: StrategyModeSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Label(L("Global strategy mode", "全局策略模式"), systemImage: "slider.horizontal.3")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
                Spacer()
                if let routing = snapshot.routing, !routing.isEmpty {
                    Text(localizedRoutingName(routing))
                        .font(.system(size: 6.8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.42))
                }
                Text(localizedConfiguredName)
                    .font(.system(size: 7.5, weight: .heavy, design: .rounded))
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.cyan.opacity(0.12)))

                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.32))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(snapshot.profiles) { profile in
                    strategyTile(profile)
                }
            }

            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 7.5))
                    .padding(.top, 1)
                Text(L("Repository policy can override this global strategy for individual tasks.", "具体仓库策略可以覆盖此全局模式。"))
                    .font(.system(size: 7.5))
            }
            .foregroundColor(.white.opacity(0.35))
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
        )
    }

    private var localizedConfiguredName: String {
        snapshot.profiles.first(where: { $0.name == snapshot.configured })?.localizedName
            ?? snapshot.configured.capitalized
    }

    private func localizedRoutingName(_ routing: String) -> String {
        switch routing.lowercased() {
        case "adaptive": return L("Adaptive", "自适应")
        case "direct": return L("Direct", "直接")
        case "delegate": return L("Delegate", "委派")
        default: return routing.capitalized
        }
    }

    private func strategyTile(_ profile: StrategyProfileInfo) -> some View {
        let selected = profile.name == snapshot.configured
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: profile.iconName)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(profile.accent)
                Text(profile.localizedName)
                    .font(.system(size: 8.8, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(selected ? 0.95 : 0.72))
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 8.5))
                        .foregroundColor(profile.accent)
                }
            }
            Text(profile.localizedDescription)
                .font(.system(size: 7.3))
                .foregroundColor(.white.opacity(0.38))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? profile.accent.opacity(0.12) : Color.white.opacity(0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(selected ? profile.accent.opacity(0.45) : Color.white.opacity(0.055), lineWidth: 0.7)
                )
        )
    }
}

private struct ShowcaseAutostartCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "power.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.green)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Launch at Login", "登录时启动"))
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.84))
                    Text(L("Enabled · starts automatically on next login", "已开启 · 下次登录自动启动"))
                        .font(.system(size: 7.6))
                        .foregroundColor(.white.opacity(0.42))
                }

                Spacer()

                HStack(spacing: 3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 7.5, weight: .bold))
                    Text(L("ON", "开"))
                        .font(.system(size: 7.2, weight: .heavy, design: .rounded))
                }
                .foregroundColor(.green)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.green.opacity(0.14)))

                Toggle("", isOn: .constant(true))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(.green)
                    .disabled(true)
            }

            HStack(spacing: 4) {
                Image(systemName: "info.circle")
                    .font(.system(size: 7.2))
                Text(L(
                    "Registered as a user LaunchAgent; enabling it affects the next login and does not restart the current widget.",
                    "使用用户级 LaunchAgent 注册；开启后从下次登录生效，不会重启当前悬浮窗。"
                ))
                    .font(.system(size: 7.2))
            }
            .foregroundColor(.white.opacity(0.3))
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.04))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.08), lineWidth: 0.8))
        )
    }
}

// MARK: - Promotional Graphic Composers

struct PosterPromoView: View {
    var stateInspector: OverlayState
    var stateHistory: OverlayState
    var stateAnalytics: OverlayState
    var stateAccount: OverlayState
    var stateBubble: OverlayState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.11),
                    Color(red: 0.08, green: 0.09, blue: 0.16),
                    Color(red: 0.03, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.cyan.opacity(0.12))
                .blur(radius: 120)
                .frame(width: 650, height: 650)
                .offset(x: -620, y: -260)

            Circle()
                .fill(Color(red: 0.6, green: 0.2, blue: 0.9).opacity(0.12))
                .blur(radius: 140)
                .frame(width: 720, height: 720)
                .offset(x: 600, y: 240)

            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        FlowPilotLogoView(size: 44, showGlow: true, withBolt: true)
                        Text("FlowPilot macOS Native Widget")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                    }

                    Text("Inspector · History · Analytics · Account · Privacy-blurred Showcase")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.top, 28)

                HStack(alignment: .top, spacing: 18) {
                    promoColumn(
                        icon: "bolt.fill",
                        title: "⚡️ Inspector (实时巡检)",
                        tint: .cyan,
                        view: AnyView(SummaryView(state: stateInspector, isFullHeight: true))
                    )

                    promoColumn(
                        icon: "clock.arrow.circlepath",
                        title: "📜 History (历史回溯)",
                        tint: .indigo,
                        view: AnyView(SummaryView(state: stateHistory, isFullHeight: true))
                    )

                    promoColumn(
                        icon: "chart.bar.xaxis",
                        title: "📊 Analytics (效能看板)",
                        tint: Color(red: 0.95, green: 0.35, blue: 0.8),
                        view: AnyView(SummaryView(state: stateAnalytics, isFullHeight: true))
                    )

                    promoColumn(
                        icon: "person.crop.circle.fill",
                        title: "👤 Account (账户与额度)",
                        tint: .teal,
                        view: AnyView(AccountPromoCard(state: stateAccount, isFullHeight: true))
                    )
                }

                HStack(spacing: 18) {
                    BubbleView(state: stateBubble)
                        .scaleEffect(0.88)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("🟢 灵动微胶囊 (Micro Capsule)")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        Text("闲置自动吸附屏幕边缘；宣传物料默认强制隐私模式，敏感项目、任务与账户标识统一做真实模糊处理。")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.6))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
                .padding(.bottom, 28)
            }
        }
        .frame(width: 1740)
    }

    private func promoColumn(icon: String, title: String, tint: Color, view: AnyView) -> some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: icon).foregroundColor(tint)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }

            view
                .frame(width: ShowcaseMetrics.panelWidth)
                .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
    }
}

struct StrategiesPromoView: View {
    var stateBubble: OverlayState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.11),
                    Color(red: 0.08, green: 0.09, blue: 0.16),
                    Color(red: 0.03, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Dynamic Ambient Glows
            Circle()
                .fill(Color.green.opacity(0.10))
                .blur(radius: 130)
                .frame(width: 520, height: 520)
                .offset(x: -600, y: -60)

            Circle()
                .fill(Color.cyan.opacity(0.10))
                .blur(radius: 130)
                .frame(width: 520, height: 520)
                .offset(x: -200, y: -60)

            Circle()
                .fill(Color.purple.opacity(0.10))
                .blur(radius: 140)
                .frame(width: 540, height: 540)
                .offset(x: 200, y: 60)

            Circle()
                .fill(Color.orange.opacity(0.10))
                .blur(radius: 130)
                .frame(width: 520, height: 520)
                .offset(x: 600, y: 60)

            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        FlowPilotLogoView(size: 46, showGlow: true, withBolt: true)
                        Text("FlowPilot · 多 Agent 协同策略矩阵")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                    }

                    Text("智能解耦 · 动态自适应路由 · 兼顾成本与极限正确性的 4 种编排策略")
                        .font(.system(size: 14.5, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.68))
                }
                .padding(.top, 32)

                // 4 Strategy Cards
                HStack(alignment: .top, spacing: 16) {
                    strategyCard(
                        name: "Efficient",
                        chineseName: "高效模式",
                        tag: "额度优先 · 极简消耗",
                        icon: "leaf.fill",
                        accent: .green,
                        badgeText: "最省配额",
                        objective: "专为控制成本与长效编码设计。压低昂贵 Parent 模型介入，把繁重的深入编写与报错修复精准下沉给高效 Worker。",
                        budget: "5 Agents",
                        budgetDetail: "2 探索 / 2 执行 / 1 评审",
                        modelPolicy: "latest-efficient",
                        modelSub: "全链路低成本模型",
                        reasoning: "Parent 节能 / Worker xhigh",
                        reasoningSub: "Worker 推理高于 Parent",
                        quotaElasticity: "高敏感 (主动收敛)",
                        quotaSub: "配额紧张自动缩减探索",
                        mechanisms: [
                            "小任务直连，深执行下沉 Worker",
                            "积极裁撤冗余只读探索与无效开销",
                            "配额紧张时自动收敛试探性分叉"
                        ],
                        scenarios: "日常轻中度编码 · 探索查错 · 额度预算受限",
                        cliCommand: "codex-flow strategy set efficient"
                    )

                    strategyCard(
                        name: "Balanced",
                        chineseName: "均衡模式",
                        tag: "效能与质量并重",
                        icon: "scale.3d",
                        accent: .cyan,
                        badgeText: "黄金默认 ★",
                        objective: "任务全能的黄金基准。在交付质量、配额消耗与响应延迟之间维持最佳动态平衡，自适应大多数复杂工程任务。",
                        budget: "5 Agents",
                        budgetDetail: "3 探索 / 3 执行 / 1 评审",
                        modelPolicy: "Parent 掌舵 + Worker 提效",
                        modelSub: "双层混合解耦架构",
                        reasoning: "Parent high / Worker xhigh",
                        reasoningSub: "Worker 推理稳固高于 Parent",
                        quotaElasticity: "平滑缓冲 (动态调节)",
                        quotaSub: "兼顾交付确定性与配额安全",
                        mechanisms: [
                            "中度并行探索，最多 3 路隔离编写",
                            "Worker 推理深度稳固高于 Parent",
                            "通用工程任务的最佳默认生产策略"
                        ],
                        scenarios: "全栈功能开发 · 多文件协作 · 标准 PR",
                        cliCommand: "codex-flow strategy set balanced"
                    )

                    strategyCard(
                        name: "Quality",
                        chineseName: "质量模式",
                        tag: "正确性至上 · 深度验证",
                        icon: "checkmark.seal.fill",
                        accent: .purple,
                        badgeText: "零缺陷交付",
                        objective: "追求零缺陷交付。支持 Normal / Strong / Absolute 三级质量意图；在关键执行与评审环节拉满推理，关键角色按需升级至顶配模型。",
                        budget: "6～8 Agents",
                        budgetDetail: "4 探索 / 3～4 执行 / 2 独立评审",
                        modelPolicy: "升级 latest-capable",
                        modelSub: "关键角色升至顶配模型",
                        reasoning: "全流程锁定 xhigh / max",
                        reasoningSub: "拉满推理阶梯极限思考",
                        quotaElasticity: "质量锁定 (质量不妥协)",
                        quotaSub: "绝不因配额压缩推理与评审",
                        mechanisms: [
                            "支持 normal / strong / absolute 三级意图",
                            "关键 Implementer / Reviewer 升级顶配模型",
                            "启用 2 位独立评审员交叉独立验证"
                        ],
                        scenarios: "核心底层架构 · 生产 Bug · 安全合规",
                        cliCommand: "codex-flow strategy set quality"
                    )

                    strategyCard(
                        name: "Speed",
                        chineseName: "速度模式",
                        tag: "极速交付 · 饱和并发",
                        icon: "bolt.fill",
                        accent: .orange,
                        badgeText: "极速吞吐 🚀",
                        objective: "突破耗时瓶颈。在经算法验证的完全隔离无冲突工作流上，饱和调度并发 Worker 线程并行编写，大幅缩减端到端耗时。",
                        budget: "8 Agents",
                        budgetDetail: "4 探索 / 8 执行 / 1 评审",
                        modelPolicy: "高并发 latest-efficient",
                        modelSub: "饱和并行高速工作流集群",
                        reasoning: "标准深度 · 激进并发",
                        reasoningSub: "最大化并发吞吐率",
                        quotaElasticity: "时间优先 (时间换产能)",
                        quotaSub: "以最快时钟完成任务收敛",
                        mechanisms: [
                            "严格隔离的多可写工作流饱和并发",
                            "并发上限根据可写流动态拉满至 8",
                            "绝不发生覆写冲突，极致压缩端到端耗时"
                        ],
                        scenarios: "批量脚手架 · 独立模块并行 · Hotfix",
                        cliCommand: "codex-flow strategy set speed"
                    )
                }
                .padding(.horizontal, 54)

                // Footer Banner: Core Architecture Highlights
                HStack(spacing: 20) {
                    BubbleView(state: stateBubble)
                        .scaleEffect(0.85)

                    Divider()
                        .background(Color.white.opacity(0.12))
                        .frame(height: 30)

                    featureHighlightItem(
                        icon: "brain.head.profile",
                        title: "动态自适应路由",
                        subtitle: "复杂度意图感知 · 自动匹配路线",
                        tint: .cyan
                    )

                    Divider()
                        .background(Color.white.opacity(0.08))
                        .frame(height: 24)

                    featureHighlightItem(
                        icon: "slider.horizontal.2.square",
                        title: "能力与推理深度解耦",
                        subtitle: "Worker 与 Parent 分工 · 高效模型拉满推理",
                        tint: .purple
                    )

                    Divider()
                        .background(Color.white.opacity(0.08))
                        .frame(height: 24)

                    featureHighlightItem(
                        icon: "shield.lefthalf.filled",
                        title: "确定性写入隔离屏障",
                        subtitle: "Speed 饱和并发绝无写入冲突",
                        tint: .green
                    )

                    Divider()
                        .background(Color.white.opacity(0.08))
                        .frame(height: 24)

                    featureHighlightItem(
                        icon: "macwindow.badge.plus",
                        title: "macOS 浮窗即时调控",
                        subtitle: "桌面悬浮胶囊与菜单界面实时热切换",
                        tint: .orange
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .frame(width: 1632)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 1)
                        )
                )
                .padding(.bottom, 32)
            }
        }
        .frame(width: 1740)
    }

    private func strategyCard(
        name: String,
        chineseName: String,
        tag: String,
        icon: String,
        accent: Color,
        badgeText: String,
        objective: String,
        budget: String,
        budgetDetail: String,
        modelPolicy: String,
        modelSub: String,
        reasoning: String,
        reasoningSub: String,
        quotaElasticity: String,
        quotaSub: String,
        mechanisms: [String],
        scenarios: String,
        cliCommand: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header: Icon + Name + Badge
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(accent.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(accent.opacity(0.4), lineWidth: 1))
                        .frame(width: 38, height: 38)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(accent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(chineseName)
                            .font(.system(size: 16.5, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                        Text(name)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.5))
                    }
                    Text(tag)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(accent)
                }

                Spacer()

                Text(badgeText)
                    .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                    .foregroundColor(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(accent.opacity(0.14)))
                    .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 0.8))
            }

            // Objective Text
            Text(objective)
                .font(.system(size: 11.2, weight: .regular))
                .foregroundColor(.white.opacity(0.78))
                .lineSpacing(3.5)
                .fixedSize(horizontal: false, vertical: true)

            // Specs Grid (2x2)
            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    metricBadge(label: "并发上限 (Budget)", value: budget, subvalue: budgetDetail, tint: accent)
                    metricBadge(label: "模型政策 (Policy)", value: modelPolicy, subvalue: modelSub, tint: .white.opacity(0.92))
                }
                HStack(spacing: 6) {
                    metricBadge(label: "推理深度 (Reasoning)", value: reasoning, subvalue: reasoningSub, tint: .white.opacity(0.92))
                    metricBadge(label: "配额弹性 (Elasticity)", value: quotaElasticity, subvalue: quotaSub, tint: accent)
                }
            }

            // Core Mechanisms List
            VStack(alignment: .leading, spacing: 6) {
                Text("核心编排机制")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.48))
                    .textCase(.uppercase)

                ForEach(mechanisms, id: \.self) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 9.5))
                            .foregroundColor(accent.opacity(0.9))
                            .padding(.top, 2)
                        Text(item)
                            .font(.system(size: 10.8, weight: .medium))
                            .foregroundColor(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.03))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.8))
            )

            // Recommended Scenario Footer
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "target")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(accent)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text("推荐适用场景")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.48))
                    Text(scenarios)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(accent.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(accent.opacity(0.22), lineWidth: 0.8))
            )

            // CLI command hint
            HStack(spacing: 5) {
                Text("$")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(accent)
                Text(cliCommand)
                    .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                Text("一键热切换")
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.35))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color.black.opacity(0.35))
            .cornerRadius(6)
        }
        .padding(14)
        .frame(width: 396)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.08, green: 0.10, blue: 0.16).opacity(0.90))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.45),
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
        )
        .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
    }

    private func metricBadge(
        label: String,
        value: String,
        subvalue: String?,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundColor(.white.opacity(0.45))
            Text(value)
                .font(.system(size: 9.5, weight: .heavy, design: .rounded))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let subvalue {
                Text(subvalue)
                    .font(.system(size: 7.5, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private func featureHighlightItem(
        icon: String,
        title: String,
        subtitle: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                Text(subtitle)
                    .font(.system(size: 8.8, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }
}

struct BannerPromoView: View {
    var stateInspector: OverlayState
    var stateBubble: OverlayState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.13),
                    Color(red: 0.08, green: 0.09, blue: 0.18),
                    Color(red: 0.04, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 48) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 14) {
                        FlowPilotLogoView(size: 52, showGlow: true, withBolt: true)
                        Text("codex-flow")
                            .font(.system(size: 40, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                    }

                    Text("智能、高效、自适应的\nCodex 多 Agent 协同编排引擎")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                        .lineSpacing(5)

                    Text("Inspector · History · Analytics · Account")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))

                    VStack(alignment: .leading, spacing: 9) {
                        featurePill("brain.head.profile", "FlowPilot 动态自适应任务复杂度路由")
                        featurePill("chart.pie.fill", "确定性 Token 归因 + 实时 Quota 水位")
                        featurePill("person.crop.circle.fill", "账户级 Plan / 额度 / Reset / 每日消耗")
                        featurePill("eye.slash.fill", "宣传截图默认隐私模式，敏感信息统一模糊")
                    }

                    HStack(spacing: 14) {
                        BubbleView(state: stateBubble).scaleEffect(0.85)
                        Text("🟢 灵动微胶囊 · 闲置边缘吸附 · 状态光环")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .frame(width: 560)

                SummaryView(state: stateInspector, isFullHeight: false)
                    .frame(width: ShowcaseMetrics.panelWidth, height: ShowcaseMetrics.panelHeight)
                    .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 15)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 36)
        }
        .frame(width: 1340)
    }

    private func featurePill(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.cyan)
            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6.5)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.06)))
    }
}

struct DesktopScenePromoView: View {
    var stateInspector: OverlayState
    var stateBubble: OverlayState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.18),
                    Color(red: 0.14, green: 0.08, blue: 0.22),
                    Color(red: 0.05, green: 0.06, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack {
                HStack(spacing: 16) {
                    Image(systemName: "applelogo")
                    Text("Code").fontWeight(.bold)
                    Text("File")
                    Text("Edit")
                    Text("Selection")
                    Text("View")
                    Text("Go")
                    Text("Run")
                    Text("Terminal")
                    Text("Help")
                    Spacer()
                    Image(systemName: "sparkles").foregroundColor(.cyan)
                    Text("FlowPilot")
                    Image(systemName: "wifi")
                    Image(systemName: "battery.100")
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                Spacer()
            }

            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.15).opacity(0.95))
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                            Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                            Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
                            Text("SummaryView.swift — codex-flow")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                        }
                        Divider().background(Color.white.opacity(0.08))
                        Text("// FlowPilot adaptive multi-agent orchestration\npublic struct SummaryView: View {\n    @ObservedObject var state: OverlayState\n    ...\n}")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(.cyan.opacity(0.8))
                        Spacer()
                    }
                    .padding(16)
                )
                .frame(width: 820, height: 560)
                .offset(x: -180, y: 15)
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: -10, y: 15)

            SummaryView(state: stateInspector, isFullHeight: false)
                .frame(width: ShowcaseMetrics.panelWidth, height: ShowcaseMetrics.panelHeight)
                .scaleEffect(0.72)
                .offset(x: 320, y: 15)
                .shadow(color: Color.black.opacity(0.6), radius: 35, x: 5, y: 15)

            BubbleView(state: stateBubble)
                .scaleEffect(0.9)
                .offset(x: 600, y: -180)
                .shadow(color: Color.cyan.opacity(0.4), radius: 15)
        }
        .frame(width: 1280, height: 720)
    }
}

// MARK: - Main Execution

@MainActor
func runGenerator() {
    print("🎨 Starting FlowPilot privacy-blurred screenshot & promo generation...")

    let engine = TelemetryQueryEngine.shared
    let allRuns = engine.loadAllRuns()

    var latestRun = engine.loadLatestRun() ?? allRuns.first ?? TaskRun.previewSample
    engine.enrichRunIfNeeded(&latestRun)

    let historyChats = engine.fetchChatHistory(limit: 20)
    let historyRuns = engine.fetchHistory(limit: 50)
    let stats = engine.computeStats(days: 30, project: nil)

    let stateInspector = OverlayState()
    stateInspector.latestRun = latestRun
    stateInspector.inspectedRun = nil
    stateInspector.activeTab = .inspector
    stateInspector.isExpanded = true
    stateInspector.isPrivacyMode = true

    let stateHistoryFull = OverlayState()
    stateHistoryFull.latestRun = latestRun
    stateHistoryFull.historyChats = historyChats
    stateHistoryFull.historyRuns = historyRuns
    stateHistoryFull.activeTab = .history
    stateHistoryFull.isExpanded = true
    stateHistoryFull.isPrivacyMode = true
    stateHistoryFull.expandedChatIds = Set(historyChats.prefix(3).map { $0.sessionId })

    let stateHistoryPoster = OverlayState()
    stateHistoryPoster.latestRun = latestRun
    stateHistoryPoster.historyChats = Array(historyChats.prefix(3))
    stateHistoryPoster.historyRuns = historyRuns
    stateHistoryPoster.activeTab = .history
    stateHistoryPoster.isExpanded = true
    stateHistoryPoster.isPrivacyMode = true
    stateHistoryPoster.expandedChatIds = Set(historyChats.prefix(1).map { $0.sessionId })

    let stateAnalytics = OverlayState()
    stateAnalytics.latestRun = latestRun
    stateAnalytics.statsData = stats
    stateAnalytics.activeTab = .analytics
    stateAnalytics.isExpanded = true
    stateAnalytics.isPrivacyMode = true

    let stateAccount = OverlayState()
    stateAccount.latestRun = latestRun
    stateAccount.isExpanded = true
    stateAccount.isPrivacyMode = true

    let stateBubble = OverlayState()
    stateBubble.latestRun = latestRun
    stateBubble.isTaskRunning = false
    stateBubble.isExpanded = false
    stateBubble.isPrivacyMode = true

    renderViewToPNG(
        view: FlowPilotLogoView(size: 512, showGlow: true, withBolt: true),
        scale: 2.0,
        outputPath: "docs/assets/logo.png"
    )

    renderViewToPNG(
        view: FlowPilotLogoView(size: 256, showGlow: true, withBolt: true),
        scale: 1.0,
        outputPath: "docs/assets/logo_256.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateInspector, isFullHeight: true),
        targetWidth: ShowcaseMetrics.panelWidth,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/inspector_full.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateHistoryFull, isFullHeight: true),
        targetWidth: ShowcaseMetrics.panelWidth,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/history_full.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateAnalytics, isFullHeight: true),
        targetWidth: ShowcaseMetrics.panelWidth,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/analytics_full.png"
    )

    renderViewToPNG(
        view: BubbleView(state: stateBubble).padding(20),
        scale: 3.0,
        outputPath: "docs/assets/screenshots/capsule.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateInspector, isFullHeight: false),
        targetWidth: ShowcaseMetrics.panelWidth,
        targetHeight: ShowcaseMetrics.panelHeight,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/inspector_window.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateHistoryFull, isFullHeight: false),
        targetWidth: ShowcaseMetrics.panelWidth,
        targetHeight: ShowcaseMetrics.panelHeight,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/history_window.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateAnalytics, isFullHeight: false),
        targetWidth: ShowcaseMetrics.panelWidth,
        targetHeight: ShowcaseMetrics.panelHeight,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/analytics_window.png"
    )

    // Account remains deterministic mock data in the showcase pipeline. Live
    // hosting is used only for layout fidelity, never to trigger real account I/O.
    renderViewToPNG(
        view: AccountPromoCard(state: stateAccount, isFullHeight: true),
        targetWidth: ShowcaseMetrics.panelWidth,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/account_full.png"
    )

    renderViewToPNG(
        view: AccountPromoCard(state: stateAccount, isFullHeight: false),
        targetWidth: ShowcaseMetrics.panelWidth,
        targetHeight: ShowcaseMetrics.panelHeight,
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/screenshots/account_window.png"
    )

    renderViewToPNG(
        view: PosterPromoView(
            stateInspector: stateInspector,
            stateHistory: stateHistoryPoster,
            stateAnalytics: stateAnalytics,
            stateAccount: stateAccount,
            stateBubble: stateBubble
        ),
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/promo/flowpilot_promo_poster.png"
    )

    renderViewToPNG(
        view: BannerPromoView(
            stateInspector: stateInspector,
            stateBubble: stateBubble
        ),
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/promo/flowpilot_promo_banner.png"
    )

    renderViewToPNG(
        view: DesktopScenePromoView(
            stateInspector: stateInspector,
            stateBubble: stateBubble
        ),
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/promo/flowpilot_promo_desktop_scene.png"
    )

    renderViewToPNG(
        view: StrategiesPromoView(
            stateBubble: stateBubble
        ),
        scale: 2.0,
        requiresLiveHosting: true,
        outputPath: "docs/assets/promo/flowpilot_promo_strategies.png"
    )

    optimizeAssetsWithCrunch()
    print("✨ All privacy-blurred screenshots and promo graphics generated into docs/assets!")
}

func optimizeAssetsWithCrunch() {
    let crunchScript = "/usr/local/bin/crunch"
    let pngquantCandidates = ["/opt/homebrew/bin/pngquant", "/usr/local/bin/pngquant"]
    let pngquantPath = pngquantCandidates.first(where: { FileManager.default.fileExists(atPath: $0) })

    let outputFiles = [
        "docs/assets/logo.png",
        "docs/assets/logo_256.png",
        "docs/assets/screenshots/inspector_full.png",
        "docs/assets/screenshots/history_full.png",
        "docs/assets/screenshots/analytics_full.png",
        "docs/assets/screenshots/account_full.png",
        "docs/assets/screenshots/capsule.png",
        "docs/assets/screenshots/inspector_window.png",
        "docs/assets/screenshots/history_window.png",
        "docs/assets/screenshots/analytics_window.png",
        "docs/assets/screenshots/account_window.png",
        "docs/assets/promo/flowpilot_promo_poster.png",
        "docs/assets/promo/flowpilot_promo_banner.png",
        "docs/assets/promo/flowpilot_promo_desktop_scene.png",
        "docs/assets/promo/flowpilot_promo_strategies.png"
    ]

    if FileManager.default.fileExists(atPath: crunchScript) {
        print("🗜️ Optimizing generated PNG images with crunch...")
        for file in outputFiles {
            guard FileManager.default.fileExists(atPath: file) else { continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [crunchScript, file]
            try? process.run()
            process.waitUntilExit()

            let crunched = file.replacingOccurrences(of: ".png", with: "-crunch.png")
            if FileManager.default.fileExists(atPath: crunched) {
                try? FileManager.default.removeItem(atPath: file)
                try? FileManager.default.moveItem(atPath: crunched, toPath: file)
                print("✅ Compressed & replaced: \(file)")
            }
        }
    } else if let pngquant = pngquantPath {
        print("🗜️ Optimizing generated PNG images with pngquant...")
        for file in outputFiles {
            guard FileManager.default.fileExists(atPath: file) else { continue }
            let tempOut = file.replacingOccurrences(of: ".png", with: "-quant.png")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: pngquant)
            process.arguments = ["--quality=85-98", "--skip-if-larger", "--force", file, "--output", tempOut]
            try? process.run()
            process.waitUntilExit()

            if FileManager.default.fileExists(atPath: tempOut) {
                try? FileManager.default.removeItem(atPath: file)
                try? FileManager.default.moveItem(atPath: tempOut, toPath: file)
                print("✅ Compressed & replaced: \(file)")
            }
        }
    } else {
        print("⚠️ Neither crunch nor pngquant found, skipping compression.")
    }
}

@main
struct ShowcaseGenerator {
    static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            runGenerator()
            exit(0)
        }
        app.run()
    }
}
