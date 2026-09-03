import Cocoa
import SwiftUI
import CoreGraphics

@MainActor
func renderViewToPNG<V: View>(view: V, targetWidth: CGFloat? = nil, targetHeight: CGFloat? = nil, scale: CGFloat = 2.0, outputPath: String) {
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
    
    // Allow AppKit/SwiftUI to attach controls (Menu, TextField, ProgressView)
    // and resolve background fetch tasks cleanly
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
    
    if let rep = hostingView.bitmapImageRepForCachingDisplay(in: contentRect) {
        hostingView.cacheDisplay(in: contentRect, to: rep)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outputPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? pngData.write(to: url)
            print("✅ Rendered [\(rep.pixelsWide)x\(rep.pixelsHigh)] -> \(outputPath)")
            return
        }
    }
    
    let renderer = ImageRenderer(content: sizedView)
    renderer.scale = scale
    if let cgImage = renderer.cgImage {
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            let url = URL(fileURLWithPath: outputPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? pngData.write(to: url)
            print("✅ Rendered fallback [\(cgImage.width)x\(cgImage.height)] -> \(outputPath)")
        }
    }
}

// MARK: - Promotional Graphic Composers

struct PosterPromoView: View {
    var stateInspector: OverlayState
    var stateHistory: OverlayState
    var stateAnalytics: OverlayState
    var stateBubble: OverlayState
    
    var body: some View {
        ZStack {
            // Dark futuristic background
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.06, blue: 0.11),
                    Color(red: 0.08, green: 0.09, blue: 0.16),
                    Color(red: 0.03, green: 0.04, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Cyber glow orbs
            Circle()
                .fill(Color.cyan.opacity(0.12))
                .blur(radius: 120)
                .frame(width: 600, height: 600)
                .offset(x: -450, y: -250)
            
            Circle()
                .fill(Color(red: 0.6, green: 0.2, blue: 0.9).opacity(0.12))
                .blur(radius: 140)
                .frame(width: 700, height: 700)
                .offset(x: 450, y: 200)
            
            VStack(spacing: 20) {
                // Header Title & Badges
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        FlowPilotLogoView(size: 44, showGlow: true, withBolt: true)
                        
                        Text("FlowPilot macOS Native Widget")
                            .font(.system(size: 32, weight: .black, design: .rounded))
                            .foregroundColor(.white)
                    }
                    
                    Text("100% Native SwiftUI + AppKit · Zero-Cost Deterministic Telemetry · Ambient Quota Perception")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.65))
                }
                .padding(.top, 28)
                
                // 3 Main Column Cards
                HStack(alignment: .top, spacing: 24) {
                    // Column 1: Inspector (Live Task & Quota)
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.cyan)
                            Text("⚡️ Inspector (实时巡检)")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        SummaryView(state: stateInspector, isFullHeight: true)
                            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
                    }
                    
                    // Column 2: History (Task Timeline)
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.indigo)
                            Text("📜 History (历史回溯)")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        SummaryView(state: stateHistory, isFullHeight: true)
                            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
                    }
                    
                    // Column 3: Analytics (30-Day Efficiency)
                    VStack(spacing: 10) {
                        HStack {
                            Image(systemName: "chart.bar.xaxis")
                                .foregroundColor(Color(red: 0.95, green: 0.35, blue: 0.8))
                            Text("📊 Analytics (效能看板)")
                                .font(.system(size: 13.5, weight: .bold, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                        }
                        
                        SummaryView(state: stateAnalytics, isFullHeight: true)
                            .shadow(color: Color.black.opacity(0.45), radius: 24, x: 0, y: 12)
                    }
                }
                
                // Bottom Micro-Capsule Feature Callout
                HStack(spacing: 18) {
                    BubbleView(state: stateBubble)
                        .scaleEffect(0.88)
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("🟢 灵动微胶囊 (Micro Capsule)")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                        
                        Text("闲置时自动吸附屏幕边缘，动态彩虹呼吸光环实时感知任务运行态与最新消耗。")
                            .font(.system(size: 11, weight: .regular))
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
        .frame(width: 1360)
    }
}

struct BannerPromoView: View {
    var stateInspector: OverlayState
    var stateBubble: OverlayState
    
    var body: some View {
        ZStack {
            // Dark futuristic background
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.13),
                    Color(red: 0.08, green: 0.09, blue: 0.18),
                    Color(red: 0.04, green: 0.05, blue: 0.09)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Background glow
            Circle()
                .fill(Color.cyan.opacity(0.15))
                .blur(radius: 120)
                .frame(width: 500, height: 500)
                .offset(x: -350, y: 0)
            
            Circle()
                .fill(Color(red: 0.6, green: 0.2, blue: 0.9).opacity(0.15))
                .blur(radius: 140)
                .frame(width: 600, height: 600)
                .offset(x: 350, y: 0)
            
            HStack(spacing: 48) {
                // Left Column: Branding, Slogan, Highlights
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
                    
                    Text("让高能力模型负责规划决策，让更经济的 Worker 负责落地执行；\n只有任务确实需要时，才提高推理强度。")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(.white.opacity(0.65))
                        .lineSpacing(4)
                    
                    // Feature Pills
                    VStack(alignment: .leading, spacing: 9) {
                        featurePill(icon: "brain.head.profile", text: "FlowPilot 动态自适应任务复杂度路由")
                        featurePill(icon: "chart.pie.fill", text: "零开销确定性 Token 差值归因 + 实时 Quota 水位")
                        featurePill(icon: "macwindow.badge.plus", text: "SwiftUI + AppKit 100% 纯原生毛玻璃灵动悬浮窗")
                    }
                    .padding(.top, 6)
                    
                    HStack(spacing: 14) {
                        BubbleView(state: stateBubble)
                            .scaleEffect(0.85)
                        
                        Text("🟢 灵动微胶囊 · 闲置边缘吸附 · 状态光环")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    .padding(.top, 4)
                }
                .frame(width: 560)
                
                // Right Column: Actual Running Inspector Card
                SummaryView(state: stateInspector, isFullHeight: true)
                    .scaleEffect(0.92)
                    .shadow(color: Color.black.opacity(0.5), radius: 30, x: 0, y: 15)
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 36)
        }
        .frame(width: 1340)
    }
    
    private func featurePill(icon: String, text: String) -> some View {
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
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.06))
        )
    }
}

struct DesktopScenePromoView: View {
    var stateInspector: OverlayState
    var stateBubble: OverlayState
    
    var body: some View {
        ZStack {
            // macOS Wallpaper Gradient (Sonoma/Sequoia dark style)
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.10, blue: 0.18),
                    Color(red: 0.14, green: 0.08, blue: 0.22),
                    Color(red: 0.05, green: 0.06, blue: 0.12)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // macOS Menu Bar
            VStack {
                HStack(spacing: 16) {
                    Image(systemName: "applelogo")
                        .font(.system(size: 13))
                    Text("Code")
                        .font(.system(size: 12, weight: .bold))
                    Text("File")
                    Text("Edit")
                    Text("Selection")
                    Text("View")
                    Text("Go")
                    Text("Run")
                    Text("Terminal")
                    Text("Help")
                    
                    Spacer()
                    
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .foregroundColor(.cyan)
                        Text("FlowPilot 1.4.0")
                        Image(systemName: "wifi")
                        Image(systemName: "battery.100")
                        Text("Wed 18:30")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 20)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                
                Spacer()
            }
            
            // Mock Code Editor / IDE Window in Background
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(red: 0.09, green: 0.10, blue: 0.15).opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )
                .frame(width: 820, height: 560)
                .offset(x: -180, y: 15)
                .overlay(
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Circle().fill(Color.red.opacity(0.8)).frame(width: 10, height: 10)
                            Circle().fill(Color.yellow.opacity(0.8)).frame(width: 10, height: 10)
                            Circle().fill(Color.green.opacity(0.8)).frame(width: 10, height: 10)
                            Text("SummaryView.swift — codex-flow")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.leading, 8)
                        }
                        .padding(12)
                        
                        Divider().background(Color.white.opacity(0.08))
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("import SwiftUI")
                            Text("import AppKit")
                            Text("")
                            Text("// FlowPilot Adaptive Multi-Agent Orchestration Engine")
                            Text("public struct SummaryView: View {")
                            Text("    @ObservedObject var state: OverlayState")
                            Text("    public var isFullHeight: Bool = false")
                            Text("    ...")
                        }
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.8))
                        .padding(16)
                        
                        Spacer()
                    }
                    .frame(width: 820, height: 560)
                    .offset(x: -180, y: 15)
                )
                .shadow(color: Color.black.opacity(0.5), radius: 30, x: -10, y: 15)
            
            // FlowPilot Floating Expanded Window in Foreground
            SummaryView(state: stateInspector, isFullHeight: true)
                .scaleEffect(0.72)
                .offset(x: 320, y: 15)
                .shadow(color: Color.black.opacity(0.6), radius: 35, x: 5, y: 15)
            
            // FlowPilot Docked Bubble on Screen Right Edge
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
    print("🎨 Starting FlowPilot high-precision screenshot & promo graphic generation...")
    
    let engine = TelemetryQueryEngine.shared
    let allRuns = engine.loadAllRuns()
    
    var latestRun = engine.loadLatestRun() ?? allRuns.first
    if var r = latestRun {
        engine.enrichRunIfNeeded(&r)
        latestRun = r
    }
    
    let historyChats = engine.fetchChatHistory(limit: 20)
    let historyRuns = engine.fetchHistory(limit: 50)
    let stats = engine.computeStats(days: 30, project: nil)
    
    // State 1: Inspector (Desensitized with Privacy Blur)
    let stateInspector = OverlayState()
    stateInspector.latestRun = latestRun
    stateInspector.inspectedRun = latestRun
    stateInspector.activeTab = .inspector
    stateInspector.isExpanded = true
    stateInspector.isPrivacyMode = true
    
    // State 2: Full History (Desensitized with Privacy Blur)
    let stateHistoryFull = OverlayState()
    stateHistoryFull.latestRun = latestRun
    stateHistoryFull.historyChats = historyChats
    stateHistoryFull.historyRuns = historyRuns
    stateHistoryFull.activeTab = .history
    stateHistoryFull.isExpanded = true
    stateHistoryFull.isPrivacyMode = true
    stateHistoryFull.expandedChatIds = Set(historyChats.prefix(3).map { $0.sessionId })
    
    // State 2b: Poster Compact History (Top 3 chats)
    let stateHistoryPoster = OverlayState()
    stateHistoryPoster.latestRun = latestRun
    stateHistoryPoster.historyChats = Array(historyChats.prefix(3))
    stateHistoryPoster.historyRuns = historyRuns
    stateHistoryPoster.activeTab = .history
    stateHistoryPoster.isExpanded = true
    stateHistoryPoster.isPrivacyMode = true
    stateHistoryPoster.expandedChatIds = Set(historyChats.prefix(1).map { $0.sessionId })
    
    // State 3: Analytics (Desensitized with Privacy Blur)
    let stateAnalytics = OverlayState()
    stateAnalytics.latestRun = latestRun
    stateAnalytics.statsData = stats
    stateAnalytics.activeTab = .analytics
    stateAnalytics.isExpanded = true
    stateAnalytics.isPrivacyMode = true
    
    // State 4: Bubble
    let stateBubble = OverlayState()
    stateBubble.latestRun = latestRun
    stateBubble.isTaskRunning = false
    stateBubble.isExpanded = false
    
    // 0. Render Official Project Logo (1024x1024 Retina & 256x256)
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

    // 1. Render Standalone Unclipped Full-Height Views (2x Retina)
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
        view: BubbleView(state: stateBubble).padding(20),
        scale: 3.0,
        outputPath: "docs/assets/screenshots/capsule.png"
    )
    
    // 2. Render Standard Window Framed Views
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
    
    // 3. Render High-Impact Composite Poster, Banner & Desktop Scene
    renderViewToPNG(
        view: PosterPromoView(
            stateInspector: stateInspector,
            stateHistory: stateHistoryPoster,
            stateAnalytics: stateAnalytics,
            stateBubble: stateBubble
        ),
        scale: 2.0,
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
    
    // 4. Automatically compress all generated PNG assets using crunch
    optimizeAssetsWithCrunch()
    
    print("✨ All screenshots and promo graphics generated and optimized successfully into docs/assets!")
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
        "docs/assets/screenshots/capsule.png",
        "docs/assets/screenshots/inspector_window.png",
        "docs/assets/screenshots/history_window.png",
        "docs/assets/screenshots/analytics_window.png",
        "docs/assets/promo/flowpilot_promo_poster.png",
        "docs/assets/promo/flowpilot_promo_banner.png",
        "docs/assets/promo/flowpilot_promo_desktop_scene.png"
    ]
    
    for file in outputFiles {
        guard FileManager.default.fileExists(atPath: file) else { continue }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [crunchScript, file]
        try? proc.run()
        proc.waitUntilExit()
        
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
