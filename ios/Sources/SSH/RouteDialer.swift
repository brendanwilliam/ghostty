import Foundation

/// Connects to a host over the best of its routes, Happy Eyeballs style:
/// routes are tried in order, each one starting a moment after the one
/// before (or as soon as it fails), and the first to connect wins. A
/// working tailnet route wins over the local network without making the
/// local network wait out a tailnet that isn't up.
enum RouteDialer {
    /// How long a route gets before the next one starts too.
    static let headStart: Duration = .milliseconds(300)

    enum DialError: LocalizedError {
        case noRoutes
        var errorDescription: String? { "The host has no address" }
    }

    /// Routes in the order to try them: tailnet routes first when the
    /// phone's tunnel is up (last when it isn't, since they can't work),
    /// with `preferred` (the route that last worked on this network)
    /// ahead of others of its kind.
    static func order(_ routes: [HostRoute], tunnelUp: Bool, preferred: HostRoute? = nil) -> [HostRoute] {
        let rank: (HostRoute) -> Int = { route in
            switch route.kind {
            case .tailnet: tunnelUp ? 0 : 3
            case .lan: 1
            case .other: 2
            }
        }
        return routes.enumerated()
            .sorted { a, b in
                let ka = (rank(a.element), a.element == preferred ? 0 : 1, a.offset)
                let kb = (rank(b.element), b.element == preferred ? 0 : 1, b.offset)
                return ka < kb
            }
            .map(\.element)
    }

    /// Dial `routes` in order and return the first to connect. Later
    /// winners are handed to `discard`. If all fail, throws the most
    /// telling error (a changed host key over anything else).
    ///
    /// - Parameter staggered: Whether to start routes before the one
    ///   before has failed. Off until the host's key is trusted, so the
    ///   user is asked about it once.
    static func race<T: Sendable>(
        _ routes: [HostRoute],
        staggered: Bool = true,
        headStart: Duration = RouteDialer.headStart,
        dial: @escaping @Sendable (HostRoute) async throws -> T,
        discard: @escaping @Sendable (T) async -> Void
    ) async throws -> (HostRoute, T) {
        guard !routes.isEmpty else { throw DialError.noRoutes }
        let race = Race<T>(count: routes.count)
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            Task {
                for (index, route) in routes.enumerated() {
                    guard !race.isDecided else { return }
                    race.started()
                    Task {
                        do {
                            let value = try await dial(route)
                            if !race.win(route, value) { await discard(value) }
                        } catch {
                            race.fail(error)
                        }
                    }
                    guard index < routes.count - 1 else { return }
                    await race.waitForNext(after: staggered ? headStart : nil)
                }
            }
        }
    }
}

/// The state of one `RouteDialer.race`.
private final class Race<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private var startedCount = 0
    private var failures = 0
    private var decided = false
    private var error: Error?
    var continuation: CheckedContinuation<(HostRoute, T), Error>?

    init(count: Int) {
        self.count = count
    }

    var isDecided: Bool { lock.withLock { decided } }

    func started() {
        lock.withLock { startedCount += 1 }
    }

    /// Returns whether `value` won.
    func win(_ route: HostRoute, _ value: T) -> Bool {
        let continuation: CheckedContinuation<(HostRoute, T), Error>? = lock.withLock {
            guard !decided else { return nil }
            decided = true
            return self.continuation
        }
        guard let continuation else { return false }
        continuation.resume(returning: (route, value))
        return true
    }

    func fail(_ error: Error) {
        let finished: (CheckedContinuation<(HostRoute, T), Error>, Error)? = lock.withLock {
            failures += 1
            if Self.priority(error) >= Self.priority(self.error) { self.error = error }
            guard !decided, failures == count, let continuation, let worst = self.error else { return nil }
            decided = true
            return (continuation, worst)
        }
        if let (continuation, error) = finished { continuation.resume(throwing: error) }
    }

    /// Wait until the next route should start: after `headStart`, or
    /// once every route started so far has failed. Nil waits only for
    /// failures.
    func waitForNext(after headStart: Duration?) async {
        let deadline = headStart.map { ContinuousClock.now + $0 }
        while true {
            let (done, allFailed): (Bool, Bool) = lock.withLock { (decided, failures == startedCount) }
            if done || allFailed { return }
            if let deadline, ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Which error to report when every route fails: the one the user
    /// most needs to see.
    private static func priority(_ error: Error?) -> Int {
        switch error {
        case nil: return 0
        case let error as SSHSessionError:
            switch error {
            case .hostKeyMismatch: return 4
            case .hostKeyRejected: return 3
            case .authenticationFailed: return 2
            }
        default: return 1
        }
    }
}
