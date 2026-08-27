# Changelog

All notable changes to Yabai Menu are documented in this file.

## [1.0.2] - 2026-08-27

### Added

- Control+Shift hover inspection of a tiled window's closest BSP parent branch
  with a transparent, click-through overlay and no layout mutation.
- Control+Option drag-and-warp for moving one ordinary tiled window to the
  north, east, south, or west edge of another BSP leaf using yabai's native
  `--insert` and `--warp` operations.
- Visual source and drop-zone overlays during a warp, plus exact Undo when the
  source window's original sibling was a single leaf.
- Menu actions for balancing the focused BSP Space, testing the overlay, and
  exporting a complete text diagnostic report to the Desktop.
- Automatic Accessibility and Input Monitoring requests, live permission state,
  and direct System Settings links in the menu.
- Optional structured JSON-lines logging of modifier/mouse input, BSP
  reconstruction, coordinates, all yabai commands, pre/post snapshots, and
  verification. Detailed logging is off by default and can be toggled in the
  menu; current-state exports remain available while it is off.
- Conservative reconstruction checks and synthetic self-tests for BSP split
  metadata, stacked leaves, invalid snapshots, and multi-display coordinate
  conversion, including a real yabai 7.1.25 regression snapshot.

### Fixed

- Reconstruct valid BSP trees when application minimum sizes make sibling
  window frames overlap or overflow their assigned display region.
- Clip overlay geometry to its display when a minimum-sized window extends
  beyond the usable BSP region.

## [1.0.1] - 2026-08-24

### Fixed

- Remove extended attributes from the application bundle before code signing.
- Exclude Finder information, resource forks, quarantine metadata, and ACLs from the downloadable ZIP.
- Preserve and verify the executable permission on `Contents/MacOS/YabaiMenu` so LaunchServices can start the app after transfer to another Mac.
- Verify the extracted distribution archive, not only the original local app bundle.

### Documentation

- Add launch diagnostics for invalid signatures and missing executable permissions.
- Clarify the versioned release asset name and the executable name inside the bundle.

## [1.0.0] - 2026-08-22

### Added

- First public release of the native Swift/AppKit menu-bar controller.
- yabai status, per-display layout status, and foreground-application detection.
- One-click management of floating applications through a canonical block in `yabairc`.
- Conservative Git synchronization at launch, after wake, hourly, before edits, and on demand.
- Local ad-hoc signing for use without a paid Apple Developer certificate.

[1.0.2]: https://github.com/MarosZofcin/yabai-menu/compare/v1.0.1...v1.0.2
[1.0.1]: https://github.com/MarosZofcin/yabai-menu/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/MarosZofcin/yabai-menu/releases/tag/v1.0.0
