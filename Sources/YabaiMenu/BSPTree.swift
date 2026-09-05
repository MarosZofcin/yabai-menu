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

struct BSPWindowSnapshot: Codable, Equatable, Sendable {
    let id: Int
    let frame: YabaiFrame
    let space: Int
    let display: Int
    let splitType: BSPSplitAxis
    let splitChild: BSPSplitChild
    let stackIndex: Int
    let hasAXReference: Bool
    let isVisible: Bool
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
        case hasAXReference = "has-ax-reference"
        case isVisible = "is-visible"
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
    let window: BSPWindowSnapshot
    let space: Int
    let display: BSPDisplaySnapshot
    let branches: [BSPBranch]
}

enum BSPWarpDirection: String, CaseIterable, Sendable {
    case north
    case east
    case south
    case west

    static func nearestEdge(to point: CGPoint, in frame: CGRect) -> BSPWarpDirection {
        let distances: [(BSPWarpDirection, CGFloat)] = [
            (.west, abs(point.x - frame.minX)),
            (.east, abs(frame.maxX - point.x)),
            (.north, abs(point.y - frame.minY)),
            (.south, abs(frame.maxY - point.y))
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .east
    }

    func previewFrame(in frame: CGRect) -> CGRect {
        switch self {
        case .west:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .east:
            return CGRect(x: frame.midX, y: frame.minY, width: frame.width / 2, height: frame.height)
        case .north:
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height / 2)
        case .south:
            return CGRect(x: frame.minX, y: frame.midY, width: frame.width, height: frame.height / 2)
        }
    }
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

// Decision logic lives in Runtime/runtime.js. Native code only marshals data,
// validates geometry and maps stable error codes for existing callers.
struct BSPTreeResolver {
    private let tolerance: CGFloat
    private let candidateLimit: Int

    init(tolerance: CGFloat = 1.5, candidateLimit: Int = 256) {
        self.tolerance = tolerance
        self.candidateLimit = candidateLimit
    }

    func branches(for targetWindowID: Int, in snapshots: [BSPWindowSnapshot]) throws -> [BSPBranch] {
        let data = try JSONEncoder().encode(snapshots)
        let windows = try JSONSerialization.jsonObject(with: data)
        let result: Any
        do {
            result = try RuntimeController.shared.call("bspBranches", input: [
                "target": targetWindowID, "snapshots": windows,
                "tolerance": Double(tolerance), "candidateLimit": candidateLimit
            ])
        } catch {
            switch error.localizedDescription {
            case "targetNotFound": throw BSPTreeError.targetNotFound
            case "targetNotTiled": throw BSPTreeError.targetNotTiled
            case "noParentBranch": throw BSPTreeError.noParentBranch
            case "inconsistentLeafMetadata": throw BSPTreeError.inconsistentLeafMetadata
            case "hierarchyCouldNotBeResolved": throw BSPTreeError.hierarchyCouldNotBeResolved
            case "ambiguousHierarchy": throw BSPTreeError.ambiguousHierarchy
            default: throw error
            }
        }
        guard let rows = result as? [[String: Any]], !rows.isEmpty, rows.count <= snapshots.count else {
            throw BSPTreeError.hierarchyCouldNotBeResolved
        }
        let knownIDs = Set(snapshots.map(\.id))
        return try rows.map { row in
            guard let ids = row["windowIDs"] as? [Int], ids.contains(targetWindowID),
                  Set(ids).isSubset(of: knownIDs),
                  let f = row["frame"] as? [String: Double],
                  let x = f["x"], let y = f["y"], let w = f["w"], let h = f["h"],
                  [x,y,w,h].allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }),
                  w > 0, h > 0 else { throw BSPTreeError.hierarchyCouldNotBeResolved }
            return BSPBranch(frame: CGRect(x: x, y: y, width: w, height: h), windowIDs: Set(ids))
        }
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
