import Cocoa
import SwiftUI
import CoreGraphics

@MainActor
func renderViewToPNG<V: View>(
    view: V,
    targetWidth: CGFloat? = nil,
    targetHeight: CGFloat? = nil,
    scale: CGFloat = 2.0,
    settleTime: TimeInterval = 0.45,
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

    // Keep the view attached to a real AppKit window so controls, AccountView's
    // onAppear refresh, menus and progress indicators all finish layout before
    // the snapshot is taken. Privacy-sensitive text is semantically redacted by
    // HoverRevealText before blur is applied, so bitmap snapshots stay private
    // even if an AppKit capture path drops the blur compositing effect.
    let hostingView = NSHostingView(rootView: sizedView)
    let fitting = hostingView.fittingSize
    let width = targetWidth ?? max(fitting.width, 10)
    let height = targetHeight ?? max(fitting.height, 10)
    let contentRect = NSRect(x: 0, y: 0, width: width, height: height)
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

    RunLoop.current.run(until: Date(timeIntervalSinceNow: settleTime))
    window.layoutIfNeeded()

    if let rep = hostingView.bitmapImageRepForCachingDisplay(in: contentRect) {
        hostingView.cacheDisplay(in: contentRect, to: rep)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outputPath)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? pngData.write(to: url)
            print("✅ Rendered [\(rep.pixelsWide)x\(rep.pixelsHigh)] -> \(outputPath)")
            return
        }
    }

    // Fallback remains useful for simple SwiftUI-only compositions.
    let renderer = ImageRenderer(content: sizedView)
    renderer.scale = scale
    if let cgImage = renderer.cgImage {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outputPath)
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? pngData.write(to: url)
            print("✅ Rendered fallback [\(cgImage.width)x\(cgImage.height)] -> \(outputPath)")
        }
    }
}

// MARK: - Account Showcase Chrome

/// Account is intentionally a UI-only fourth tab in SummaryView, so the normal
/// OverlayTab enum remains backward compatible. The showcase needs a deterministic
/// way to render that selected state without synthesizing mouse input, therefore
/// this wrapper reuses the real AccountView and mirrors the production chrome.
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

            AccountView(state: state, isFullHeight: isFullHeight)
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

                    Text("Inspector · History · Analytics · Account · Privacy-safe Showcase")
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
                        Text("闲置自动吸附屏幕边缘；宣传物料默认强制隐私模式，真实项目名、任务内容和账户标识不会进入截图像素。")
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
                .frame(width: 384)
                .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
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

            Circle()
                .fill(Color.cyan.opacity(0.15))
                .blur(radius: 120)
                .frame(width: 500, height: 500)
                .offset(x: -350)

            Circle()
                .fill(Color(red: 0.6, green: 0.2, blue: 0.9).opacity(0.15))
                .blur(radius: 140)
                .frame(width: 600, height: 600)
                .offset(x: 350)

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
                        featurePill("eye.slash.fill", "宣传截图默认隐私脱敏，不渲染敏感源文本")
                    }

                    HStack(spacing: 14) {
                        BubbleView(state: stateBubble).scaleEffect(0.85)
                        Text("🟢 灵动微胶囊 · 闲置边缘吸附 · 状态光环")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .frame(width: 560)

                SummaryView(state: stateInspector, isFullHeight: true)
                    .scaleEffect(0.92)
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

            SummaryView(state: stateInspector, isFullHeight: true)
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
    print("🎨 Starting FlowPilot privacy-safe screenshot & promo generation...")

    let engine = TelemetryQueryEngine.shared
    let allRuns = engine.loadAllRuns()

    var latestRun = engine.loadLatestRun() ?? allRuns.first
    if var run = latestRun {
        engine.enrichRunIfNeeded(&run)
        latestRun = run
    }

    let historyChats = engine.fetchChatHistory(limit: 20)
    let historyRuns = engine.fetchHistory(limit: 50)
    let stats = engine.computeStats(days: 30, project: nil)

    let stateInspector = OverlayState()
    stateInspector.latestRun = latestRun
    stateInspector.inspectedRun = latestRun
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

    // AccountView performs an async Codex app-server request on appearance. The
    // RPC itself may take up to four seconds, so account-containing captures get
    // a wider settle window than the purely local telemetry views.
    let accountSettleTime: TimeInterval = 5.0

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
        targetWidth: 384,
        scale: 2.0,
        outputPath: "docs/assets/screenshots/inspector_full.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateHistoryFull, isFullHeight: true),
        targetWidth: 384,
        scale: 2.0,
        outputPath: "docs/assets/screenshots/history_full.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateAnalytics, isFullHeight: true),
        targetWidth: 384,
        scale: 2.0,
        outputPath: "docs/assets/screenshots/analytics_full.png"
    )

    renderViewToPNG(
        view: AccountPromoCard(state: stateAccount, isFullHeight: true),
        targetWidth: 384,
        scale: 2.0,
        settleTime: accountSettleTime,
        outputPath: "docs/assets/screenshots/account_full.png"
    )

    renderViewToPNG(
        view: BubbleView(state: stateBubble).padding(20),
        scale: 3.0,
        outputPath: "docs/assets/screenshots/capsule.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateInspector, isFullHeight: false),
        targetWidth: 384,
        targetHeight: 490,
        scale: 2.0,
        outputPath: "docs/assets/screenshots/inspector_window.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateHistoryFull, isFullHeight: false),
        targetWidth: 384,
        targetHeight: 490,
        scale: 2.0,
        outputPath: "docs/assets/screenshots/history_window.png"
    )

    renderViewToPNG(
        view: SummaryView(state: stateAnalytics, isFullHeight: false),
        targetWidth: 384,
        targetHeight: 490,
        scale: 2.0,
        outputPath: "docs/assets/screenshots/analytics_window.png"
    )

    renderViewToPNG(
        view: AccountPromoCard(state: stateAccount, isFullHeight: false),
        targetWidth: 384,
        targetHeight: 490,
        scale: 2.0,
        settleTime: accountSettleTime,
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
        settleTime: accountSettleTime,
        outputPath: "docs/assets/promo/flowpilot_promo_poster.png"
    )

    renderViewToPNG(
        view: BannerPromoView(
            stateInspector: stateInspector,
            stateBubble: stateBubble
        ),
        scale: 2.0,
        outputPath: "docs/assets/promo/flowpilot_promo_banner.png"
    )

    renderViewToPNG(
        view: DesktopScenePromoView(
            stateInspector: stateInspector,
            stateBubble: stateBubble
        ),
        scale: 2.0,
        outputPath: "docs/assets/promo/flowpilot_promo_desktop_scene.png"
    )

    optimizeAssetsWithCrunch()
    print("✨ All privacy-safe screenshots and promo graphics generated into docs/assets!")
}

func optimizeAssetsWithCrunch() {
    let crunchScript = "/usr/local/bin/crunch"
    guard FileManager.default.fileExists(atPath: crunchScript) else {
        print("⚠️ /usr/local/bin/crunch not found, skipping compression.")
        return
    }

    print("🗜️ Optimizing generated PNG images with crunch...")
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
        "docs/assets/promo/flowpilot_promo_desktop_scene.png"
    ]

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
