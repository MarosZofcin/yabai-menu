# Stable host / replaceable runtime — Host API 1

## Decision and purpose

The old 1.0.4 updater replaced the complete ad-hoc-signed app. A changed native
binary can lose macOS privacy consent. From host 1.1.0 onward, the updater only
writes application-owned runtime data outside `.app`. No Developer ID account
is required for this design. This is not a Gatekeeper or TCC bypass.

Installing a NEW HOST still requires the usual manual macOS approvals. An
unchanged host avoids the code-identity change caused by recompilation, but
OS upgrades, MDM policy, revoked consent and system bugs can still affect access.
An on-device before/after consent check is required before claiming tested TCC
retention. CI does not grant or inspect a person's real privacy permissions.

## Actual boundary (not a claim that the entire application is external)

| Runtime-owned | Host-owned |
| --- | --- |
| BSP leaf grouping, candidate search, ambiguity checks and ancestor selection | Querying windows, validating returned IDs/geometry, AppKit/AX/event tap access |
| Git integration plan and success messages | File scope/syntax validation, conflict recovery, non-force Git commands |
| Selected menu action order/titles/sections and timer values | Fixed selector allowlist, permission UI, recovery menu, timer limits |
| Future pure decision functions via versioned JSON inputs/outputs | Drag state machine, overlay rendering, stable rule IDs and safe blacklist serialization |

This first host retains native I/O and event orchestration intentionally. The
goal is a small trusted boundary, not the smallest line count at the expense of
safety. General Swift changes cannot be delivered as runtime JSON. New native
capabilities require an explicit host release.

User layout rules, margins and floating entries remain in dotfiles. Runtime
updates must never reset user-specific settings. Timer defaults belong to the
runtime; the update-enabled toggle is a local UserDefaults preference.

## Files and versions

- `Resources/Info.plist`: HOST version/build (1.1.0 / 8 initially).
- `Runtime/manifest.json`: runtime API, independent semantic version, menu/timers.
- `Runtime/runtime.js`: pure decision code with `dispatch(method,input)`.
- `scripts/package-runtime.js`: validates/packages these as one JSON asset.
- `.app/Contents/Resources/bootstrap-runtime.json`: offline fallback, sealed once
  when the host is built. Never modified by runtime updates.
- `~/Library/Application Support/Yabai Menu/Runtime/active.json`: active package.
- Same directory, `previous.json`: last known package for manual rollback.

Host releases use `vX.Y.Z` and a ZIP. Runtime releases use `runtime-vX.Y.Z` and
`Yabai-Menu-Runtime-X.Y.Z.json`. Both can contain the bootstrap runtime asset.
Runtime releases must NOT rebuild, rename, replace, modify, or re-sign `.app`.

## Execution and authority

The host starts its SAME executable with `--runtime-evaluate` in a short-lived
worker. That entry point does not initialize AppKit, event taps or permission
prompts. JavaScriptCore receives plain JSON only; no Foundation/Objective-C
objects or native callbacks are exported. Evaluation has a 4-second parent
watchdog, 1 MB protocol limits and BSP search limits. Results are checked before
use. Only the host executes its hard-coded Git/yabai/file operations.

This is not an OS sandbox against a JavaScriptCore engine exploit, and the
runtime package must still be trusted. It is NOT an unrestricted shell plugin.
Do not add a generic process runner as an API shortcut. The child time limit
protects availability; it is not a memory quota or a formal security proof.

## Update and recovery

Checks run after launch/wake (15s defaults), every 6h, and via the menu. They read
up to the newest 100 releases of the fixed GitHub repository over HTTPS, ignore
drafts/prereleases and choose the highest strict runtime version above current.
URLs must match the expected repository/tag/filename. GitHub's asset size and
SHA-256 digest are required; unsupported API versions are rejected.

There is no independent publisher signature yet: GitHub/TLS/repository control
is the trust root. A checksum is integrity, not independent proof of authorship.
Compromise of that publishing authority remains a risk. Do not claim that an
ad-hoc macOS signature authenticates the runtime publisher.

The candidate runs its health check and the existing native self-tests (with
candidate override) against temporary Git fixtures, never live dotfiles/yabai.
Only after success is it written atomically to active.json. Previous is retained.
The app refreshes runtime menu/timers without a restart or an app-bundle write.
Git operations cannot overlap installation via the menu's operation guard.

Startup falls back to the sealed bootstrap if persisted runtime decoding/health
checks fail. A worker crash/timeout fails that operation without killing the
host. It does not automatically downgrade for every application-level error;
use **Restore Previous Runtime**, which also pauses auto-updates to avoid an
immediate reinstall. Use **Automatically Update Runtime** to resume deliberately.
Offline/download/hash/API/test errors keep the current runtime intact.

Host upgrades are manual via **Host Releases (Manual Installation)**. GitHub's
**Latest** label points to the current installable host ZIP, not a runtime-only
release. Runtime discovery scans releases independently of that label.

Host 1.1.0 was initially not-latest to avoid triggering the legacy 1.0.4 whole-app
updater during migration. On 2026-09-05 the owner confirmed the remaining Mac
runs a pre-updater version and will be migrated manually, so this temporary
restriction was removed. Existing 1.0.4 installations elsewhere can still react
to GitHub's Latest label using their legacy updater; this does not change the
runtime-only behavior of host 1.1.0 and later.

## Release/test checklist

1. Runtime change: bump runtime only. CI compares host files to the released tag.
2. CI downloads the existing host ZIP and tests the candidate with it. Do not
   substitute a freshly built binary; this catches accidental API dependence.
3. Retest BSP fixtures, stacked leaves, minimum-width overlap, no-parent and
   ambiguous trees; Git autocommit/push with isolated local repositories.
4. Test corrupt payload, wrong API, invalid version, untrusted URL and timeout.
5. On a real Mac: approve bootstrap once; note AX/Input Monitoring states and
   `codesign -dvvv` CDHash. Install a runtime-only update; verify unchanged CDHash,
   menu changes and working Ctrl+Shift hover / Ctrl+Option drag with no new prompts.
6. Test rollback, restart, offline wake, failed download and the second Mac.

Never promise this is the last host update forever. Fixes to the native trust
boundary or macOS API changes may require a new manually approved host.
