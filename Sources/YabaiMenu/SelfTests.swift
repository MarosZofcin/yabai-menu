import Foundation

enum SelfTests {
    static func run() throws {
        let identifier = YabaiController.stableIdentifier(name: "Google Chrome", bundleIdentifier: "com.google.Chrome")
        guard identifier == YabaiController.stableIdentifier(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"), identifier.count == 16 else {
            throw AppError.message("Stable yabai rule identifiers failed.")
        }

        guard GitSyncController.pathFromStatusLine(" M yabai/floating-apps.json") == "yabai/floating-apps.json",
              GitSyncController.pathFromStatusLine("?? yabai/floating-apps.json") == "yabai/floating-apps.json",
              GitSyncController.pathFromStatusLine("R  old.json -> yabai/floating-apps.json") == "yabai/floating-apps.json" else {
            throw AppError.message("Git status path parsing failed.")
        }

        try testBSPTreeResolution()
        try testBSPCoordinateConversion()
        try testBSPWarpDirections()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let yabairc = directory.appendingPathComponent("yabairc")
        let source = """
        #!/usr/bin/env sh
        # --- Okná mimo tilingu ---
        for LABEL in float-finder float-whatsapp; do
            yabai -m rule --remove "$LABEL" 2>/dev/null || true
        done
        yabai -m rule --add label=float-finder app="^Finder$" manage=off
        yabai -m rule --add label=float-whatsapp app="^.*WhatsApp$" manage=off
        yabai -m rule --apply
        """
        try source.write(to: yabairc, atomically: true, encoding: .utf8)
        let store = YabaircBlacklistStore(fileURL: yabairc)
        let existing = try store.load()
        guard existing.map(\.name) == ["Finder", "WhatsApp"] else {
            throw AppError.message("Existing yabairc rule parsing failed.")
        }
        let change = try store.adding(RunningApplication(name: "Google Chrome", bundleIdentifier: "com.google.Chrome"))
        guard change.new.map(\.name) == ["Finder", "Google Chrome", "WhatsApp"] else {
            throw AppError.message("yabairc blacklist editing failed.")
        }
        let migrated = try String(contentsOf: yabairc, encoding: .utf8)
        guard migrated.contains(YabaircBlacklistStore.beginMarker),
              migrated.contains(YabaircBlacklistStore.endMarker),
              migrated.contains("# --- Okná mimo tilingu ---"),
              migrated.components(separatedBy: "manage=off").count - 1 == 3 else {
            throw AppError.message("yabairc managed-block migration failed.")
        }

        try testLocalGitSynchronization(in: directory)
    }

    private static func testBSPTreeResolution() throws {
        let resolver = BSPTreeResolver()

        let twoWindowTree = SyntheticBSPNode.split(
            .vertical,
            .leaf([1]),
            .leaf([2])
        )
        let twoWindows = syntheticSnapshots(from: twoWindowTree)
        let firstPath = try resolver.branches(for: 1, in: twoWindows)
        try requireBranchPath(firstPath, equals: [[1, 2]], label: "two-window tree")

        let exampleTree = SyntheticBSPNode.split(
            .horizontal,
            .split(
                .vertical,
                .split(.vertical, .leaf([1]), .leaf([2])),
                .split(.vertical, .leaf([3]), .leaf([7]))
            ),
            .split(
                .vertical,
                .leaf([4]),
                .split(.vertical, .leaf([5]), .leaf([6]))
            )
        )
        let exampleWindows = syntheticSnapshots(from: exampleTree)
        let examplePath = try resolver.branches(for: 3, in: exampleWindows)
        try requireBranchPath(
            examplePath,
            equals: [[3, 7], [1, 2, 3, 7], [1, 2, 3, 4, 5, 6, 7]],
            label: "documented C/G example"
        )

        let skewedTree = SyntheticBSPNode.split(
            .vertical,
            .leaf([10]),
            .split(
                .horizontal,
                .leaf([11]),
                .split(
                    .vertical,
                    .leaf([12]),
                    .split(.horizontal, .leaf([13]), .leaf([14]))
                )
            )
        )
        let skewedPath = try resolver.branches(for: 14, in: syntheticSnapshots(from: skewedTree))
        try requireBranchPath(
            skewedPath,
            equals: [[13, 14], [12, 13, 14], [11, 12, 13, 14], [10, 11, 12, 13, 14]],
            label: "deep skewed tree"
        )

        let asymmetric = [
            snapshot(
                id: 15,
                frame: CGRect(x: 0, y: 0, width: 280, height: 800),
                axis: .vertical,
                child: .first
            ),
            snapshot(
                id: 16,
                frame: CGRect(x: 290, y: 0, width: 910, height: 340),
                axis: .horizontal,
                child: .first
            ),
            snapshot(
                id: 17,
                frame: CGRect(x: 290, y: 350, width: 910, height: 450),
                axis: .horizontal,
                child: .second
            )
        ]
        let asymmetricPath = try resolver.branches(for: 17, in: asymmetric)
        try requireBranchPath(
            asymmetricPath,
            equals: [[16, 17], [15, 16, 17]],
            label: "asymmetric split ratios"
        )

        let stackedTree = SyntheticBSPNode.split(
            .vertical,
            .leaf([20, 21]),
            .leaf([22])
        )
        let stackedPath = try resolver.branches(for: 21, in: syntheticSnapshots(from: stackedTree))
        try requireBranchPath(stackedPath, equals: [[20, 21, 22]], label: "stacked leaf")

        // Regression fixture captured from yabai 7.1.25. A Space query can
        // include stale windows without an AX reference. Those records report
        // `is-floating: false`, but they are not leaves in the current BSP
        // tree and must not participate in reconstruction.
        let yabaiSevenRealSpace = [
            snapshot(
                id: 2195,
                frame: CGRect(x: 0, y: 31, width: 540, height: 1189),
                axis: .vertical,
                child: .first
            ),
            snapshot(
                id: 4585,
                frame: CGRect(x: 550, y: 31, width: 538, height: 1189),
                axis: .vertical,
                child: .second
            ),
            snapshot(
                id: 3616,
                frame: CGRect(x: 1100, y: 31, width: 1090, height: 1189),
                axis: .vertical,
                child: .second
            ),
            snapshot(
                id: 3772,
                frame: CGRect(x: 0, y: 779, width: 965, height: 481),
                axis: .none,
                child: .none,
                isVisible: false,
                hasAXReference: false
            ),
            snapshot(
                id: 241,
                frame: CGRect(x: 0, y: 31, width: 2189, height: 1189),
                axis: .none,
                child: .none,
                isVisible: false,
                hasAXReference: false
            ),
            snapshot(
                id: 4287,
                frame: CGRect(x: 1100, y: 31, width: 1090, height: 1189),
                axis: .none,
                child: .none,
                isVisible: false,
                hasAXReference: false
            )
        ]
        let yabaiSevenPath = try resolver.branches(for: 2195, in: yabaiSevenRealSpace)
        try requireBranchPath(
            yabaiSevenPath,
            equals: [[2195, 4585], [2195, 3616, 4585]],
            label: "yabai 7.1.25 Space query with stale windows"
        )

        var filteredWindows = exampleWindows
        filteredWindows.append(
            snapshot(
                id: 100,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                space: 2,
                display: 1,
                axis: .none,
                child: .none
            )
        )
        filteredWindows.append(
            snapshot(
                id: 101,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                space: 1,
                display: 2,
                axis: .none,
                child: .none
            )
        )
        filteredWindows.append(
            snapshot(
                id: 102,
                frame: CGRect(x: 0, y: 0, width: 1000, height: 1000),
                space: 1,
                display: 1,
                axis: .none,
                child: .none,
                isFloating: true
            )
        )
        let filteredPath = try resolver.branches(for: 3, in: filteredWindows)
        try requireBranchPath(
            filteredPath,
            equals: [[3, 7], [1, 2, 3, 7], [1, 2, 3, 4, 5, 6, 7]],
            label: "space/display/floating filtering"
        )

        let inconsistent = [
            snapshot(
                id: 30,
                frame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                axis: .horizontal,
                child: .first
            ),
            snapshot(
                id: 31,
                frame: CGRect(x: 500, y: 0, width: 500, height: 1000),
                axis: .horizontal,
                child: .second
            )
        ]
        do {
            _ = try resolver.branches(for: 30, in: inconsistent)
            throw AppError.message("Invalid yabai BSP metadata was accepted.")
        } catch BSPTreeError.hierarchyCouldNotBeResolved {
            // Expected: geometry says vertical, metadata says horizontal.
        }

        let invalidStack = [
            snapshot(
                id: 40,
                frame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                axis: .vertical,
                child: .first,
                stackIndex: 1
            ),
            snapshot(
                id: 41,
                frame: CGRect(x: 0, y: 0, width: 500, height: 1000),
                axis: .vertical,
                child: .first,
                stackIndex: 1
            ),
            snapshot(
                id: 42,
                frame: CGRect(x: 510, y: 0, width: 490, height: 1000),
                axis: .vertical,
                child: .second
            )
        ]
        do {
            _ = try resolver.branches(for: 40, in: invalidStack)
            throw AppError.message("Invalid yabai stack metadata was accepted.")
        } catch BSPTreeError.inconsistentLeafMetadata {
            // Expected: stack indices must describe a unique 1...n ordering.
        }

        var duplicateWindowID = twoWindows
        duplicateWindowID.append(twoWindows[0])
        do {
            _ = try resolver.branches(for: 1, in: duplicateWindowID)
            throw AppError.message("Duplicate yabai window IDs were accepted.")
        } catch BSPTreeError.hierarchyCouldNotBeResolved {
            // Expected: a snapshot must never describe the same window twice.
        }

        do {
            _ = try resolver.branches(
                for: 50,
                in: [snapshot(
                    id: 50,
                    frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                    axis: .none,
                    child: .none
                )]
            )
            throw AppError.message("A root leaf was treated as a parent branch.")
        } catch BSPTreeError.noParentBranch {
            // Expected: a single tiled window has no parent region.
        }
    }

    private static func testBSPCoordinateConversion() throws {
        let main = try convertedRect(
            BSPCoordinateConverter.appKitRect(
                fromYabai: CGRect(x: 100, y: 50, width: 400, height: 300),
                yabaiDisplayFrame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                appKitScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            label: "main display"
        )
        try requireRect(main, equals: CGRect(x: 100, y: 550, width: 400, height: 300), label: "main display")

        let left = try convertedRect(
            BSPCoordinateConverter.appKitRect(
                fromYabai: CGRect(x: -1800, y: 100, width: 500, height: 400),
                yabaiDisplayFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
                appKitScreenFrame: CGRect(x: -1920, y: -180, width: 1920, height: 1080)
            ),
            label: "left display"
        )
        try requireRect(left, equals: CGRect(x: -1800, y: 400, width: 500, height: 400), label: "left display")

        let above = try convertedRect(
            BSPCoordinateConverter.appKitRect(
                fromYabai: CGRect(x: 100, y: -1100, width: 600, height: 300),
                yabaiDisplayFrame: CGRect(x: 0, y: -1200, width: 1920, height: 1200),
                appKitScreenFrame: CGRect(x: 0, y: 900, width: 1920, height: 1200)
            ),
            label: "display above"
        )
        try requireRect(above, equals: CGRect(x: 100, y: 1700, width: 600, height: 300), label: "display above")

        let scaled = try convertedRect(
            BSPCoordinateConverter.appKitRect(
                fromYabai: CGRect(x: 400, y: 200, width: 800, height: 600),
                yabaiDisplayFrame: CGRect(x: 0, y: 0, width: 2880, height: 1800),
                appKitScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            label: "scaled display"
        )
        try requireRect(scaled, equals: CGRect(x: 200, y: 500, width: 400, height: 300), label: "scaled display")

        guard BSPCoordinateConverter.appKitRect(
            fromYabai: CGRect(x: 0, y: 0, width: 100, height: 100),
            yabaiDisplayFrame: .zero,
            appKitScreenFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
        ) == nil else {
            throw AppError.message("Invalid yabai display bounds produced an overlay rectangle.")
        }
    }

    private static func testBSPWarpDirections() throws {
        let frame = CGRect(x: 100, y: 200, width: 400, height: 200)
        let samples: [(CGPoint, BSPWarpDirection)] = [
            (CGPoint(x: 105, y: 300), .west),
            (CGPoint(x: 495, y: 300), .east),
            (CGPoint(x: 300, y: 205), .north),
            (CGPoint(x: 300, y: 395), .south)
        ]
        for (point, expected) in samples {
            let actual = BSPWarpDirection.nearestEdge(to: point, in: frame)
            guard actual == expected else {
                throw AppError.message("Warp direction test failed at \(point): \(actual) != \(expected)")
            }
        }

        try requireRect(
            BSPWarpDirection.west.previewFrame(in: frame),
            equals: CGRect(x: 100, y: 200, width: 200, height: 200),
            label: "west drop preview"
        )
        try requireRect(
            BSPWarpDirection.east.previewFrame(in: frame),
            equals: CGRect(x: 300, y: 200, width: 200, height: 200),
            label: "east drop preview"
        )
        try requireRect(
            BSPWarpDirection.north.previewFrame(in: frame),
            equals: CGRect(x: 100, y: 200, width: 400, height: 100),
            label: "north drop preview"
        )
        try requireRect(
            BSPWarpDirection.south.previewFrame(in: frame),
            equals: CGRect(x: 100, y: 300, width: 400, height: 100),
            label: "south drop preview"
        )
    }

    private static func convertedRect(_ rect: CGRect?, label: String) throws -> CGRect {
        guard let rect else {
            throw AppError.message("BSP coordinate conversion unexpectedly failed for \(label).")
        }
        return rect
    }

    private static func requireBranchPath(
        _ actual: [BSPBranch],
        equals expected: [[Int]],
        label: String
    ) throws {
        let actualIDs = actual.map { $0.windowIDs.sorted() }
        let expectedIDs = expected.map { $0.sorted() }
        guard actualIDs == expectedIDs else {
            throw AppError.message("BSP branch test failed for \(label): \(actualIDs) != \(expectedIDs)")
        }
    }

    private static func requireRect(_ actual: CGRect, equals expected: CGRect, label: String) throws {
        let values = [
            abs(actual.minX - expected.minX),
            abs(actual.minY - expected.minY),
            abs(actual.width - expected.width),
            abs(actual.height - expected.height)
        ]
        guard values.allSatisfy({ $0 < 0.01 }) else {
            throw AppError.message("BSP coordinate test failed for \(label): \(actual) != \(expected)")
        }
    }

    private static func syntheticSnapshots(
        from tree: SyntheticBSPNode,
        frame: CGRect = CGRect(x: 0, y: 0, width: 1200, height: 800),
        gap: CGFloat = 10
    ) -> [BSPWindowSnapshot] {
        var result: [BSPWindowSnapshot] = []
        appendSyntheticSnapshots(
            tree,
            frame: frame,
            parentAxis: .none,
            parentChild: .none,
            gap: gap,
            result: &result
        )
        return result
    }

    private static func appendSyntheticSnapshots(
        _ node: SyntheticBSPNode,
        frame: CGRect,
        parentAxis: BSPSplitAxis,
        parentChild: BSPSplitChild,
        gap: CGFloat,
        result: inout [BSPWindowSnapshot]
    ) {
        switch node {
        case .leaf(let ids):
            for (index, id) in ids.enumerated() {
                result.append(
                    snapshot(
                        id: id,
                        frame: frame,
                        axis: parentAxis,
                        child: parentChild,
                        stackIndex: ids.count > 1 ? index + 1 : 0
                    )
                )
            }
        case .split(let axis, let first, let second):
            let firstFrame: CGRect
            let secondFrame: CGRect
            if axis == .vertical {
                let firstWidth = floor((frame.width - gap) / 2)
                firstFrame = CGRect(x: frame.minX, y: frame.minY, width: firstWidth, height: frame.height)
                secondFrame = CGRect(
                    x: frame.minX + firstWidth + gap,
                    y: frame.minY,
                    width: frame.width - firstWidth - gap,
                    height: frame.height
                )
            } else {
                let firstHeight = floor((frame.height - gap) / 2)
                firstFrame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: firstHeight)
                secondFrame = CGRect(
                    x: frame.minX,
                    y: frame.minY + firstHeight + gap,
                    width: frame.width,
                    height: frame.height - firstHeight - gap
                )
            }
            appendSyntheticSnapshots(
                first,
                frame: firstFrame,
                parentAxis: axis,
                parentChild: .first,
                gap: gap,
                result: &result
            )
            appendSyntheticSnapshots(
                second,
                frame: secondFrame,
                parentAxis: axis,
                parentChild: .second,
                gap: gap,
                result: &result
            )
        }
    }

    private static func snapshot(
        id: Int,
        frame: CGRect,
        space: Int = 1,
        display: Int = 1,
        axis: BSPSplitAxis,
        child: BSPSplitChild,
        stackIndex: Int = 0,
        isFloating: Bool = false,
        isVisible: Bool = true,
        hasAXReference: Bool = true
    ) -> BSPWindowSnapshot {
        BSPWindowSnapshot(
            id: id,
            frame: YabaiFrame(x: frame.minX, y: frame.minY, w: frame.width, h: frame.height),
            space: space,
            display: display,
            splitType: axis,
            splitChild: child,
            stackIndex: stackIndex,
            hasAXReference: hasAXReference,
            isVisible: isVisible,
            isFloating: isFloating,
            isMinimized: false,
            isHidden: false
        )
    }

    private static func testLocalGitSynchronization(in root: URL) throws {
        let remote = root.appendingPathComponent("remote.git")
        let seed = root.appendingPathComponent("seed")
        let client = root.appendingPathComponent("client")
        let verifier = root.appendingPathComponent("verifier")

        try requireGit(["init", "--bare", "--initial-branch=main", remote.path], in: root)
        try requireGit(["init", "--initial-branch=main", seed.path], in: root)
        try requireGit(["config", "user.name", "Yabai Menu Tests"], in: seed)
        try requireGit(["config", "user.email", "yabai-menu-tests@localhost"], in: seed)
        let seedYabaiDirectory = seed.appendingPathComponent("yabai")
        try FileManager.default.createDirectory(at: seedYabaiDirectory, withIntermediateDirectories: true)
        try "#!/usr/bin/env sh\n".write(
            to: seedYabaiDirectory.appendingPathComponent("yabairc"),
            atomically: true,
            encoding: .utf8
        )
        try requireGit(["add", "."], in: seed)
        try requireGit(["commit", "-m", "Initial"], in: seed)
        try requireGit(["remote", "add", "origin", remote.path], in: seed)
        try requireGit(["push", "-u", "origin", "main"], in: seed)
        try requireGit(["clone", remote.path, client.path], in: root)
        try requireGit(["config", "user.name", "Yabai Menu Tests"], in: client)
        try requireGit(["config", "user.email", "yabai-menu-tests@localhost"], in: client)

        let clientYabairc = client.appendingPathComponent("yabai/yabairc")
        let clientStore = YabaircBlacklistStore(fileURL: clientYabairc)
        _ = try clientStore.adding(RunningApplication(name: "Finder", bundleIdentifier: "com.apple.finder"))
        let sync = GitSyncController(repositoryURL: client, managedFileURL: clientYabairc)
        guard try sync.commitManagedFile() else {
            throw AppError.message("Git sync did not detect the managed yabairc change.")
        }
        _ = try sync.sync()

        try requireGit(["clone", remote.path, verifier.path], in: root)
        let verified = try String(contentsOf: verifier.appendingPathComponent("yabai/yabairc"), encoding: .utf8)
        guard verified.contains("com.apple.finder") else {
            throw AppError.message("Git sync did not push the yabairc change.")
        }
    }

    private static func requireGit(_ arguments: [String], in directory: URL) throws {
        let result = ProcessRunner.run(
            URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            currentDirectory: directory
        )
        guard result.succeeded else {
            throw AppError.message("Git self-test failed: \(result.usefulError)")
        }
    }
}

private indirect enum SyntheticBSPNode {
    case leaf([Int])
    case split(BSPSplitAxis, SyntheticBSPNode, SyntheticBSPNode)
}
