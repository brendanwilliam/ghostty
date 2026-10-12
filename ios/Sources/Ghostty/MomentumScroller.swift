import UIKit

/// Keeps a flick scrolling after the finger lifts, decelerating like
/// UIScrollView. The terminal still moves in whole rows; this only
/// supplies the deltas.
@MainActor
final class MomentumScroller {
    /// UIScrollView's normal deceleration (`DecelerationRate.normal`):
    /// the fraction of velocity kept per millisecond.
    nonisolated static let decelerationRate = 0.998
    /// Flicks slower than this (points per second) don't glide.
    nonisolated static let minimumStartVelocity = 100.0
    /// The glide stops once it's slower than this.
    nonisolated static let stopVelocity = 20.0

    struct Step: Equatable {
        var delta: CGPoint
        var velocity: CGPoint
        var done: Bool
    }

    /// Advance a glide by `dt` seconds. Pure, so it can be tested.
    nonisolated static func step(velocity: CGPoint, dt: Double) -> Step {
        let decay = pow(decelerationRate, dt * 1000)
        let next = CGPoint(x: velocity.x * decay, y: velocity.y * decay)
        // Distance travelled is the integral of the decaying velocity.
        let travel = (decay - 1) / log(decelerationRate) / 1000
        let delta = CGPoint(x: velocity.x * travel, y: velocity.y * travel)
        return Step(delta: delta, velocity: next, done: hypot(next.x, next.y) < stopVelocity)
    }

    enum Phase { case began, changed, ended }

    /// Receives each frame's scroll delta (points) and momentum phase.
    private let scroll: (CGPoint, Phase) -> Void
    private var velocity: CGPoint = .zero
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var started = false
    private(set) var isGliding = false

    init(scroll: @escaping (CGPoint, Phase) -> Void) {
        self.scroll = scroll
    }

    /// Start gliding at `velocity` (points per second), if it's fast
    /// enough. `driven` false leaves the stepping to the caller (tests).
    func start(velocity: CGPoint, driven: Bool = true) {
        stop()
        guard hypot(velocity.x, velocity.y) >= Self.minimumStartVelocity else { return }
        self.velocity = velocity
        started = false
        isGliding = true
        guard driven else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    /// Stop gliding, e.g. because the user touched the screen again.
    func stop() {
        guard isGliding else { return }
        link?.invalidate()
        link = nil
        lastTimestamp = nil
        isGliding = false
        if started { scroll(.zero, .ended) }
        started = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastTimestamp.map { now - $0 } ?? link.duration
        lastTimestamp = now
        advance(dt: dt)
    }

    /// One frame of the glide. Internal so tests can drive it without a
    /// display link.
    func advance(dt: Double) {
        guard isGliding else { return }
        let step = Self.step(velocity: velocity, dt: dt)
        velocity = step.velocity
        scroll(step.delta, started ? .changed : .began)
        started = true
        if step.done { stop() }
    }
}
