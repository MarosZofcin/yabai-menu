# Stable host / replaceable runtime — Host API 2

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

Host 1.2.0 deliberately broadens the frozen-host strategy with a reusable
**System Services** category. Instead of adding one-off native implementations,
the host emits bounded JSON events and accepts only a small allowlist of typed
operations. Runtime remains pure JavaScript and never receives native objects.
This lets future runtime releases implement new policies over already-exposed
system events without rebuilding the permission-bearing host.

Host 1.2.1 extends that same category with a generic declarative preference
surface. Runtime can declare a bounded list of boolean `runtime.*` settings; the
host renders them as checked menu items and persists their values. This is not a
generic menu/action bridge and does not add new native authority.

## Actual boundary

| Runtime-owned | Host-owned |
| --- | --- |
| BSP leaf grouping, candidate search, ambiguity checks and ancestor selection | Querying windows, validating returned IDs/geometry, AppKit/AX/event tap access |
| Git integration plan and success messages | File scope/syntax validation, conflict recovery, non-force Git commands |
| Selected menu action order/titles/sections and timer values | Fixed selector allowlist, permission UI, recovery menu, timer limits |
| Clipboard-cleaning policy and future decisions over System Services events | Clipboard observation and guarded replacement, lifecycle/workspace/display event capture |
| Boolean preference declarations and decisions using namespaced runtime state | Validation/rendering of preference toggles and UserDefaults storage |
| Future pure decision functions via versioned JSON inputs/outputs | Drag state machine, overlay rendering, stable rule IDs and safe blacklist serialization |

The goal is a small trusted boundary, not the smallest line count at the expense
of safety. General Swift changes still cannot be delivered as runtime JSON.
New native authority requires an explicit host release; new policy over existing
System Services normally does not.

User layout rules, margins and floating entries remain in dotfiles. Runtime
updates must never reset user-specific settings. Timer defaults belong to the
runtime; the update-enabled toggle is a local UserDefaults preference.

## System Services contract

`SystemServiceController` is the only generic runtime-facing native capability
layer. It is intentionally event/operation/preference based rather than a generic
bridge. Runtime calls still execute in the existing short-lived JavaScriptCore
worker.

Current event kinds:

- `clipboard.text.changed` — at most 1 MB of UTF-8 text.
- `host.started` — host/build/macOS metadata.
- `workspace.application.activated` — localized app name and bundle identifier.
- `workspace.didWake` and `workspace.willSleep`.
- `display.configuration.changed`.

Current allowed operation kinds:

- `clipboard.replaceText` — accepted only as a response to the exact clipboard
  change that produced the event. The host verifies `NSPasteboard.changeCount`
  again before writing so a slower runtime cannot overwrite a newer user copy.
- `state.set` / `state.remove` — tiny primitive values under keys prefixed
  `runtime.`; no arbitrary files or defaults domains are exposed.

Current preference surface:

- Runtime `dispatch("preferences", {})` may return at most 16 declarations.
- Each declaration contains only `title`, a validated `runtime.*` `key`, and a
  boolean `defaultValue`.
- Titles are bounded, keys must be unique, and invalid declarations cause the
  entire preference list to fail closed.
- The host renders valid declarations as normal checked menu items and stores
  explicit user choices in the same namespaced System Services state dictionary.
- Preference declarations are re-read when the menu opens, so a future
  runtime-only update can add/remove safe boolean settings without a host restart.

The host accepts at most 16 operations from one event. Unknown operations are
ignored. Text and state values are bounded. A runtime response cannot introduce
new native authority by inventing operation or preference names.

Clipboard observation polls `NSPasteboard.changeCount` every 100 ms on the main
run loop. It ignores non-text clipboard contents. When the host performs a
runtime-requested replacement it immediately records the new change count,
preventing self-triggered loops. It also checks that the clipboard has not
changed while the runtime worker was evaluating the event.

This release intentionally exposes several no-op event families before they are
needed by a feature. They are useful general primitives for later policies, but
exposing an event is not equivalent to authorizing a native action. For example,
a future runtime can react to app activation or wake using existing allowed
state operations, but cannot launch an app or alter displays unless a later host
explicitly adds such an operation.

## Files and versions

- `Resources/Info.plist`: HOST version/build (1.2.1 / 10 for this release).
- `Runtime/manifest.json`: runtime API, independent semantic version, menu/timers
  and mirrored preference metadata used by packaging validation.
- `Runtime/runtime.js`: pure decision code with `dispatch(method,input)`,
  including `systemEvent` and `preferences` policy.
- `Sources/YabaiMenu/SystemServiceController.swift`: native event/operation and
  declarative-preference gate.
- `scripts/package-runtime.js`: validates/packages runtime as one JSON asset.
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
use. Only the host executes hard-coded Git/yabai/file/System Services operations.

This is not an OS sandbox against a JavaScriptCore engine exploit, and the
runtime package must still be trusted. It is NOT an unrestricted shell plugin.
Do not add a generic process runner as an API shortcut. The child time limit
protects availability; it is not a memory quota or a formal security proof.

## Clipboard policy in Runtime 1.2.1

Automatic clipboard cleaning remains the first System Services consumer. Runtime
1.2.1 removes a trailing `Čítajte viac:` attribution injected by Živé/Aktuality
only when it points to `zive.aktuality.sk`, and strips known tracking query
parameters from copied HTTP/HTTPS URLs. Functional query parameters are kept.

The policy is enabled by default but now checks the persistent
`runtime.clipboardCleaner.enabled` boolean state. Host 1.2.1 renders that runtime
declaration as **Automatic Clipboard Cleaner** in the menu. Turning it off causes
the runtime to return no clipboard replacement operation at all.

The cleanup rules still live entirely in `Runtime/runtime.js`, so they can be
refined later by runtime-only updates without another host replacement.

## On-device verification status

On **2026-09-06**, Host/Runtime **1.2.1** was manually installed and tested on a
real Mac by the project owner. The **Automatic Clipboard Cleaner** preference is
visible in the Yabai Menu menu and automatic clipboard cleanup works in normal
copy/paste use. This closes the feature-level real-device verification item that
CI cannot establish.

This verification confirms the menu preference surface and clipboard-cleaning
path in real use. It does **not** by itself prove every residual item in the
release checklist (for example long-term TCC retention, every Maccy race case,
second-Mac behavior, or a later runtime-only update preserving CDHash); those
remain separate checks and must not be inferred from this result.

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
System Services preference declarations are re-read on menu open. Git operations
cannot overlap installation via the menu's operation guard.

Startup falls back to the sealed bootstrap if persisted runtime decoding/health
checks fail. A worker crash/timeout fails that operation without killing the host.
It does not automatically downgrade for every application-level error; use
**Restore Previous Runtime**, which also pauses auto-updates to avoid an immediate
reinstall. Use **Automatically Update Runtime** to resume deliberately.
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
2. CI downloads the existing host ZIP and tests a runtime-only candidate with it.
   Do not substitute a freshly built binary; this catches accidental API dependence.
3. New-host releases build/sign/archive the explicitly bumped host and run all
   native self-tests with the bundled bootstrap runtime.
4. Retest BSP fixtures, stacked leaves, minimum-width overlap, no-parent and
   ambiguous trees; Git autocommit/push with isolated local repositories.
5. Runtime self-test must cover System Services policy such as tracking cleanup,
   publisher-copy-footer removal, preference declaration shape and disabled state.
6. Test corrupt payload, wrong API, invalid version, untrusted URL and timeout.
7. On a real Mac: approve the new host if macOS asks; verify AX/Input Monitoring,
   BSP hover/drag, **Automatic Clipboard Cleaner** menu toggle in both states,
   Maccy coexistence, and that a subsequent runtime-only update leaves the host
   CDHash unchanged. As of 2026-09-06, the Clipboard Cleaner toggle and active
   cleaning path are confirmed working on-device; the remaining subchecks are
   still tracked separately.
8. Test rollback, restart, offline wake, failed download and the second Mac.

Never promise this is the last host update forever. Fixes to the native trust
boundary or genuinely new macOS authority may require another manually approved
host. Prefer extending policy over the existing System Services category first.
