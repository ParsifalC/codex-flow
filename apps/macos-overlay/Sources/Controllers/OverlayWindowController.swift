import Cocoa
import SwiftUI
import Combine

public enum DockEdge: String, Codable {
    case none
    case left
    case right
}

// MARK: - Shared Observable State
public class OverlayState: ObservableObject {
    @Published public var isExpanded: Bool = false
    @Published public var isPinned: Bool = false
    @Published public var isTaskRunning: Bool = false
    @Published public var isDocked: Bool = false
    @Published public var dockEdge: DockEdge = .right
    @Published public var latestRun: TaskRun? = nil
    @Published public var isPrivacyMode: Bool = false

    // Tab & Explorer State
    @Published public var activeTab: OverlayTab = .inspector
    @Published public var inspectedRun: TaskRun? = nil
    @Published public var historyRuns: [TaskRun] = []
    @Published public var historyChats: [ChatSession] = []
    @Published public var expandedChatIds: Set<String> = []
    @Published public var statsData: TelemetryStats? = nil
    @Published public var statsDays: Int = 30
    @Published public var selectedProject: String? = nil
    @Published public var isTodayOnly: Bool = false
    @Published public var searchQuery: String = ""
    @Published public var recentChats: [ChatSession] = []
    @Published public var allProjectsList: [String] = []

    public weak var windowController: OverlayWindowController?

    private var historyLoadGeneration = 0
    private var statsLoadGeneration = 0

    public init() {
        if let latest = TelemetryQueryEngine.shared.loadLatestRun() {
            self.latestRun = latest
            self.isTaskRunning = latest.isRunning
        }
        self.loadMenuData()
    }

    public func loadMenuData() {
        DispatchQueue.global(qos: .userInitiated).async {
            let chats = TelemetryQueryEngine.shared.fetchChatHistory(limit: 15)
            let projs = TelemetryQueryEngine.shared.allProjects()
            DispatchQueue.main.async {
                self.recentChats = chats
                self.allProjectsList = projs
            }
        }
    }

    public func expand() {
        guard !isExpanded else { return }
        self.loadMenuData()
        DispatchQueue.main.async {
            self.windowController?.prepareForPresentationChange()
            self.isDocked = false
            self.isExpanded = true
            self.windowController?.updateWindowFrame(animated: true)
        }
    }

    public func collapse() {
        guard isExpanded else { return }
        DispatchQueue.main.async {
            self.windowController?.prepareForPresentationChange()
            self.isExpanded = false
            self.isPinned = false
            self.isDocked = false
            self.windowController?.updateWindowFrame(animated: true)
        }
    }

    public func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand()
        }
    }

    public func selectTab(_ tab: OverlayTab) {
        DispatchQueue.main.async {
            self.activeTab = tab
            if tab == .history {
                self.loadHistory()
            } else if tab == .analytics {
                self.loadStats()
            }
            self.windowController?.updateWindowFrame(animated: true)
        }
    }

    public func inspect(run: TaskRun) {
        var r = run
        DispatchQueue.main.async {
            self.inspectedRun = r
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
        }
        if r.trajectory == nil || r.skillsUsed == nil || r.toolsUsed == nil || r.logs == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                TelemetryQueryEngine.shared.enrichRunIfNeeded(&r)
                DispatchQueue.main.async {
                    if self.inspectedRun?.id == r.id {
                        self.inspectedRun = r
                    }
                }
            }
        }
    }

    public func jumpToLive() {
        DispatchQueue.main.async {
            self.inspectedRun = nil
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
        }
    }

    public func toggleChatExpansion(_ id: String) {
        if expandedChatIds.contains(id) {
            expandedChatIds.remove(id)
        } else {
            expandedChatIds.insert(id)
        }
        self.windowController?.updateWindowFrame(animated: true)
    }

    public func isChatExpanded(_ id: String) -> Bool {
        expandedChatIds.contains(id)
    }

    public func expandAllChats() {
        expandedChatIds = Set(historyChats.map { $0.sessionId })
        self.windowController?.updateWindowFrame(animated: true)
    }

    public func collapseAllChats() {
        expandedChatIds.removeAll()
        self.windowController?.updateWindowFrame(animated: true)
    }

    public func loadHistory() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadHistory() }
            return
        }

        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        let proj = selectedProject
        let today = isTodayOnly
        let search = searchQuery

        DispatchQueue.global(qos: .userInitiated).async {
            let chats = TelemetryQueryEngine.shared.fetchChatHistory(
                limit: 60,
                project: proj,
                todayOnly: today,
                search: search
            )
            let runs = TelemetryQueryEngine.shared.fetchHistory(
                limit: 60,
                project: proj,
                todayOnly: today,
                search: search
            )
            DispatchQueue.main.async {
                guard generation == self.historyLoadGeneration else { return }
                self.historyChats = chats
                self.historyRuns = runs
                if self.expandedChatIds.isEmpty, let first = chats.first {
                    self.expandedChatIds.insert(first.sessionId)
                }
            }
        }
    }

    public func loadStats() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadStats() }
            return
        }

        statsLoadGeneration += 1
        let generation = statsLoadGeneration
        let days = statsDays
        let project = selectedProject

        DispatchQueue.global(qos: .userInitiated).async {
            let stats = TelemetryQueryEngine.shared.computeStats(days: days, project: project)
            DispatchQueue.main.async {
                guard generation == self.statsLoadGeneration else { return }
                self.statsData = stats
            }
        }
    }

    public func update(run: TaskRun) {
        DispatchQueue.main.async {
            self.latestRun = run
            self.isTaskRunning = run.isRunning
            if self.activeTab == .history {
                self.loadHistory()
            } else if self.activeTab == .analytics {
                self.loadStats()
            }
            if self.isExpanded {
                self.windowController?.updateWindowFrame(animated: true)
            }
        }
    }
}

// MARK: - Main Root Container View
public struct OverlayRootView: View {
    @ObservedObject var state: OverlayState

    public init(state: OverlayState) {
        self.state = state
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if state.isExpanded {
                SummaryView(state: state)
                    .frame(width: 384)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing))
                        )
                    )
            } else {
                BubbleView(state: state)
                    .frame(width: 76, height: 76)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing))
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .background(Color.clear)
        .animation(.spring(response: 0.16, dampingFraction: 0.82), value: state.isExpanded)
    }
}

// MARK: - Custom Tracking Hosting View
class TrackingHostingView<Content: View>: NSHostingView<Content> {
    weak var windowController: OverlayWindowController?
    private var trackingArea: NSTrackingArea?
    private var initialMouseScreenLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    private var isDragging = false

    required public init(rootView: Content) {
        super.init(rootView: rootView)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect
        ]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        windowController?.handleMouseEntered()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        windowController?.handleMouseMoved()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        windowController?.handleMouseExited()
    }

    // MARK: - Dragging & Magnetic Edge Snapping
    override func mouseDown(with event: NSEvent) {
        if let window {
            initialMouseScreenLocation = NSEvent.mouseLocation
            initialWindowOrigin = window.frame.origin
        }
        isDragging = false
        windowController?.cancelDwellTimer()
        windowController?.cancelTuckTimer()
        windowController?.isInteractingOrDragging = true
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouseScreenLocation = NSEvent.mouseLocation
        let deltaX = currentMouseScreenLocation.x - initialMouseScreenLocation.x
        let deltaY = currentMouseScreenLocation.y - initialMouseScreenLocation.y
        let dragThreshold: CGFloat = (windowController?.state.isExpanded ?? false) ? 8.0 : 4.0

        if isDragging || abs(deltaX) > dragThreshold || abs(deltaY) > dragThreshold {
            isDragging = true
            windowController?.cancelDwellTimer()
            windowController?.cancelTuckTimer()
            windowController?.isInteractingOrDragging = true

            var newOrigin = NSPoint(
                x: initialWindowOrigin.x + deltaX,
                y: initialWindowOrigin.y + deltaY
            )

            if let visible = windowController?.visibleFrameForDrag(
                mouseLocation: currentMouseScreenLocation,
                windowFrame: window.frame
            ) {
                newOrigin = OverlayScreenGeometry.clamp(
                    newOrigin,
                    windowSize: window.frame.size,
                    to: visible
                )
            }
            window.setFrameOrigin(newOrigin)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let window else {
            super.mouseUp(with: event)
            return
        }

        if isDragging {
            windowController?.performMagneticSnap(
                for: window,
                pointerLocation: NSEvent.mouseLocation
            )
        } else {
            windowController?.isInteractingOrDragging = false
            if let state = windowController?.state, !state.isExpanded {
                state.expand()
            }
        }
        isDragging = false
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        if let state = windowController?.state {
            if state.isExpanded {
                let pinItem = NSMenuItem(
                    title: state.isPinned ? L("Unpin Window", "取消置顶") : L("Pin Window", "置顶窗口"),
                    action: #selector(togglePin),
                    keyEquivalent: "p"
                )
                pinItem.target = self
                menu.addItem(pinItem)

                let collapseItem = NSMenuItem(
                    title: L("Collapse to Bubble", "收起为悬浮球"),
                    action: #selector(collapseBubble),
                    keyEquivalent: "c"
                )
                collapseItem.target = self
                menu.addItem(collapseItem)
            } else {
                let expandItem = NSMenuItem(
                    title: L("Expand Summary", "展开摘要"),
                    action: #selector(expandSummary),
                    keyEquivalent: "e"
                )
                expandItem.target = self
                menu.addItem(expandItem)
            }
        }

        menu.addItem(NSMenuItem.separator())

        let consoleItem = NSMenuItem(
            title: L("Open FlowPilot Console", "打开 FlowPilot 控制台"),
            action: #selector(openConsole),
            keyEquivalent: "t"
        )
        consoleItem.target = self
        menu.addItem(consoleItem)

        let refreshItem = NSMenuItem(
            title: L("Refresh Telemetry", "刷新遥测数据"),
            action: #selector(refreshData),
            keyEquivalent: "r"
        )
        refreshItem.target = self
        menu.addItem(refreshItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: L("Quit FlowPilot", "退出 FlowPilot"),
            action: #selector(quitApp),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func togglePin() {
        windowController?.state.isPinned.toggle()
    }

    @objc private func expandSummary() {
        windowController?.state.expand()
    }

    @objc private func collapseBubble() {
        windowController?.state.collapse()
    }

    @objc private func openConsole() {
        let script = """
        tell application "Terminal"
            activate
            do script "codex-flow"
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    @objc private func refreshData() {
        windowController?.refreshTelemetry()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Overlay Window Controller
public class OverlayWindowController: NSObject, NSWindowDelegate {
    private enum GeometryTransition {
        case resize
        case snap
    }

    public let state: OverlayState
    public var window: NSPanel!
    public var isInteractingOrDragging = false

    private var hoverDwellTimer: Timer?
    private var collapseTimer: Timer?
    private var tuckTimer: Timer?
    private let edgeTuckIdleInterval: TimeInterval = 30.0

    private var hoverRearmPointerLocation: NSPoint?
    private let hoverRearmDistance: CGFloat = 6.0
    private var geometryGeneration = 0
    private var isGeometryTransitioning = false
    private var activeGeometryTransition: GeometryTransition?

    private let bubbleSize = NSSize(width: 76, height: 76)
    private let summarySize = NSSize(width: 384, height: 490)
    private let snapMargin: CGFloat = 8.0
    private let snapThreshold: CGFloat = 36.0

    public init(state: OverlayState) {
        self.state = state
        super.init()
        state.windowController = self
        setupWindow()
    }

    private var visibleFrames: [NSRect] {
        NSScreen.screens.map { $0.visibleFrame }
    }

    private func resolvedVisibleFrame(for frame: NSRect, preferredPoint: NSPoint? = nil) -> NSRect? {
        let frames = visibleFrames
        if let preferredPoint,
           let byPointer = OverlayScreenGeometry.visibleFrame(containing: preferredPoint, among: frames) {
            return byPointer
        }
        if let byFrame = OverlayScreenGeometry.bestVisibleFrame(for: frame, among: frames) {
            return byFrame
        }
        return NSScreen.main?.visibleFrame
    }

    func visibleFrameForDrag(mouseLocation: NSPoint, windowFrame: NSRect) -> NSRect? {
        resolvedVisibleFrame(for: windowFrame, preferredPoint: mouseLocation)
    }

    private func setupWindow() {
        state.dockEdge = .right
        let restored = loadSavedPosition() ?? defaultPosition(for: bubbleSize)
        let initialRect = normalizedCollapsedFrame(restored)

        window = NSPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        window.level = .floating
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.delegate = self

        let rootView = OverlayRootView(state: state)
        let hostingView = TrackingHostingView(rootView: rootView)
        hostingView.windowController = self
        window.contentView = hostingView
        window.orderFront(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.scheduleTuck()
        }
    }

    public func prepareForPresentationChange() {
        cancelDwellTimer()
        cancelTuckTimer()
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    // MARK: - Programmatic Geometry Serialization
    private func animateWindow(
        to targetFrame: NSRect,
        animated: Bool,
        duration: TimeInterval,
        timing: CAMediaTimingFunctionName,
        transition: GeometryTransition,
        suppressHover: Bool,
        completion: (() -> Void)? = nil
    ) {
        geometryGeneration &+= 1
        let generation = geometryGeneration
        isGeometryTransitioning = true
        activeGeometryTransition = transition
        if suppressHover {
            suppressHoverUntilPointerMoves()
        }

        let finish: () -> Void = { [weak self] in
            guard let self, generation == self.geometryGeneration else { return }
            self.isGeometryTransitioning = false
            self.activeGeometryTransition = nil
            completion?()
        }

        guard animated else {
            window.setFrame(targetFrame, display: true)
            finish()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: timing)
            context.allowsImplicitAnimation = true
            self.window.animator().setFrame(targetFrame, display: true)
        }, completionHandler: finish)
    }

    // MARK: - Edge Half-Tuck Support
    public func cancelTuckTimer() {
        tuckTimer?.invalidate()
        tuckTimer = nil
    }

    public func scheduleTuck() {
        cancelTuckTimer()
        guard !state.isExpanded,
              !state.isPinned,
              !isInteractingOrDragging,
              !state.isDocked,
              !isGeometryTransitioning else { return }

        state.dockEdge = .right
        tuckTimer = Timer.scheduledTimer(withTimeInterval: edgeTuckIdleInterval, repeats: false) { [weak self] _ in
            self?.tuckBubble(animated: true)
        }
    }

    private func suppressHoverUntilPointerMoves() {
        hoverRearmPointerLocation = NSEvent.mouseLocation
        cancelDwellTimer()
    }

    private func pointerMovementRearmedHover() -> Bool {
        guard let anchor = hoverRearmPointerLocation else { return true }
        let current = NSEvent.mouseLocation
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let minimumDistanceSquared = hoverRearmDistance * hoverRearmDistance
        guard dx * dx + dy * dy >= minimumDistanceSquared else { return false }
        hoverRearmPointerLocation = nil
        return true
    }

    /// Tucking is deliberately visual-only. The 76x76 host window stays fixed at
    /// the right edge; BubbleView swaps its centered 58pt circle for a right-
    /// aligned 44pt pill inside that same host. Moving NSWindow here creates a
    /// second geometry target and turns AppKit tracking events into an oscillator.
    public func tuckBubble(animated: Bool = true) {
        guard !state.isExpanded,
              !state.isPinned,
              !isInteractingOrDragging,
              !state.isDocked,
              !isGeometryTransitioning else { return }

        cancelTuckTimer()
        state.dockEdge = .right
        suppressHoverUntilPointerMoves()
        state.isDocked = true
    }

    /// Untucking only changes the content rendered inside the already-stationary
    /// host window. There is intentionally no NSWindow frame animation here.
    public func unTuckBubble(animated: Bool = true) {
        cancelTuckTimer()
        guard state.isDocked, !isGeometryTransitioning else { return }
        state.dockEdge = .right
        state.isDocked = false

        if !state.isExpanded,
           !isInteractingOrDragging,
           window.frame.contains(NSEvent.mouseLocation) {
            resetDwellTimer()
        }
    }

    // MARK: - Hover-Dwell Detection
    public func cancelDwellTimer() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
    }

    public func handleMouseEntered() {
        guard !isGeometryTransitioning else { return }
        guard pointerMovementRearmedHover() else { return }

        cancelTuckTimer()
        collapseTimer?.invalidate()
        collapseTimer = nil

        if state.isDocked {
            unTuckBubble(animated: true)
            return
        }

        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }

    public func handleMouseMoved() {
        guard !isGeometryTransitioning else { return }
        guard pointerMovementRearmedHover() else { return }

        if state.isDocked {
            unTuckBubble(animated: true)
            return
        }

        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }

    private func resetDwellTimer() {
        cancelDwellTimer()
        guard !isInteractingOrDragging, !isGeometryTransitioning else { return }
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self,
                  !self.state.isExpanded,
                  !self.isInteractingOrDragging,
                  !self.isGeometryTransitioning else { return }
            self.state.expand()
        }
    }

    public func handleMouseExited() {
        cancelDwellTimer()
        guard !isGeometryTransitioning else { return }

        if state.isExpanded && !state.isPinned && !isInteractingOrDragging {
            collapseTimer?.invalidate()
            collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                guard let self,
                      self.state.isExpanded,
                      !self.state.isPinned,
                      !self.isInteractingOrDragging,
                      !self.isGeometryTransitioning else { return }
                self.state.collapse()
            }
        } else if !state.isExpanded && !state.isDocked && !isInteractingOrDragging {
            scheduleTuck()
        }
    }

    // MARK: - Drag Snap
    func performMagneticSnap(for window: NSWindow, pointerLocation: NSPoint) {
        guard let visible = resolvedVisibleFrame(for: window.frame, preferredPoint: pointerLocation) else {
            isInteractingOrDragging = false
            scheduleTuck()
            return
        }

        let frame = window.frame
        var targetOrigin = frame.origin
        let distLeft = abs(frame.minX - visible.minX)
        let distRight = abs(visible.maxX - frame.maxX)
        let distTop = abs(visible.maxY - frame.maxY)
        let distBottom = abs(frame.minY - visible.minY)

        if state.isExpanded {
            if distLeft < snapThreshold {
                targetOrigin.x = visible.minX + snapMargin
            } else if distRight < snapThreshold {
                targetOrigin.x = visible.maxX - frame.width - snapMargin
            }
            if distTop < snapThreshold {
                targetOrigin.y = visible.maxY - frame.height - snapMargin
            } else if distBottom < snapThreshold {
                targetOrigin.y = visible.minY + snapMargin
            }
            targetOrigin = OverlayScreenGeometry.clamp(
                targetOrigin,
                windowSize: frame.size,
                to: visible
            )
        } else {
            state.dockEdge = .right
            // The host itself sits flush to the right edge. The 58pt circular
            // content is centered inside 76pt, giving it a natural 9pt margin;
            // the tucked 44pt pill is right-aligned and therefore truly flush.
            targetOrigin.x = visible.maxX - frame.width
            if distTop < snapThreshold {
                targetOrigin.y = visible.maxY - frame.height - snapMargin
            } else if distBottom < snapThreshold {
                targetOrigin.y = visible.minY + snapMargin
            } else {
                targetOrigin.y = max(
                    visible.minY + snapMargin,
                    min(targetOrigin.y, visible.maxY - frame.height - snapMargin)
                )
            }
        }

        let targetFrame = NSRect(origin: targetOrigin, size: frame.size)
        animateWindow(
            to: targetFrame,
            animated: true,
            duration: 0.16,
            timing: .easeOut,
            transition: .snap,
            suppressHover: true
        ) { [weak self] in
            guard let self else { return }
            self.isInteractingOrDragging = false
            self.saveWindowPosition(targetOrigin)
            if !self.state.isExpanded {
                self.scheduleTuck()
            }
        }
    }

    // MARK: - Frame Resizing & Animation
    public func updateWindowFrame(animated: Bool = true) {
        guard let window else { return }

        let targetSize = state.isExpanded ? summarySize : bubbleSize
        let currentFrame = window.frame
        guard let visible = resolvedVisibleFrame(for: currentFrame) else { return }

        var newOrigin = NSPoint(
            x: currentFrame.maxX - targetSize.width,
            y: currentFrame.maxY - targetSize.height
        )

        if state.isExpanded {
            newOrigin = OverlayScreenGeometry.clamp(
                newOrigin,
                windowSize: targetSize,
                to: visible
            )
        } else {
            state.dockEdge = .right
            newOrigin.x = visible.maxX - targetSize.width
            newOrigin.y = max(visible.minY, min(newOrigin.y, visible.maxY - targetSize.height))
        }

        let newFrame = NSRect(origin: newOrigin, size: targetSize)
        let collapsedAfterAnimation = !state.isExpanded

        animateWindow(
            to: newFrame,
            animated: animated,
            duration: 0.16,
            timing: .easeInEaseOut,
            transition: .resize,
            suppressHover: collapsedAfterAnimation
        ) { [weak self] in
            guard let self else { return }
            if collapsedAfterAnimation && !self.state.isExpanded {
                self.saveWindowPosition(newOrigin)
                self.scheduleTuck()
            }
        }
    }

    // MARK: - Position Persistence
    private let positionKey = "CodexFlowOverlayWindowPosition"

    public func saveWindowPosition(_ origin: NSPoint) {
        let dict: [String: Double] = ["x": Double(origin.x), "y": Double(origin.y)]
        UserDefaults.standard.set(dict, forKey: positionKey)
    }

    private func loadSavedPosition() -> NSRect? {
        guard let dict = UserDefaults.standard.dictionary(forKey: positionKey) as? [String: Double],
              let x = dict["x"],
              let y = dict["y"] else {
            return nil
        }
        return NSRect(x: CGFloat(x), y: CGFloat(y), width: bubbleSize.width, height: bubbleSize.height)
    }

    private func normalizedCollapsedFrame(_ frame: NSRect) -> NSRect {
        let visible = OverlayScreenGeometry.bestVisibleFrame(for: frame, among: visibleFrames)
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.maxX - bubbleSize.width
        let y = max(visible.minY, min(frame.origin.y, visible.maxY - bubbleSize.height))
        return NSRect(origin: NSPoint(x: x, y: y), size: bubbleSize)
    }

    private func defaultPosition(for size: NSSize) -> NSRect {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screen.maxX - size.width
        let y = screen.maxY - size.height - 32
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    public func refreshTelemetry() {
        DispatchQueue.global(qos: .userInitiated).async {
            let latest = TelemetryQueryEngine.shared.loadLatestRun()
            DispatchQueue.main.async {
                if let run = latest {
                    self.state.update(run: run)
                } else {
                    self.state.latestRun = nil
                    self.state.isTaskRunning = false
                    self.state.loadHistory()
                    self.state.loadStats()
                }
            }
        }
    }
}
