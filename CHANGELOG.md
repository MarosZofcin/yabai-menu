# Changelog

All notable changes to Yabai Menu are documented in this file.

## [Unreleased]

### Added

- Option-click BSP branch inspection with a transparent, click-through overlay.
- Repeated Option-clicks on the same tiled window advance from its closest
  parent branch to the complete current BSP tree.
- Conservative reconstruction checks and synthetic self-tests for BSP split
  metadata, stacked leaves, invalid snapshots, and multi-display coordinate
  conversion.

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

[1.0.1]: https://github.com/MarosZofcin/yabai-menu/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/MarosZofcin/yabai-menu/releases/tag/v1.0.0
