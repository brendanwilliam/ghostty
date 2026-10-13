import CoreGraphics
import Foundation

/// Where a new split goes relative to the pane it splits, as in Ghostty's
/// `new_split:<direction>`.
enum SplitDirection: Equatable {
    case right, down, left, up

    var axis: SplitAxis { self == .right || self == .left ? .horizontal : .vertical }
}

/// How a split arranges its two children.
enum SplitAxis: Equatable {
    /// Side by side, with a vertical divider (Ghostty's split right/left).
    case horizontal
    /// Stacked, with a horizontal divider (Ghostty's split down/up).
    case vertical
}

/// The panes of one tab as a binary tree of splits, modeled on the macOS
/// app's `SplitTree` (macos/Sources/Features/Splits/SplitTree.swift).
struct SplitTree: Equatable {
    indirect enum Node: Equatable {
        case leaf(UUID)
        /// `ratio` is the share of the space the first child gets.
        case split(SplitAxis, ratio: Double, first: Node, second: Node)
    }

    /// Identifies a split node: the turns (false = first, true = second)
    /// taken from the root to reach it.
    typealias Path = [Bool]

    /// A divider between the two children of the split at `path`.
    struct Divider: Equatable {
        var path: Path
        var axis: SplitAxis
        /// The whole split's frame, which the divider moves across.
        var bounds: CGRect
        var ratio: Double
    }

    static let ratioRange = 0.1...0.9

    private(set) var root: Node

    init(_ pane: UUID) {
        root = .leaf(pane)
    }

    /// Panes in order, first to last (left to right, top to bottom).
    var panes: [UUID] { Self.leaves(root) }

    var count: Int { panes.count }

    private static func leaves(_ node: Node) -> [UUID] {
        switch node {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return leaves(first) + leaves(second)
        }
    }

    // MARK: Editing

    /// Split `target`, putting `pane` on the `direction` side of it.
    mutating func insert(_ pane: UUID, splitting target: UUID, direction: SplitDirection) {
        root = Self.insert(pane, splitting: target, direction: direction, in: root)
    }

    private static func insert(_ pane: UUID, splitting target: UUID, direction: SplitDirection, in node: Node) -> Node {
        switch node {
        case .leaf(let id) where id == target:
            let new = Node.leaf(pane)
            let after = direction == .right || direction == .down
            return .split(direction.axis, ratio: 0.5, first: after ? node : new, second: after ? new : node)
        case .leaf:
            return node
        case .split(let axis, let ratio, let first, let second):
            return .split(axis, ratio: ratio,
                          first: insert(pane, splitting: target, direction: direction, in: first),
                          second: insert(pane, splitting: target, direction: direction, in: second))
        }
    }

    /// Remove `pane`; its sibling takes the parent's place. Returns false
    /// (and changes nothing) when it's the last pane.
    @discardableResult
    mutating func remove(_ pane: UUID) -> Bool {
        guard let node = Self.remove(pane, from: root) else { return false }
        root = node
        return true
    }

    private static func remove(_ pane: UUID, from node: Node) -> Node? {
        switch node {
        case .leaf(let id):
            return id == pane ? nil : node
        case .split(let axis, let ratio, let first, let second):
            guard let newFirst = remove(pane, from: first) else { return second }
            guard let newSecond = remove(pane, from: second) else { return first }
            return .split(axis, ratio: ratio, first: newFirst, second: newSecond)
        }
    }

    /// Set the ratio of the split at `path`, clamped so neither side
    /// vanishes.
    mutating func setRatio(_ ratio: Double, at path: Path) {
        root = Self.update(root, at: path[...]) { node in
            guard case .split(let axis, _, let first, let second) = node else { return node }
            let clamped = min(max(ratio, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
            return .split(axis, ratio: clamped, first: first, second: second)
        }
    }

    private static func update(_ node: Node, at path: ArraySlice<Bool>, _ change: (Node) -> Node) -> Node {
        guard let turn = path.first else { return change(node) }
        guard case .split(let axis, let ratio, let first, let second) = node else { return node }
        let rest = path.dropFirst()
        return turn
            ? .split(axis, ratio: ratio, first: first, second: update(second, at: rest, change))
            : .split(axis, ratio: ratio, first: update(first, at: rest, change), second: second)
    }

    /// Move the edge of `pane` that faces `direction` by `fraction` of the
    /// enclosing split, as Ghostty's `resize_split` does. Returns false if
    /// no split has an edge on that side of the pane.
    @discardableResult
    mutating func resize(_ pane: UUID, toward direction: SplitDirection, by fraction: Double) -> Bool {
        guard let path = Self.pathToLeaf(pane, in: root) else { return false }
        // The nearest ancestor split along the direction's axis.
        var prefix = path
        while !prefix.isEmpty {
            prefix.removeLast()
            guard case .split(let axis, let ratio, _, _) = node(at: prefix), axis == direction.axis else { continue }
            let grows = direction == .right || direction == .down
            setRatio(ratio + (grows ? fraction : -fraction), at: prefix)
            return true
        }
        return false
    }

    /// Give every pane an equal share, as Ghostty's `equalize_splits`.
    mutating func equalize() {
        root = Self.equalize(root)
    }

    private static func equalize(_ node: Node) -> Node {
        guard case .split(let axis, _, let first, let second) = node else { return node }
        let a = weight(first, along: axis), b = weight(second, along: axis)
        return .split(axis, ratio: a / (a + b), first: equalize(first), second: equalize(second))
    }

    /// How many panes a subtree lines up along `axis`.
    private static func weight(_ node: Node, along axis: SplitAxis) -> Double {
        guard case .split(let nodeAxis, _, let first, let second) = node else { return 1 }
        let a = weight(first, along: axis), b = weight(second, along: axis)
        return nodeAxis == axis ? a + b : max(a, b)
    }

    // MARK: Lookup

    private func node(at path: Path) -> Node {
        var node = root
        for turn in path {
            guard case .split(_, _, let first, let second) = node else { break }
            node = turn ? second : first
        }
        return node
    }

    private static func pathToLeaf(_ pane: UUID, in node: Node) -> Path? {
        switch node {
        case .leaf(let id):
            return id == pane ? [] : nil
        case .split(_, _, let first, let second):
            if let path = pathToLeaf(pane, in: first) { return [false] + path }
            if let path = pathToLeaf(pane, in: second) { return [true] + path }
            return nil
        }
    }

    /// The pane after (or before) `pane`, wrapping around.
    func pane(after pane: UUID, forward: Bool = true) -> UUID? {
        let all = panes
        guard let index = all.firstIndex(of: pane), all.count > 1 else { return nil }
        let next = (index + (forward ? 1 : all.count - 1)) % all.count
        return all[next]
    }

    /// The nearest pane in `direction` from `pane`, within `bounds`.
    func pane(from pane: UUID, toward direction: SplitDirection, in bounds: CGRect) -> UUID? {
        let frames = self.frames(in: bounds)
        guard let origin = frames[pane] else { return nil }
        var best: (UUID, CGFloat)?
        for (id, frame) in frames where id != pane {
            let distance: CGFloat
            let overlaps: Bool
            switch direction {
            case .left:
                distance = origin.minX - frame.maxX
                overlaps = frame.minY < origin.maxY && frame.maxY > origin.minY
            case .right:
                distance = frame.minX - origin.maxX
                overlaps = frame.minY < origin.maxY && frame.maxY > origin.minY
            case .up:
                distance = origin.minY - frame.maxY
                overlaps = frame.minX < origin.maxX && frame.maxX > origin.minX
            case .down:
                distance = frame.minY - origin.maxY
                overlaps = frame.minX < origin.maxX && frame.maxX > origin.minX
            }
            guard overlaps, distance >= -0.5 else { continue }
            if best == nil || distance < best!.1 { best = (id, distance) }
        }
        return best?.0
    }

    // MARK: Layout

    /// Each pane's frame within `bounds`, leaving `gap` between panes for
    /// the divider.
    func frames(in bounds: CGRect, gap: CGFloat = 0) -> [UUID: CGRect] {
        var result: [UUID: CGRect] = [:]
        Self.layout(root, in: bounds, gap: gap, path: []) { node, rect, _ in
            if case .leaf(let id) = node { result[id] = rect }
        }
        return result
    }

    /// The dividers within `bounds`, one per split.
    func dividers(in bounds: CGRect, gap: CGFloat = 0) -> [Divider] {
        var result: [Divider] = []
        Self.layout(root, in: bounds, gap: gap, path: []) { node, rect, path in
            if case .split(let axis, let ratio, _, _) = node {
                result.append(Divider(path: path, axis: axis, bounds: rect, ratio: ratio))
            }
        }
        return result
    }

    private static func layout(_ node: Node, in rect: CGRect, gap: CGFloat, path: Path,
                               _ visit: (Node, CGRect, Path) -> Void) {
        visit(node, rect, path)
        guard case .split(let axis, let ratio, let first, let second) = node else { return }
        let (a, b) = split(rect, axis: axis, ratio: ratio, gap: gap)
        layout(first, in: a, gap: gap, path: path + [false], visit)
        layout(second, in: b, gap: gap, path: path + [true], visit)
    }

    /// Divide `rect` at `ratio`, leaving `gap` between the halves.
    static func split(_ rect: CGRect, axis: SplitAxis, ratio: Double, gap: CGFloat) -> (CGRect, CGRect) {
        switch axis {
        case .horizontal:
            let usable = max(0, rect.width - gap)
            let firstWidth = (usable * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height),
                    CGRect(x: rect.minX + firstWidth + gap, y: rect.minY,
                           width: usable - firstWidth, height: rect.height))
        case .vertical:
            let usable = max(0, rect.height - gap)
            let firstHeight = (usable * ratio).rounded()
            return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight),
                    CGRect(x: rect.minX, y: rect.minY + firstHeight + gap,
                           width: rect.width, height: usable - firstHeight))
        }
    }
}
