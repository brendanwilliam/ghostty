import Combine
import SwiftUI

/// The tabs and splits open on one host's terminal screen. Every pane is
/// its own shell on the host. Mirrors Ghostty's tab and split actions.
@MainActor
final class TerminalWorkspace: ObservableObject {
    struct Tab: Identifiable, Equatable, Codable {
        let id: UUID
        var tree: SplitTree
        var focused: UUID
        /// A split shown alone, filling the tab.
        var zoomed: UUID?

        init(id: UUID = UUID(), tree: SplitTree, focused: UUID, zoomed: UUID? = nil) {
            self.id = id
            self.tree = tree
            self.focused = focused
            self.zoomed = zoomed
        }

        /// The panes to show: just the zoomed one, or all of them.
        var visiblePanes: [UUID] { zoomed.map { [$0] } ?? tree.panes }
    }

    let host: Host

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var selectedTabID: UUID
    @Published private(set) var panes: [UUID: TerminalPane] = [:]
    /// Set when the last tab closes; the screen goes back to the host list.
    @Published private(set) var closed = false

    /// The size tabs are laid out in, which sets the default split
    /// direction and scales keyboard resizes.
    var layoutSize = CGSize(width: 390, height: 700) {
        didSet { if layoutSize != oldValue { applyPaneStates() } }
    }

    /// Saves the column count a pinch settles on.
    var onColumnsSettled: ((Int) -> Void)?

    /// The host's zmx sessions, which let panes outlive the app.
    let sessions: HostSessions?

    /// Connects a pane. Tests replace this to avoid SSH.
    private let connector: @MainActor (TerminalPane) async -> Void
    private var columns: Int?
    /// Whether this host has its own column count (otherwise it follows
    /// the default in Settings).
    private var hasOwnColumns: Bool
    private var columnsObserver: NSObjectProtocol?
    private var paneObservers: [UUID: AnyCancellable] = [:]
    /// Each pane's connection, including attaching again after drops.
    private var connections: [UUID: Task<Void, Never>] = [:]
    /// A pane whose surface should take the keyboard once it's shown.
    private var pendingKeyboard: UUID?
    private var started = false

    /// Waits between attempts to attach again. Tests replace this.
    var waitToRetry: @MainActor (Duration) async -> Void = { delay in
        await SessionLifecycle.shared.waitToRetry(after: delay)
    }

    /// Delays between attempts to attach to a dropped session again. It
    /// gives up after the last.
    static let retryDelays: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2), .seconds(4),
                                          .seconds(8), .seconds(15), .seconds(15), .seconds(15)]

    /// - Parameter layout: Tabs and splits saved from an earlier launch,
    ///   whose panes attach to their sessions again.
    init(host: Host, layout: WorkspaceLayout? = nil, sessions: HostSessions? = nil,
         connector: (@MainActor (TerminalPane) async -> Void)? = nil) {
        self.host = host
        self.sessions = sessions
        self.connector = connector ?? { await $0.connect() }
        self.columns = AppSettings.columns(for: host)
        self.hasOwnColumns = host.columns != nil
        if let layout, !layout.tabs.isEmpty {
            tabs = layout.tabs
            selectedTabID = layout.tabs.contains { $0.id == layout.selectedTabID }
                ? layout.selectedTabID : layout.tabs[0].id
            for id in layout.tabs.flatMap(\.tree.panes) {
                add(TerminalPane(id: id, host: host, sessionName: layout.sessions[id]))
            }
            pendingKeyboard = tabs.first { $0.id == selectedTabID }?.focused
        } else {
            let first = TerminalPane(host: host)
            let tab = Tab(tree: SplitTree(first.id), focused: first.id)
            tabs = [tab]
            selectedTabID = tab.id
            pendingKeyboard = first.id
            add(first)
        }
        sessions?.onSessionsFound = { [weak self] found in self?.adopt(found) }
        columnsObserver = NotificationCenter.default.addObserver(
            forName: AppSettings.columnsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.defaultColumnsChanged() }
        }
    }

    deinit {
        if let columnsObserver { NotificationCenter.default.removeObserver(columnsObserver) }
    }

    // MARK: State

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    var focusedPane: TerminalPane? { selectedTab.flatMap { panes[$0.focused] } }

    var title: String { focusedPane?.title ?? host.displayName }

    /// A pane waiting on the user (host key or password), if any.
    var promptingPane: TerminalPane? {
        tabs.lazy.flatMap(\.tree.panes).compactMap { self.panes[$0] }
            .first { $0.hostKeyPrompt != nil || $0.needsPassword }
    }

    /// Portrait stacks new splits so each keeps the full width; landscape
    /// puts them side by side.
    var defaultSplitDirection: SplitDirection {
        layoutSize.height >= layoutSize.width ? .down : .right
    }

    func title(of tab: Tab) -> String {
        panes[tab.focused]?.title ?? host.displayName
    }

    // MARK: Lifecycle

    /// Connect the first pane. Later panes connect as they're opened.
    func start() {
        guard !started else { return }
        started = true
        for pane in tabs.flatMap(\.tree.panes).compactMap({ panes[$0] }) {
            connect(pane)
        }
    }

    /// End every pane, and its session on the host.
    func endAll() {
        for tab in tabs { closeTab(tab.id) }
    }

    /// Connect again after the session ended, optionally with a password.
    func reconnect(_ pane: TerminalPane, password: String? = nil) {
        if pane.id == selectedTab?.focused { pendingKeyboard = pane.id }
        if let password {
            connect(pane) { await $0.connect(password: password) }
        } else {
            connect(pane)
        }
    }

    /// Close every connection, keeping the panes; their zmx sessions keep
    /// running on the host. They attach again once the app is active.
    func suspend() {
        for pane in panes.values where pane.attachedToSession {
            pane.suspend()
        }
    }

    /// Attach again any pane whose session dropped and that gave up
    /// retrying (say while the app was in the background).
    func resume() {
        guard started else { return }
        for pane in panes.values where pane.canReattach && !pane.reconnecting {
            connect(pane)
        }
    }

    /// Run a pane's connection. When a zmx session drops, attach to it
    /// again, backing off, until it works or `retryDelays` run out.
    private func connect(_ pane: TerminalPane, first: (@MainActor (TerminalPane) async -> Void)? = nil) {
        connections[pane.id]?.cancel()
        connections[pane.id] = Task { [weak self, connector] in
            var attempt = 0
            await (first ?? connector)(pane)
            while !Task.isCancelled, let self, self.panes[pane.id] === pane, pane.canReattach {
                guard attempt < Self.retryDelays.count else {
                    pane.reconnecting = false
                    return
                }
                pane.reconnecting = true
                await self.waitToRetry(Self.retryDelays[attempt])
                guard !Task.isCancelled, self.panes[pane.id] === pane else { return }
                let started = ContinuousClock.now
                await connector(pane)
                // A connection that lasted a while starts the backoff over.
                attempt = ContinuousClock.now - started > .seconds(10) ? 0 : attempt + 1
            }
        }
    }

    private func add(_ pane: TerminalPane) {
        pane.sessions = sessions
        pane.onKeyboardHandoff = { [weak self, weak pane] in
            guard let pane else { return }
            self?.pendingKeyboard = pane.id
        }
        // One pane fetches the host's config; the others use the cache.
        pane.syncsRemoteConfig = panes.isEmpty
        pane.onRemoteConfigChanged = { [weak self, weak pane] url in
            guard let self else { return }
            for other in self.panes.values where other !== pane {
                other.surfaceView?.remoteConfig = url
            }
        }
        pane.configureSurface = { [weak self, weak pane] view in
            guard let self, let pane else { return }
            self.configure(view, for: pane)
        }
        paneObservers[pane.id] = pane.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        panes[pane.id] = pane
        if started { connect(pane) }
    }

    private func configure(_ view: TerminalSurfaceView, for pane: TerminalPane) {
        let id = pane.id
        view.targetColumns = columns
        view.onColumnsSettled = { [weak self] columns in
            self?.columnsSettled(columns, from: id)
        }
        view.onAction = { [weak self] action in
            self?.perform(action, from: id) ?? false
        }
        view.onActivate = { [weak self] in self?.focus(id) }
        view.onClose = { [weak self, weak view] in
            // A dropped or failed connection stays open to reconnect.
            guard let view, !view.sessionDropped, !view.startFailed else { return }
            self?.close(id)
        }
        applyPaneStates()
    }

    /// Whether `pane`'s surface should take the keyboard as it's first
    /// shown. Asked once, by the view that shows it.
    func takeKeyboard(for pane: UUID) -> Bool {
        guard pendingKeyboard == pane else { return false }
        pendingKeyboard = nil
        return true
    }

    // MARK: Actions

    /// Do a tab or split action asked for by the pane `source`. Returns
    /// whether it applied.
    @discardableResult
    func perform(_ action: PaneAction, from source: UUID? = nil) -> Bool {
        guard let source = source ?? selectedTab?.focused,
              let tabIndex = tabs.firstIndex(where: { $0.tree.panes.contains(source) }) else { return false }

        switch action {
        case .newTab:
            newTab(after: tabIndex)
        case .newSplit(let direction):
            split(source, in: tabIndex, direction: direction ?? defaultSplitDirection)
        case .gotoSplit(let target):
            let tree = tabs[tabIndex].tree
            let next: UUID?
            switch target {
            case .previous: next = tree.pane(after: source, forward: false)
            case .next: next = tree.pane(after: source)
            case .toward(let direction):
                next = tree.pane(from: source, toward: direction, in: CGRect(origin: .zero, size: layoutSize))
            }
            guard let next else { return false }
            focus(next)
        case .resizeSplit(let direction, let amount):
            let extent = direction.axis == .horizontal ? layoutSize.width : layoutSize.height
            guard extent > 0, tabs[tabIndex].tree.resize(source, toward: direction, by: amount / extent) else {
                return false
            }
        case .equalizeSplits:
            tabs[tabIndex].tree.equalize()
        case .toggleSplitZoom:
            guard tabs[tabIndex].tree.count > 1 else { return false }
            tabs[tabIndex].zoomed = tabs[tabIndex].zoomed == nil ? source : nil
        case .gotoTab(let target):
            guard let index = targetTab(target, from: tabIndex) else { return false }
            select(tabs[index].id)
        case .closeTab(let mode):
            let doomed: [Tab]
            switch mode {
            case .this: doomed = [tabs[tabIndex]]
            case .others: doomed = tabs.enumerated().filter { $0.offset != tabIndex }.map(\.element)
            case .right: doomed = Array(tabs[(tabIndex + 1)...])
            }
            for tab in doomed { closeTab(tab.id) }
        case .closeWindow:
            for tab in tabs { closeTab(tab.id) }
        }
        applyPaneStates()
        return true
    }

    private func targetTab(_ target: PaneAction.TabTarget, from current: Int) -> Int? {
        guard !tabs.isEmpty else { return nil }
        switch target {
        case .index(let n): return n >= 1 ? min(n, tabs.count) - 1 : nil
        case .previous: return (current + tabs.count - 1) % tabs.count
        case .next: return (current + 1) % tabs.count
        case .last: return tabs.count - 1
        }
    }

    private func newTab(after index: Int) {
        let keyboard = focusedSurfaceHasKeyboard
        let pane = TerminalPane(host: host)
        let tab = Tab(tree: SplitTree(pane.id), focused: pane.id)
        tabs.insert(tab, at: index + 1)
        if keyboard { pendingKeyboard = pane.id }
        add(pane)
        selectedTabID = tab.id
    }

    private func split(_ source: UUID, in tabIndex: Int, direction: SplitDirection) {
        let keyboard = focusedSurfaceHasKeyboard
        let pane = TerminalPane(host: host)
        tabs[tabIndex].zoomed = nil
        tabs[tabIndex].tree.insert(pane.id, splitting: source, direction: direction)
        tabs[tabIndex].focused = pane.id
        if keyboard { pendingKeyboard = pane.id }
        add(pane)
        applyPaneStates()
    }

    /// Focus a pane (selecting its tab). The keyboard follows focus if it
    /// was up.
    func focus(_ pane: UUID) {
        guard let index = tabs.firstIndex(where: { $0.tree.panes.contains(pane) }) else { return }
        let keyboard = focusedSurfaceHasKeyboard
        if tabs[index].zoomed != nil, tabs[index].zoomed != pane { tabs[index].zoomed = nil }
        tabs[index].focused = pane
        selectedTabID = tabs[index].id
        applyPaneStates()
        if keyboard { giveKeyboard(to: pane) }
    }

    func select(_ tab: UUID) {
        guard let target = tabs.first(where: { $0.id == tab }) else { return }
        let keyboard = focusedSurfaceHasKeyboard
        selectedTabID = tab
        applyPaneStates()
        if keyboard { giveKeyboard(to: target.focused) }
    }

    /// Split the focused pane (toolbar). Nil uses the orientation default.
    func splitFocused(_ direction: SplitDirection? = nil) {
        perform(.newSplit(direction))
    }

    /// A divider was dragged.
    func setRatio(_ ratio: Double, at path: SplitTree.Path, in tab: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].tree.setRatio(ratio, at: path)
    }

    func equalize(_ tab: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].tree.equalize()
    }

    /// Close one pane. Its tab closes with its last pane, and the screen
    /// with its last tab.
    func close(_ pane: UUID) {
        guard let index = tabs.firstIndex(where: { $0.tree.panes.contains(pane) }) else { return }
        let keyboard = focusedSurfaceHasKeyboard
        var tab = tabs[index]
        let fallback = tab.tree.pane(after: pane, forward: false)
        guard tab.tree.remove(pane) else {
            closeTab(tab.id)
            return
        }
        if tab.zoomed == pane { tab.zoomed = nil }
        if tab.focused == pane, let fallback { tab.focused = fallback }
        tabs[index] = tab
        dispose(pane)
        applyPaneStates()
        if keyboard, tab.id == selectedTabID { giveKeyboard(to: tab.focused) }
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        for pane in tab.tree.panes { dispose(pane) }
        guard !tabs.isEmpty else {
            closed = true
            return
        }
        if selectedTabID == id {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        applyPaneStates()
    }

    /// Close a pane for good, ending its zmx session on the host.
    private func dispose(_ id: UUID) {
        connections[id]?.cancel()
        connections[id] = nil
        if let pane = panes[id] {
            pane.disconnect()
            sessions?.end([pane.sessionName])
        }
        panes[id] = nil
        paneObservers[id] = nil
    }

    // MARK: Saving

    /// The tabs and splits, and each pane's session, to restore later.
    var layout: WorkspaceLayout {
        WorkspaceLayout(
            tabs: tabs,
            selectedTabID: selectedTabID,
            sessions: panes.mapValues(\.sessionName))
    }

    /// Open this device's sessions that no pane shows (say the app quit
    /// before saving) as tabs of their own.
    func adopt(_ found: [String]) {
        guard !closed else { return }
        let shown = Set(panes.values.map(\.sessionName))
        for name in found where !shown.contains(name) {
            let pane = TerminalPane(host: host, sessionName: name)
            tabs.append(Tab(tree: SplitTree(pane.id), focused: pane.id))
            add(pane)
        }
        applyPaneStates()
    }

    // MARK: Focus and layout state

    private var focusedSurfaceHasKeyboard: Bool {
        focusedPane?.surfaceView?.isFirstResponder ?? false
    }

    private func giveKeyboard(to pane: UUID) {
        if let view = panes[pane]?.surfaceView, view.window != nil {
            _ = view.becomeFirstResponder()
        } else {
            pendingKeyboard = pane
        }
    }

    /// Tell each surface whether it's its tab's focused pane, and what
    /// width to fit columns across: its own when alone, else the screen's
    /// so all the tab's panes share a lone pane's font.
    private func applyPaneStates() {
        let screenShortSide = min(layoutSize.width, layoutSize.height)
        for tab in tabs {
            let alone = tab.tree.count == 1
            for id in tab.tree.panes {
                guard let view = panes[id]?.surfaceView else { continue }
                view.isActivePane = id == tab.focused || alone
                view.fitWidth = alone ? nil : screenShortSide
            }
        }
    }

    // MARK: Columns

    private func columnsSettled(_ columns: Int, from pane: UUID) {
        self.columns = columns
        hasOwnColumns = true
        for (id, other) in panes where id != pane {
            other.surfaceView?.targetColumns = columns
        }
        onColumnsSettled?(columns)
    }

    private func defaultColumnsChanged() {
        guard !hasOwnColumns else { return }
        columns = AppSettings.defaultColumns
        for pane in panes.values { pane.surfaceView?.targetColumns = columns }
    }
}
