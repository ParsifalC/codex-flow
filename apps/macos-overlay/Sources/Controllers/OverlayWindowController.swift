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
    @Published public var isExpanded: Bool = false {
        didSet { if isExpanded { dismissPetCompletionNotice() } }
    }
    @Published public var isPinned: Bool = false {
        didSet {
            if isPinned {
                windowController?.cancelNotificationAutoCollapseTimer()
            }
        }
    }
    @Published public var isDocked: Bool = false
    @Published public var dockEdge: DockEdge = .right
    @Published public var latestRun: TaskRun? = nil
    @Published public private(set) var petResource: PetResource?
    @Published public private(set) var petActivityUnavailable: Bool = false
    public let petAnimator: PetAnimator
    var compactSize: NSSize {
        petResource == nil ? OverlayCompactLayout.hostSize : OverlayCompactLayout.petHostSize
    }
    public lazy var petActivityConsumer = PetActivityConsumer(state: self)
    // A completion IPC can refer to an older turn than latestRun. Keep that
    // event's content for the notification presentation while preserving the
    // latest snapshot used by the live bubble and history state.
    @Published public var notificationRun: TaskRun? = nil
    @Published public private(set) var petCompletionNotice: TaskRun?
    private var petNoticeDismissal: DispatchWorkItem?

    public var petUnreadCount: Int {
        var identities = Set(unreadNotificationRuns.keys)
        if let run = latestRun, run.publication != nil, !viewedTurnIds.contains(run.id) {
            identities.insert(run.id)
        }
        return identities.count
    }

    public func dismissPetCompletionNotice() {
        petNoticeDismissal?.cancel()
        petNoticeDismissal = nil
        petCompletionNotice = nil
    }

    private func showPetCompletionNotice(_ run: TaskRun) {
        guard !isExpanded, !viewedTurnIds.contains(run.id) else { return }
        petNoticeDismissal?.cancel()
        petCompletionNotice = run
        let dismissal = DispatchWorkItem { [weak self] in self?.dismissPetCompletionNotice() }
        petNoticeDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismissal)
    }
    @Published public var isPrivacyMode: Bool = false {
        didSet { analysisService?.setPrivacyMode(isPrivacyMode) }
    }
    @Published public private(set) var analysisSnapshot: AnalysisSnapshot?
    public private(set) var analysisService: ConversationAnalysisService?
    private var analysisSubscription: AnyCancellable?
    private var analysisErrorSubscription: AnyCancellable?
    private var telemetryChats: [ChatSession] = []

    public func analysis(for run: TaskRun) -> ConversationAnalysisProjection? {
        analysisSnapshot?.projection(sessionID: run.sessionId, turnID: run.turnId, privacyMode: isPrivacyMode)
    }

    /// The analyzed conversation owns the task destination; global telemetry
    /// can enrich matching turns but cannot move it to a different conversation.
    public var currentTaskRun: TaskRun? {
        guard let latest = analysisSnapshot?.overlayRuns.last else { return latestRun }
        if latestRun?.id == latest.id { return latestRun }
        return telemetryChats.flatMap(\.runs).first(where: { $0.id == latest.id }) ?? latest
    }

    public var isInspectingHistory: Bool {
        currentTaskRun != nil && (inspectedRun != nil || notificationRun != nil || selectedRun?.id != currentTaskRun?.id)
    }

    public func attachAnalysis(_ service: ConversationAnalysisService) {
        analysisSubscription?.cancel()
        analysisService?.stop()
        analysisService = service
        analysisErrorSubscription = service.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        service.setPrivacyMode(isPrivacyMode)
        analysisSubscription = service.$projection.sink { [weak self] projection in
            guard let self else { return }
            let followLatest = self.inspectedRun == nil && self.notificationRun == nil &&
                (self.selectedTurnIdentity == nil || self.selectedTurnIdentity == self.currentTaskRun?.id)
            self.analysisSnapshot = projection.snapshot
            if let selected = self.selectedRun, projection.snapshot.excludes(selected) {
                self.inspectedRun = nil
                self.notificationRun = nil
                self.selectedTurnIdentity = self.currentTaskRun?.id
                self.selectedSessionRuns = self.currentTaskRun.map { [$0] } ?? []
            }
            if followLatest, let current = self.currentTaskRun {
                self.selectedTurnIdentity = current.id
                if !self.selectedSessionRuns.contains(where: { $0.id == current.id }) {
                    self.selectedSessionRuns.append(current)
                }
            }
            let chats = self.chatsWithAnalysis(self.telemetryChats)
            self.recentChats = Array(chats.prefix(15))
            self.refreshSelectedSessionRuns(from: chats)
        }
        service.start()
    }

    private func runsWithAnalysis(_ runs: [TaskRun]) -> [TaskRun] {
        let known = Set(runs.map(\.id))
        return runs.filter { analysisSnapshot?.excludes($0) != true } +
            (analysisSnapshot?.overlayRuns ?? []).filter { !known.contains($0.id) }
    }

    private func chatsWithAnalysis(_ chats: [ChatSession]) -> [ChatSession] {
        guard let snapshot = analysisSnapshot, let session = snapshot.sessionID, !snapshot.turns.isEmpty else { return chats }
        var result = chats
        if let index = result.firstIndex(where: { $0.sessionId == session }) {
            result[index].runs = runsWithAnalysis(result[index].runs)
        } else {
            result.insert(ChatSession(sessionId: session, projectName: "codex-flow",
                title: L("Current conversation", "当前会话"), runs: snapshot.overlayRuns), at: 0)
        }
        return result
    }

    @Published public var activeTab: OverlayTab = .inspector
    @Published public var inspectedRun: TaskRun? = nil
    /// The selected turn is a session+turn identity. Keeping it separate from
    /// latestRun prevents a refresh in another chat from changing the task
    /// currently being read.
    @Published public var selectedTurnIdentity: String? = nil
    @Published public private(set) var selectedSessionRuns: [TaskRun] = []
    @Published public var historyRuns: [TaskRun] = []
    @Published public var expandedChatIds: Set<String> = []
    @Published public var statsData: TelemetryStats? = nil
    @Published public var statsDays: Int = 30
    @Published public var selectedProject: String? = nil
    @Published public var isTodayOnly: Bool = false
    @Published public var searchQuery: String = ""
    @Published public var recentChats: [ChatSession] = []

    public weak var windowController: OverlayWindowController?

    private var menuLoadGeneration = 0
    private var historyLoadGeneration = 0
    private var statsLoadGeneration = 0
    private var publicationGate = PublishedTurnGate()

    private let readDefaults: UserDefaults
    private let petStore: PetResourceStore
    private var hasStartedPetPresetSeeding = false
    private var petWindowVisible = false
    private var celebratedPetTurns: Set<String> = []
    private var celebratedPetTurnOrder: [String] = []
    @Published private var viewedTurnIds: [String]
    // Keep the completion snapshot: a delayed notification may arrive before
    // its history file, and latestRun may belong to another conversation.
    @Published private var unreadNotificationRuns: [String: TaskRun] = [:]
    public var hasUnreadResult: Bool {
        if !unreadNotificationRuns.isEmpty { return true }
        guard let run = latestRun, run.publication != nil else { return false }
        return !viewedTurnIds.contains(run.id)
    }

    /// Use the same unread turn for the caption and its click destination.
    public var petReminderRun: TaskRun? {
        let pending = unreadNotificationRuns.values.max {
            let lhs = $0.publication?.completedAtMs ?? $0.finishedAtMs ?? $0.startedAtMs ?? 0
            let rhs = $1.publication?.completedAtMs ?? $1.finishedAtMs ?? $1.startedAtMs ?? 0
            return lhs == rhs ? $0.id < $1.id : lhs < rhs
        }
        if let pending { return pending }
        guard let run = latestRun, run.publication != nil,
              !viewedTurnIds.contains(run.id) else { return nil }
        return run
    }

    public var selectedRun: TaskRun? {
        if let selectedTurnIdentity {
            if let run = selectedSessionRuns.first(where: { $0.id == selectedTurnIdentity }) {
                return run
            }
            if let run = [notificationRun, inspectedRun, currentTaskRun, latestRun].compactMap({ $0 }).first(where: { $0.id == selectedTurnIdentity }) {
                return run
            }
            return nil
        }
        return notificationRun ?? inspectedRun ?? currentTaskRun
    }

    public var turnNavigation: TurnNavigation {
        let runs = selectedSessionRuns.isEmpty ? selectedRun.map { [$0] } ?? [] : selectedSessionRuns
        let source = analysisSnapshot?.overlayRuns ?? []
        return TurnNavigation(runs: runs.filter { analysisSnapshot?.excludes($0) != true }, selectedIdentity: selectedTurnIdentity,
            additionalVisibleIDs: Set(source.map(\.id)),
            sourceOrder: Dictionary(uniqueKeysWithValues: source.enumerated().map { ($0.element.id, $0.offset) }))
    }

    public func markResultViewed(_ run: TaskRun?) {
        guard let run, run.publication != nil else { return }
        if petCompletionNotice?.id == run.id { dismissPetCompletionNotice() }
        unreadNotificationRuns.removeValue(forKey: run.id)
        guard !viewedTurnIds.contains(run.id) else { return }
        viewedTurnIds.append(run.id)
        viewedTurnIds = Array(viewedTurnIds.suffix(200))
        readDefaults.set(viewedTurnIds, forKey: "viewedCompletedTurns")
    }

    public init(readDefaults: UserDefaults = .standard) {
        self.readDefaults = readDefaults
        self.petStore = PetResourceStore()
        self.petAnimator = PetAnimator()
        self.viewedTurnIds = readDefaults.stringArray(forKey: "viewedCompletedTurns") ?? []
        // TelemetryWatcher owns the initial snapshot after recover-last.
        // Reading last.json here would expose a stale snapshot before recovery.
        loadMenuData()
        petActivityConsumer.recover()
    }

    private var petReloadGeneration = 0

    /// Ensure bundled presets are installed when the native app starts. The
    /// CLI owns seeding and current-selection persistence; native startup only
    /// asks it to reconcile and then reloads the validated selection.
    public func seedPetPresetsOnStartup() {
        guard !hasStartedPetPresetSeeding else { return }
        hasStartedPetPresetSeeding = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            do {
                _ = try PetCatalogService.list()
            } catch {
                return
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reloadPetAsync { _ in }
            }
        }
    }

    /// Selection persistence belongs to the CLI. This owner applies the result once,
    /// using the same asynchronous loader as external IPC and startup.
    public var selectedPetID: String { petResource?.id ?? "default" }

    func selectPet(_ id: String, completion: @escaping (PetReloadOutcome) -> Void) {
        precondition(Thread.isMainThread)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try PetCatalogService.select(id)
                DispatchQueue.main.async {
                    self?.reloadPetAsync(completion: completion)
                }
            } catch {
                DispatchQueue.main.async {
                    completion(PetReloadOutcome(accepted: false, selectedID: id, error: error.localizedDescription))
                }
            }
        }
    }

    /// Decode on a background queue so selecting an atlas never blocks UI work.
    public func reloadPetAsync(completion: @escaping (PetReloadOutcome) -> Void) {
        precondition(Thread.isMainThread)
        petReloadGeneration += 1
        let generation = petReloadGeneration
        let home = petStore.codexHome
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let store = PetResourceStore(codexHome: home)
            let result = store.reload()
            let selectedID = store.lastSelectionID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == self.petReloadGeneration else {
                    completion(PetReloadOutcome(accepted: false, selectedID: selectedID,
                        error: L("Pet selection changed. Please retry.", "宠物选择已更新，请重试。")))
                    return
                }
                completion(self.applyPetReload(result, selectedID: selectedID))
            }
        }
    }

    private func applyPetReload(_ result: PetResourceLoadResult, selectedID: String) -> PetReloadOutcome {
        let previousSize = compactSize
        defer {
            petAnimator.configure(resourceID: petResource?.id ?? "default")
            petAnimator.setAutonomyEnabled(petResource != nil)
            if petResource != nil { isDocked = false }
            if compactSize != previousSize { windowController?.updateWindowFrame(animated: false) }
        }
        switch result {
        case .builtIn:
            petResource = nil
            return PetReloadOutcome(accepted: true, selectedID: "default")
        case .loaded(let resource):
            petResource = resource
            return PetReloadOutcome(accepted: true, selectedID: resource.id)
        case .rejected(let error):
            petResource = nil
            return PetReloadOutcome(accepted: false, selectedID: selectedID, error: error)
        }
    }

    public func setPetTaskState(_ state: PetState) {
        petAnimator.setTaskState(state)
    }

    public func playPetHover(reduceMotion: Bool = false) {
        guard !reduceMotion else { return }
        petAnimator.playHover()
    }

    public func beginPetDrag(direction: PetDragDirection) {
        petAnimator.beginDrag(direction: direction)
    }

    public func endPetDrag() {
        petAnimator.endDrag()
    }

    public func clearPetState() {
        petAnimator.clear()
    }

    public func stopPet() {
        petAnimator.stop()
    }

    // Live event bridge hooks. Keep the short names on the state owner so a
    // producer does not need to know which animator instance the view owns.
    public func setTaskState(_ state: PetState, preservingTransient: Bool = false) {
        petAnimator.setTaskState(state, preservingTransient: preservingTransient)
    }

    public func celebratePetResult(session: String, turn: String) {
        let identity = "\(session.utf8.count):\(session)\(turn)"
        guard celebratedPetTurns.insert(identity).inserted else { return }
        celebratedPetTurnOrder.append(identity)
        if celebratedPetTurnOrder.count > 512 {
            celebratedPetTurns.remove(celebratedPetTurnOrder.removeFirst())
        }
        petAnimator.playCelebration()
    }

    public func playTransient(_ state: PetState) {
        petAnimator.playTransient(state)
    }

    public func beginDrag(direction: PetDragDirection) {
        petAnimator.beginDrag(direction: direction)
    }

    public func endDrag() {
        petAnimator.endDrag()
    }

    public func clear() {
        petAnimator.clear()
    }

    public func stop() {
        petAnimator.stop()
    }

    public func markPetActivityUnavailable() {
        petActivityUnavailable = true
    }

    public func markPetActivityAvailable() {
        petActivityUnavailable = false
    }

    @discardableResult
    public func handlePetActivity(_ event: PetActivityEvent) -> PetActivityTransition {
        petActivityConsumer.consume(event)
    }

    public func handlePetActivityJSON(_ payload: String) -> String {
        petActivityConsumer.consumeJSON(payload)
    }

    public func setPetVisibility(_ visible: Bool, reduceMotion: Bool = false) {
        petWindowVisible = visible
        refreshPetVisibility(reduceMotion: reduceMotion)
    }

    public func refreshPetVisibility(reduceMotion: Bool) {
        petAnimator.setVisibility(visible: petWindowVisible, expanded: isExpanded, reduceMotion: reduceMotion)
    }

    public func loadMenuData() {
        menuLoadGeneration += 1
        let generation = menuLoadGeneration
        DispatchQueue.global(qos: .userInitiated).async {
            let chats = TelemetryQueryEngine.shared.fetchChatHistory(limit: 0)
            DispatchQueue.main.async {
                guard generation == self.menuLoadGeneration else { return }
                self.telemetryChats = chats
                let mergedChats = self.chatsWithAnalysis(chats)
                self.recentChats = Array(mergedChats.prefix(15))
                self.refreshSelectedSessionRuns(from: mergedChats)
            }
        }
    }

    private func refreshSelectedSessionRuns(from chats: [ChatSession]) {
        guard let selected = selectedRun else {
            selectedSessionRuns = []
            return
        }
        let chat = chats.first { chat in
            if let session = selected.sessionId { return chat.sessionId == session }
            return chat.runs.contains { $0.id == selected.id }
        }
        var runs = chat?.runs ?? []
        if let index = runs.firstIndex(where: { $0.id == selected.id }) {
            // A completion snapshot can reach the UI before the directory query.
            if (selected.publicationRevision ?? 0) > (runs[index].publicationRevision ?? 0) {
                runs[index] = selected
            }
        } else {
            runs.append(selected)
        }
        selectedTurnIdentity = selected.id
        selectedSessionRuns = runs
    }

    public func moveTurn(by offset: Int) {
        DispatchQueue.main.async {
            let moved = self.turnNavigation.moved(by: offset)
            guard let run = moved.currentRun, run.id != self.selectedRun?.id else { return }
            self.notificationRun = nil
            self.inspectedRun = run
            self.selectedTurnIdentity = run.id
            self.markResultViewed(run)
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
        }
    }

    public func expand(notificationTriggered: Bool = false) {
        if isExpanded {
            if notificationTriggered {
                DispatchQueue.main.async {
                    self.windowController?.scheduleNotificationAutoCollapse()
                }
            }
            return
        }
        loadMenuData()
        DispatchQueue.main.async {
            self.windowController?.prepareForPresentationChange()
            self.isDocked = false
            self.isExpanded = true
            self.windowController?.updateWindowFrame(animated: true)
            if notificationTriggered {
                self.windowController?.scheduleNotificationAutoCollapse()
            }
        }
    }

    public func collapse() {
        guard isExpanded else { return }
        DispatchQueue.main.async {
            self.windowController?.prepareForPresentationChange()
            self.isExpanded = false
            self.notificationRun = nil
            self.isPinned = false
            self.isDocked = false
            // Reliability first: AppKit frame interpolation while SwiftUI swaps
            // a full panel for a compact capsule has been the source of several
            // display/tracking races. Collapse now commits one stable frame;
            // the compact capsule still animates entirely inside that host.
            self.windowController?.updateWindowFrame(animated: false)
        }
    }

    public func toggle() {
        isExpanded ? collapse() : openLatest()
    }

    public func openLatest() {
        let unread = petReminderRun
        if let unread {
            inspect(run: unread)
        } else {
            jumpToLive()
        }
        expand()
    }

    public func selectTab(_ tab: OverlayTab) {
        DispatchQueue.main.async {
            self.activeTab = tab
            if tab == .inspector { self.markResultViewed(self.selectedRun) }
            if tab == .history {
                self.loadHistory()
            } else if tab == .analytics {
                self.loadStats()
            }
            self.windowController?.updateWindowFrame(animated: true)
        }
    }

    public func inspect(run: TaskRun) {
        if analysisSnapshot?.excludes(run) == true { jumpToLive(); return }
        DispatchQueue.main.async {
            self.notificationRun = nil
            self.inspectedRun = run
            self.selectedTurnIdentity = run.id
            if let index = self.selectedSessionRuns.firstIndex(where: { $0.id == run.id }) {
                if (run.publicationRevision ?? 0) >= (self.selectedSessionRuns[index].publicationRevision ?? 0) {
                    self.selectedSessionRuns[index] = run
                }
            } else {
                self.selectedSessionRuns = [run]
            }
            self.markResultViewed(run)
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
            self.loadMenuData()
        }
    }

    public func jumpToLive() {
        DispatchQueue.main.async {
            self.notificationRun = nil
            self.inspectedRun = nil
            let current = self.currentTaskRun
            self.selectedTurnIdentity = current?.id
            self.selectedSessionRuns = current.map { [$0] } ?? []
            self.markResultViewed(current)
            self.activeTab = .inspector
            self.windowController?.updateWindowFrame(animated: true)
            self.loadMenuData()
        }
    }

    public func toggleChatExpansion(_ id: String) {
        if expandedChatIds.contains(id) {
            expandedChatIds.remove(id)
        } else {
            expandedChatIds.insert(id)
        }
        windowController?.updateWindowFrame(animated: true)
    }

    public func isChatExpanded(_ id: String) -> Bool {
        expandedChatIds.contains(id)
    }

    public func loadHistory() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.loadHistory() }
            return
        }

        historyLoadGeneration += 1
        let generation = historyLoadGeneration
        let project = selectedProject
        let todayOnly = isTodayOnly
        let search = searchQuery

        DispatchQueue.global(qos: .userInitiated).async {
            let runs = TelemetryQueryEngine.shared.fetchHistory(
                limit: 0,
                project: project,
                todayOnly: todayOnly,
                search: search
            )
            DispatchQueue.main.async {
                guard generation == self.historyLoadGeneration else { return }
                self.historyRuns = self.runsWithAnalysis(runs).filter { run in
                    guard !runs.contains(where: { $0.id == run.id }) else { return true }
                    return !todayOnly && (project == nil || run.projectName == project) &&
                        (search.isEmpty || run.turnPreview.localizedCaseInsensitiveContains(search))
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

    public func update(
        run: TaskRun,
        notificationTriggered: Bool = false,
        recovery: Bool = false
    ) {
        DispatchQueue.main.async {
            let decision = self.publicationGate.accept(run, notify: notificationTriggered)
            if recovery {
                // Startup recovery refreshes the restored snapshot silently and
                // keeps its completion identity eligible for a later explicit
                // completion IPC event.
                self.publicationGate.seed(run)
            }
            if let pending = self.unreadNotificationRuns[run.id] {
                if (run.publicationRevision ?? 0) > (pending.publicationRevision ?? 0) {
                    self.unreadNotificationRuns[run.id] = run
                }
            } else if decision.notify && !self.viewedTurnIds.contains(run.id) {
                self.unreadNotificationRuns[run.id] = run
            }
            if decision.notify && self.analysisSnapshot?.overlayRuns.isEmpty != false && !(self.isExpanded && self.inspectedRun != nil) {
                self.notificationRun = run
                self.selectedTurnIdentity = run.id
                self.selectedSessionRuns = [run]
                if self.petResource == nil {
                    self.expand(notificationTriggered: true)
                }
            }
            if decision.notify, self.petResource != nil {
                self.showPetCompletionNotice(run)
            }
            if decision.notify, self.petResource != nil,
               let session = run.sessionId, let turn = run.turnId {
                self.celebratePetResult(session: session, turn: turn)
            }
            guard decision.refresh else {
                if decision.notify { self.loadMenuData() }
                return
            }
            self.latestRun = run
            if self.selectedTurnIdentity == nil {
                self.selectedTurnIdentity = run.id
                self.selectedSessionRuns = [run]
            } else if self.selectedTurnIdentity == run.id {
                if let index = self.selectedSessionRuns.firstIndex(where: { $0.id == run.id }) {
                    self.selectedSessionRuns[index] = run
                } else {
                    self.selectedSessionRuns = [run]
                }
            }
            self.loadMenuData()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(state: OverlayState) {
        self.state = state
    }

    public var body: some View {
        ZStack(alignment: .topTrailing) {
            if state.isExpanded {
                SummaryView(state: state)
                    .frame(width: OverlayWindowController.summarySize.width)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.95, anchor: .topTrailing))
                        )
                    )
            } else {
                BubbleView(state: state)
                    .frame(width: state.compactSize.width, height: state.compactSize.height)
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
        .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.82), value: state.isExpanded)
    }
}

// MARK: - Keyable Overlay Panel
//
// The overlay uses a non-activating panel so it can float above other apps,
// but the history search field still needs a key window to receive keyboard
// input.  NSPanel's default key-window policy otherwise leaves the field
// visible but unable to become the first responder.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Custom Tracking Hosting View
class TrackingHostingView<Content: View>: NSHostingView<Content> {
    weak var windowController: OverlayWindowController?
    private var trackingArea: NSTrackingArea?
    private var logicalPointerInside = false
    private var initialMouseScreenLocation: NSPoint = .zero
    private var initialWindowOrigin: NSPoint = .zero
    private var isDragging = false
    private var petDragStarted = false
    private var ownsPointerInteraction = false

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
        if let trackingArea {
            removeTrackingArea(trackingArea)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let windowController else { return super.hitTest(point) }
        guard windowController.isPointerInteractive(at: point, in: bounds) else { return nil }
        return super.hitTest(point)
    }

    private func localPoint(for event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
    }

    private func routePointerMotion(_ event: NSEvent) {
        guard let windowController else { return }
        let point = localPoint(for: event)
        let isInside = windowController.isPointerInteractive(at: point, in: bounds)

        if isInside {
            if logicalPointerInside {
                windowController.handleMouseMoved(at: point)
            } else {
                logicalPointerInside = true
                windowController.handleMouseEntered(at: point)
            }
        } else if logicalPointerInside {
            logicalPointerInside = false
            windowController.handleMouseExited()
        }
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        routePointerMotion(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        routePointerMotion(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if logicalPointerInside {
            logicalPointerInside = false
            windowController?.handleMouseExited()
        }
    }

    // MARK: - Dragging & Magnetic Edge Snapping
    override func mouseDown(with event: NSEvent) {
        guard let window,
              let windowController,
              windowController.isPointerInteractive(at: localPoint(for: event), in: bounds),
              windowController.beginPointerInteraction() else { return }

        ownsPointerInteraction = true
        initialMouseScreenLocation = NSEvent.mouseLocation
        initialWindowOrigin = window.frame.origin
        isDragging = false
        petDragStarted = false
        windowController.cancelDwellTimer()
        windowController.cancelTuckTimer()
        windowController.cancelNotificationAutoCollapseTimer()
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard ownsPointerInteraction,
              let window,
              let windowController else {
            super.mouseDragged(with: event)
            return
        }

        let currentMouseScreenLocation = NSEvent.mouseLocation
        let deltaX = currentMouseScreenLocation.x - initialMouseScreenLocation.x
        let deltaY = currentMouseScreenLocation.y - initialMouseScreenLocation.y
        let dragThreshold: CGFloat = windowController.state.isExpanded ? 8.0 : 4.0

        if isDragging || abs(deltaX) > dragThreshold || abs(deltaY) > dragThreshold {
            isDragging = true
            if !petDragStarted,
               abs(deltaX) > dragThreshold,
               abs(deltaX) >= abs(deltaY),
               !windowController.state.isExpanded {
                petDragStarted = true
                windowController.state.beginPetDrag(direction: deltaX < 0 ? .left : .right)
            }
            windowController.cancelDwellTimer()
            windowController.cancelTuckTimer()

            var newOrigin = NSPoint(
                x: initialWindowOrigin.x + deltaX,
                y: initialWindowOrigin.y + deltaY
            )

            if let visible = windowController.visibleFrameForDrag(
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
        guard ownsPointerInteraction else {
            super.mouseUp(with: event)
            return
        }

        ownsPointerInteraction = false
        let dragged = isDragging
        isDragging = false
        if petDragStarted {
            windowController?.state.endPetDrag()
            petDragStarted = false
        }

        if dragged, let window, let windowController {
            windowController.endPointerInteraction(drainPendingPresentation: false)
            windowController.performMagneticSnap(
                for: window,
                pointerLocation: NSEvent.mouseLocation
            )
        } else if let windowController {
            windowController.endPointerInteraction(drainPendingPresentation: true)
            if !windowController.state.isExpanded {
                windowController.state.openLatest()
            }
        }
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let windowController,
              windowController.isPointerInteractive(at: localPoint(for: event), in: bounds) else { return }

        let menu = NSMenu()
        let state = windowController.state
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
        windowController?.state.openLatest()
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
    public let state: OverlayState
    public var window: NSPanel!

    public var isInteractingOrDragging: Bool {
        runtime.pointerInteractionActive
    }

    private var petCompletionPresenter: PetCompletionPresenter?
    private var hoverDwellTimer: Timer?
    private var collapseTimer: Timer?
    private var notificationCollapseTimer: Timer?
    private let notificationAutoCollapseDuration: TimeInterval = 10.0
    private var tuckTimer: Timer?
    private let edgeTuckIdleInterval: TimeInterval = 30.0

    private var runtime = OverlayRuntimeState()
    private var hoverGate = OverlayHoverGate(rearmDistance: 6)
    private var pendingPresentationAnimated = true
    private var needsPointerReconciliationAfterGeometry = false

    private var bubbleSize: NSSize { state.compactSize }
    static let summarySize = NSSize(width: 404, height: 660)
    private let snapMargin: CGFloat = 8.0
    private let snapThreshold: CGFloat = 36.0

    public init(state: OverlayState) {
        self.state = state
        super.init()
        state.windowController = self
        setupWindow()
        petCompletionPresenter = PetCompletionPresenter(state: state, anchor: window)
    }

    private var visibleFrames: [NSRect] {
        NSScreen.screens.map { $0.visibleFrame }
    }

    private var isGeometryTransitioning: Bool {
        runtime.isGeometryTransitioning
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

    private func presentationVisibleFrame(for frame: NSRect) -> NSRect? {
        OverlayScreenGeometry.presentationVisibleFrame(for: frame, among: visibleFrames)
            ?? NSScreen.main?.visibleFrame
    }

    func visibleFrameForDrag(mouseLocation: NSPoint, windowFrame: NSRect) -> NSRect? {
        resolvedVisibleFrame(for: windowFrame, preferredPoint: mouseLocation)
    }

    private func setupWindow() {
        state.dockEdge = .right
        let restored = loadSavedPosition() ?? defaultPosition(for: bubbleSize)
        let initialRect = normalizedCollapsedFrame(restored)

        window = OverlayPanel(
            contentRect: initialRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.becomesKeyOnlyIfNeeded = true
        window.level = .floating
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.delegate = self

        let hostingView = TrackingHostingView(rootView: OverlayRootView(state: state))
        hostingView.windowController = self
        window.contentView = hostingView
        window.orderFrontRegardless()
        updatePetVisibility()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.scheduleTuck()
        }
    }

    public func prepareForPresentationChange() {
        cancelDwellTimer()
        cancelTuckTimer()
        cancelNotificationAutoCollapseTimer()
        collapseTimer?.invalidate()
        collapseTimer = nil
    }

    // MARK: - Pointer ownership / hit testing
    func isPointerInteractive(at point: NSPoint, in hostBounds: NSRect) -> Bool {
        OverlayCompactHitRegion.contains(
            point,
            in: hostBounds,
            expanded: state.isExpanded,
            docked: state.isDocked,
            pet: state.petResource != nil
        )
    }

    @discardableResult
    func beginPointerInteraction() -> Bool {
        let accepted = runtime.beginPointerInteraction()
        if accepted { state.petAnimator.beginPointerInteraction() }
        return accepted
    }

    func endPointerInteraction(drainPendingPresentation: Bool) {
        runtime.endPointerInteraction()
        state.petAnimator.endPointerInteraction()
        guard drainPendingPresentation,
              runtime.claimPendingPresentationIfIdle() else { return }
        performPresentationFrameUpdate(animated: pendingPresentationAnimated)
    }

    // MARK: - Single-owner geometry pipeline
    public func updateWindowFrame(animated: Bool = true) {
        let animated = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        pendingPresentationAnimated = animated
        guard runtime.requestPresentationGeometry() else { return }
        performPresentationFrameUpdate(animated: animated)
    }

    private func performPresentationFrameUpdate(animated: Bool) {
        guard let window else {
            finishGeometryActivity()
            return
        }

        let targetSize = state.isExpanded ? Self.summarySize : bubbleSize
        let currentFrame = window.frame
        guard let visible = presentationVisibleFrame(for: currentFrame) else {
            finishGeometryActivity()
            return
        }

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

        let targetFrame = NSRect(origin: newOrigin, size: targetSize)
        let collapsedAfterAnimation = !state.isExpanded
        if collapsedAfterAnimation {
            suppressHoverUntilPointerMoves()
        }

        let completed: () -> Void = { [weak self] in
            guard let self else { return }
            self.window.orderFrontRegardless()
            self.updatePetVisibility()
            self.presentationFrameDidSet(targetOrigin: newOrigin, collapsed: collapsedAfterAnimation)
            let startedNext = self.finishGeometryActivity()
            if !startedNext, collapsedAfterAnimation, !self.state.isExpanded {
                self.scheduleTuck()
            }
        }

        if approximatelyEqual(window.frame, targetFrame) || !animated {
            window.setFrame(targetFrame, display: true)
            completed()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }, completionHandler: completed)
    }

    private func presentationFrameDidSet(targetOrigin: NSPoint, collapsed: Bool) {
        if collapsed && !state.isExpanded {
            saveWindowPosition(targetOrigin)
        }
    }

    private func updatePetVisibility() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        state.setPetVisibility(
            visible,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    public func windowDidChangeOcclusionState(_ notification: Notification) {
        updatePetVisibility()
    }

    @discardableResult
    private func finishGeometryActivity() -> Bool {
        let shouldRunPendingPresentation = runtime.completeGeometry()
        if shouldRunPendingPresentation {
            performPresentationFrameUpdate(animated: pendingPresentationAnimated)
            return true
        }
        reconcilePointerAfterGeometryIfNeeded()
        if state.isExpanded && isPointerInAppWindowOrPopover() {
            cancelNotificationAutoCollapseTimer()
        }
        return false
    }

    private func reconcilePointerAfterGeometryIfNeeded() {
        guard needsPointerReconciliationAfterGeometry,
              let contentView = window?.contentView,
              let window else { return }
        needsPointerReconciliationAfterGeometry = false

        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInHost = contentView.convert(pointInWindow, from: nil)
        if isPointerInteractive(at: pointInHost, in: contentView.bounds) {
            handleMouseEntered(at: pointInHost)
        } else {
            handleMouseExited()
        }
    }

    private func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance &&
        abs(lhs.origin.y - rhs.origin.y) <= tolerance &&
        abs(lhs.size.width - rhs.size.width) <= tolerance &&
        abs(lhs.size.height - rhs.size.height) <= tolerance
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
        hoverGate.suppress(at: NSEvent.mouseLocation)
        cancelDwellTimer()
    }

    private func pointerMovementRearmedHover() -> Bool {
        hoverGate.allowsHover(at: NSEvent.mouseLocation)
    }

    /// Compact docking is visual-only. Capsule and docked tile share the same stationary
    /// compact host; no NSWindow frame is changed here.
    public func tuckBubble(animated: Bool = true) {
        guard state.petResource == nil,
              !state.isExpanded,
              !state.isPinned,
              !isInteractingOrDragging,
              !state.isDocked,
              !isGeometryTransitioning else { return }

        cancelTuckTimer()
        state.dockEdge = .right
        suppressHoverUntilPointerMoves()
        state.isDocked = true
    }

    public func unTuckBubble(pointerLocationInHost: NSPoint? = nil, animated: Bool = true) {
        cancelTuckTimer()
        guard state.isDocked, !isGeometryTransitioning else { return }
        state.dockEdge = .right
        state.isDocked = false

        if let pointerLocationInHost,
           OverlayCompactHitRegion.contains(
                pointerLocationInHost,
                in: NSRect(origin: .zero, size: bubbleSize),
                expanded: false,
                docked: false,
                pet: state.petResource != nil
           ),
           !isInteractingOrDragging {
            resetDwellTimer()
        }
    }

    // MARK: - Hover-Dwell Detection
    public func cancelDwellTimer() {
        hoverDwellTimer?.invalidate()
        hoverDwellTimer = nil
    }

    public func handleMouseEntered(at point: NSPoint) {
        cancelNotificationAutoCollapseTimer()
        if isGeometryTransitioning {
            needsPointerReconciliationAfterGeometry = true
            return
        }
        guard pointerMovementRearmedHover() else { return }

        cancelTuckTimer()
        collapseTimer?.invalidate()
        collapseTimer = nil

        if state.isDocked {
            unTuckBubble(pointerLocationInHost: point, animated: true)
            return
        }

        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }

    public func handleMouseMoved(at point: NSPoint) {
        cancelNotificationAutoCollapseTimer()
        if isGeometryTransitioning {
            needsPointerReconciliationAfterGeometry = true
            return
        }
        guard pointerMovementRearmedHover() else { return }

        if state.isDocked {
            unTuckBubble(pointerLocationInHost: point, animated: true)
            return
        }

        guard !state.isExpanded, !isInteractingOrDragging else { return }
        resetDwellTimer()
    }

    private func resetDwellTimer() {
        cancelDwellTimer()
        guard state.petResource == nil, !isInteractingOrDragging, !isGeometryTransitioning else { return }
        hoverDwellTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            guard let self,
                  !self.state.isExpanded,
                  !self.isInteractingOrDragging,
                  !self.isGeometryTransitioning else { return }
            self.state.openLatest()
        }
    }

    public func handleMouseExited() {
        cancelDwellTimer()
        if isGeometryTransitioning {
            needsPointerReconciliationAfterGeometry = true
            return
        }

        if state.isExpanded && !state.isPinned && !isInteractingOrDragging {
            scheduleAutoCollapseTimer()
        } else if !state.isExpanded && !state.isDocked && !isInteractingOrDragging {
            scheduleTuck()
        }
    }

    private func scheduleAutoCollapseTimer() {
        collapseTimer?.invalidate()
        collapseTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            guard let self,
                  self.state.isExpanded,
                  !self.state.isPinned,
                  !self.isInteractingOrDragging,
                  !self.isGeometryTransitioning else { return }

            if self.isPointerInAppWindowOrPopover() {
                self.scheduleAutoCollapseTimer()
                return
            }

            self.state.collapse()
        }
    }

    public func scheduleNotificationAutoCollapse(duration: TimeInterval? = nil) {
        cancelNotificationAutoCollapseTimer()
        let interval = duration ?? notificationAutoCollapseDuration
        guard state.isExpanded,
              !state.isPinned,
              !isInteractingOrDragging else { return }

        if isPointerInAppWindowOrPopover() {
            return
        }

        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            guard let self,
                  self.state.isExpanded,
                  !self.state.isPinned,
                  !self.isInteractingOrDragging,
                  !self.isGeometryTransitioning else { return }

            if self.isPointerInAppWindowOrPopover() {
                self.cancelNotificationAutoCollapseTimer()
                return
            }

            self.state.collapse()
        }
        RunLoop.main.add(timer, forMode: .common)
        notificationCollapseTimer = timer
    }

    public func cancelNotificationAutoCollapseTimer() {
        notificationCollapseTimer?.invalidate()
        notificationCollapseTimer = nil
    }

    public func isPointerInAppWindowOrPopover() -> Bool {
        let mouseLocation = NSEvent.mouseLocation
        for appWindow in NSApp.windows {
            guard appWindow.isVisible,
                  appWindow.alphaValue > 0.01,
                  appWindow.frame.width > 10,
                  appWindow.frame.height > 10 else {
                continue
            }
            if let window, appWindow == window {
                if appWindow.frame.contains(mouseLocation),
                   let contentView = appWindow.contentView {
                    let pointInWindow = appWindow.convertPoint(fromScreen: mouseLocation)
                    let pointInHost = contentView.convert(pointInWindow, from: nil)
                    if isPointerInteractive(at: pointInHost, in: contentView.bounds) {
                        return true
                    }
                }
            } else {
                if appWindow.frame.contains(mouseLocation) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Drag Snap
    func performMagneticSnap(for window: NSWindow, pointerLocation: NSPoint) {
        guard runtime.beginSnapGeometry() else {
            if runtime.claimPendingPresentationIfIdle() {
                performPresentationFrameUpdate(animated: pendingPresentationAnimated)
            }
            return
        }

        guard let visible = resolvedVisibleFrame(for: window.frame, preferredPoint: pointerLocation) else {
            let startedNext = finishGeometryActivity()
            if !startedNext, !state.isExpanded {
                scheduleTuck()
            }
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
        suppressHoverUntilPointerMoves()

        let completed: () -> Void = { [weak self] in
            guard let self else { return }
            self.window.orderFrontRegardless()
            self.saveWindowPosition(targetOrigin)
            let startedNext = self.finishGeometryActivity()
            if !startedNext, !self.state.isExpanded {
                self.scheduleTuck()
            }
        }

        if approximatelyEqual(window.frame, targetFrame) {
            window.setFrame(targetFrame, display: true)
            completed()
            return
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            window.animator().setFrame(targetFrame, display: true)
        }, completionHandler: completed)
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
        let visible = OverlayScreenGeometry.presentationVisibleFrame(for: frame, among: visibleFrames)
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
                    self.state.loadHistory()
                    self.state.loadStats()
                }
            }
        }
    }
}
