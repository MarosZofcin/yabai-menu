import CoreGraphics
import Foundation

enum BSPSplitAxis: String, Codable, Sendable {
    case none
    case vertical
    case horizontal
    case auto
}

enum BSPSplitChild: String, Codable, Sendable {
    case none
    case first = "first_child"
    case second = "second_child"
}

struct YabaiFrame: Codable, Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

struct BSPWindowSnapshot: Decodable, Equatable, Sendable {
    let id: Int
    let frame: YabaiFrame
    let space: Int
    let display: Int
    let splitType: BSPSplitAxis
    let splitChild: BSPSplitChild
    let stackIndex: Int
    let isFloating: Bool
    let isMinimized: Bool
    let isHidden: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case frame
        case space
        case display
        case splitType = "split-type"
        case splitChild = "split-child"
        case stackIndex = "stack-index"
        case isFloating = "is-floating"
        case isMinimized = "is-minimized"
        case isHidden = "is-hidden"
    }
}

struct BSPBranch: Equatable, Sendable {
    let frame: CGRect
    let windowIDs: Set<Int>
}

struct BSPBranchSelection: Sendable {
    let windowID: Int
    let space: Int
    let display: BSPDisplaySnapshot
    let branches: [BSPBranch]
}

/// A display frame is reported by yabai in the same global coordinate system as
/// its window frames. Keeping it with a selection lets the overlay map a frame
/// to the matching `NSScreen` without guessing from its position.
struct BSPDisplaySnapshot: Decodable, Equatable, Sendable {
    let id: UInt32
    let index: Int
    let frame: YabaiFrame
}

enum BSPTreeError: LocalizedError {
    case targetNotFound
    case targetNotTiled
    case noParentBranch
    case inconsistentLeafMetadata
    case hierarchyCouldNotBeResolved
    case ambiguousHierarchy

    var errorDescription: String? {
        switch self {
        case .targetNotFound:
            return "The clicked window is no longer available."
        case .targetNotTiled:
            return "The clicked window is not a tiled BSP window."
        case .noParentBranch:
            return "The clicked window has no BSP parent branch."
        case .inconsistentLeafMetadata:
            return "yabai returned inconsistent BSP metadata for a tiled region."
        case .hierarchyCouldNotBeResolved:
            return "The BSP hierarchy could not be reconstructed from yabai's current state."
        case .ambiguousHierarchy:
            return "The BSP hierarchy is ambiguous, so no potentially incorrect overlay was shown."
        }
    }
}

struct BSPTreeResolver {
    private let tolerance: CGFloat
    private let candidateLimit: Int

    init(tolerance: CGFloat = 1.5, candidateLimit: Int = 256) {
        self.tolerance = tolerance
        self.candidateLimit = candidateLimit
    }

    func branches(
        for targetWindowID: Int,
        in snapshots: [BSPWindowSnapshot]
    ) throws -> [BSPBranch] {
        guard let target = snapshots.first(where: { $0.id == targetWindowID }) else {
            throw BSPTreeError.targetNotFound
        }
        guard !target.isFloating, !target.isMinimized, !target.isHidden else {
            throw BSPTreeError.targetNotTiled
        }

        let relevant = snapshots.filter {
            $0.space == target.space
                && $0.display == target.display
                && !$0.isFloating
                && !$0.isMinimized
                && !$0.isHidden
                && $0.frame.w > 0
                && $0.frame.h > 0
        }
        guard Set(relevant.map(\.id)).count == relevant.count else {
            throw BSPTreeError.hierarchyCouldNotBeResolved
        }
        let leaves = try groupedLeaves(from: relevant)
        guard leaves.contains(where: { $0.windowIDs.contains(targetWindowID) }) else {
            throw BSPTreeError.targetNotTiled
        }
        guard leaves.count > 1 else { throw BSPTreeError.noParentBranch }

        var builder = CandidateBuilder(
            leaves: leaves,
            tolerance: tolerance,
            candidateLimit: candidateLimit
        )
        let candidates = builder.build(indices: Array(leaves.indices))
        // A partial search can never prove that all plausible trees produce the
        // same branch path. Hide the overlay rather than presenting a guess.
        guard !builder.didReachCandidateLimit else {
            throw BSPTreeError.ambiguousHierarchy
        }
        guard !candidates.isEmpty else { throw BSPTreeError.hierarchyCouldNotBeResolved }

        let paths = candidates.compactMap { candidate -> [BSPBranch]? in
            let path = candidate.branches(to: targetWindowID)
            return path.isEmpty ? nil : path
        }
        guard let firstPath = paths.first else { throw BSPTreeError.noParentBranch }
        let firstSignature = Self.pathSignature(firstPath)
        guard paths.dropFirst().allSatisfy({ Self.pathSignature($0) == firstSignature }) else {
            throw BSPTreeError.ambiguousHierarchy
        }
        return firstPath
    }

    private func groupedLeaves(from snapshots: [BSPWindowSnapshot]) throws -> [Leaf] {
        var groups: [[BSPWindowSnapshot]] = []
        for snapshot in snapshots.sorted(by: { $0.id < $1.id }) {
            if let index = groups.firstIndex(where: {
                guard let first = $0.first else { return false }
                return approximatelyEqual(first.frame.rect, snapshot.frame.rect)
            }) {
                groups[index].append(snapshot)
            } else {
                groups.append([snapshot])
            }
        }

        return try groups.enumerated().map { index, group in
            guard let first = group.first,
                  group.allSatisfy({
                      $0.splitType == first.splitType && $0.splitChild == first.splitChild
                  }) else {
                throw BSPTreeError.inconsistentLeafMetadata
            }
            let stackIndices = group.map(\.stackIndex)
            if group.count == 1 {
                guard stackIndices == [0] else {
                    throw BSPTreeError.inconsistentLeafMetadata
                }
            } else {
                let expected = Set(1...group.count)
                guard Set(stackIndices) == expected else {
                    throw BSPTreeError.inconsistentLeafMetadata
                }
            }
            return Leaf(
                index: index,
                windowIDs: Set(group.map(\.id)),
                frame: first.frame.rect,
                parentAxis: first.splitType,
                parentChild: first.splitChild
            )
        }
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func pathSignature(_ path: [BSPBranch]) -> [[Int]] {
        path.map { $0.windowIDs.sorted() }
    }
}

private struct Leaf {
    let index: Int
    let windowIDs: Set<Int>
    let frame: CGRect
    let parentAxis: BSPSplitAxis
    let parentChild: BSPSplitChild
}

private indirect enum CandidateNode {
    case leaf(Leaf)
    case split(axis: BSPSplitAxis, first: CandidateNode, second: CandidateNode, frame: CGRect)

    var frame: CGRect {
        switch self {
        case .leaf(let leaf): return leaf.frame
        case .split(_, _, _, let frame): return frame
        }
    }

    var windowIDs: Set<Int> {
        switch self {
        case .leaf(let leaf):
            return leaf.windowIDs
        case .split(_, let first, let second, _):
            return first.windowIDs.union(second.windowIDs)
        }
    }

    var signature: String {
        switch self {
        case .leaf(let leaf):
            return "L[\(leaf.index)]"
        case .split(let axis, let first, let second, _):
            return "\(axis.rawValue)(\(first.signature),\(second.signature))"
        }
    }

    func branches(to windowID: Int) -> [BSPBranch] {
        switch self {
        case .leaf:
            return []
        case .split(_, let first, let second, let frame):
            if first.windowIDs.contains(windowID) {
                return first.branches(to: windowID)
                    + [BSPBranch(frame: frame, windowIDs: windowIDs)]
            }
            if second.windowIDs.contains(windowID) {
                return second.branches(to: windowID)
                    + [BSPBranch(frame: frame, windowIDs: windowIDs)]
            }
            return []
        }
    }
}

private struct CandidateBuilder {
    let leaves: [Leaf]
    let tolerance: CGFloat
    let candidateLimit: Int
    private var memo: [String: [CandidateNode]] = [:]
    private(set) var didReachCandidateLimit = false

    init(leaves: [Leaf], tolerance: CGFloat, candidateLimit: Int) {
        self.leaves = leaves
        self.tolerance = tolerance
        self.candidateLimit = candidateLimit
    }

    mutating func build(indices: [Int]) -> [CandidateNode] {
        let key = indices.sorted().map(String.init).joined(separator: ",")
        if let cached = memo[key] { return cached }
        if indices.count == 1 {
            let result = [CandidateNode.leaf(leaves[indices[0]])]
            memo[key] = result
            return result
        }

        var result: [CandidateNode] = []
        var signatures = Set<String>()
        for axis in [BSPSplitAxis.vertical, .horizontal] {
            for partition in partitions(indices: indices, axis: axis) {
                let firstCandidates = build(indices: partition.first)
                let secondCandidates = build(indices: partition.second)
                for first in firstCandidates where childMatches(first, axis: axis, child: .first) {
                    for second in secondCandidates where childMatches(second, axis: axis, child: .second) {
                        let node = CandidateNode.split(
                            axis: axis,
                            first: first,
                            second: second,
                            frame: first.frame.union(second.frame)
                        )
                        if signatures.insert(node.signature).inserted {
                            if result.count == candidateLimit {
                                // Do not silently return a prefix: a later
                                // candidate could have a different ancestor
                                // path for the clicked window.
                                didReachCandidateLimit = true
                            } else if result.count < candidateLimit {
                                result.append(node)
                            }
                        }
                    }
                }
            }
        }
        memo[key] = result
        return result
    }

    private func partitions(indices: [Int], axis: BSPSplitAxis) -> [(first: [Int], second: [Int])] {
        let sorted = indices.sorted { lhs, rhs in
            let a = leaves[lhs].frame
            let b = leaves[rhs].frame
            if axis == .vertical {
                return a.minX == b.minX ? a.minY < b.minY : a.minX < b.minX
            }
            return a.minY == b.minY ? a.minX < b.minX : a.minY < b.minY
        }
        guard sorted.count > 1 else { return [] }

        var result: [(first: [Int], second: [Int])] = []
        for splitIndex in 1..<sorted.count {
            let first = Array(sorted[..<splitIndex])
            let second = Array(sorted[splitIndex...])
            let firstFrame = boundingFrame(first)
            let secondFrame = boundingFrame(second)
            let separated: Bool
            let matchingSpan: Bool
            if axis == .vertical {
                separated = firstFrame.maxX <= secondFrame.minX + tolerance
                matchingSpan = abs(firstFrame.minY - secondFrame.minY) <= tolerance
                    && abs(firstFrame.maxY - secondFrame.maxY) <= tolerance
            } else {
                separated = firstFrame.maxY <= secondFrame.minY + tolerance
                matchingSpan = abs(firstFrame.minX - secondFrame.minX) <= tolerance
                    && abs(firstFrame.maxX - secondFrame.maxX) <= tolerance
            }
            if separated && matchingSpan {
                result.append((first, second))
            }
        }
        return result
    }

    private func boundingFrame(_ indices: [Int]) -> CGRect {
        indices.dropFirst().reduce(leaves[indices[0]].frame) {
            $0.union(leaves[$1].frame)
        }
    }

    private func childMatches(
        _ candidate: CandidateNode,
        axis: BSPSplitAxis,
        child: BSPSplitChild
    ) -> Bool {
        guard case .leaf(let leaf) = candidate else { return true }
        return leaf.parentAxis == axis && leaf.parentChild == child
    }
}

enum BSPCoordinateConverter {
    static func appKitRect(
        fromYabai rect: CGRect,
        yabaiDisplayFrame: CGRect,
        appKitScreenFrame: CGRect
    ) -> CGRect? {
        guard yabaiDisplayFrame.width > 0, yabaiDisplayFrame.height > 0 else {
            return nil
        }
        let xScale = appKitScreenFrame.width / yabaiDisplayFrame.width
        let yScale = appKitScreenFrame.height / yabaiDisplayFrame.height
        return CGRect(
            x: appKitScreenFrame.minX + (rect.minX - yabaiDisplayFrame.minX) * xScale,
            y: appKitScreenFrame.maxY - (rect.maxY - yabaiDisplayFrame.minY) * yScale,
            width: rect.width * xScale,
            height: rect.height * yScale
        )
    }
}
