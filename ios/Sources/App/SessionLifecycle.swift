import UIKit

/// Keeps terminals going across the app's lifecycle. iOS suspends the app
/// soon after it leaves the screen, which drops its connections; panes in
/// zmx sessions keep running on the host and attach again when the app
/// comes back.
///
/// - Going into the background saves the layout and holds connections
///   open for the time iOS allows, so a quick app switch costs nothing.
///   When that runs out they're closed cleanly.
/// - Attaching again waits for the app to be active, and retries early
///   when it becomes active or the network comes back.
@MainActor
final class SessionLifecycle {
    static let shared = SessionLifecycle()

    private(set) var isActive = true
    /// Bumped when it's a good moment to retry (became active, network
    /// back), cutting retry delays short.
    private var wakeups = 0
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var networkToken: NetworkMonitor.Token?
    private var networkUp = true

    private init() {
        networkToken = NetworkMonitor.shared.observe { [weak self] changes, network in
            Task { @MainActor in self?.networkChanged(changes, up: network.satisfied) }
        }
    }

    /// Retry early when there's a new way to reach hosts: the network
    /// came back, the phone moved to another network, or the tailnet
    /// tunnel came up.
    private func networkChanged(_ changes: [NetworkMonitor.Change], up: Bool) {
        networkUp = up
        if changes.contains(where: { [.cameUp, .switched, .tunnelUp].contains($0) }) { wakeups += 1 }
    }

    func didEnterBackground(_ store: WorkspaceStore) {
        isActive = false
        store.saveAll()
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Terminal sessions") { [weak self, weak store] in
            // Out of background time: detach before iOS suspends us.
            MainActor.assumeIsolated {
                store?.suspendAll()
                self?.endBackgroundTask()
            }
        }
    }

    func didBecomeActive() {
        isActive = true
        wakeups += 1
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Wait `delay` before retrying a connection, no sooner than the app
    /// is active. Returns early when the app becomes active or the
    /// network comes back.
    func waitToRetry(after delay: Duration) async {
        let start = wakeups
        let deadline = ContinuousClock.now + delay
        while !Task.isCancelled {
            if isActive && networkUp && (wakeups != start || ContinuousClock.now >= deadline) { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
