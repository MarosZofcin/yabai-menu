# Yabai Menu

Native macOS menu-bar controller for yabai with geometry-first Smart Move, floating-app controls, safe yabairc synchronization, runtime updates, and an automatic Clipboard Cleaner.

## Highlights

- **Automatic Clipboard Cleaner** — when enabled, copied text is cleaned automatically before paste. It removes injected copy-attribution footers and strips known URL tracking parameters such as `utm_*`, `fbclid`, `gclid`, `msclkid`, `ttclid` and related identifiers while preserving functional query parameters. It can be turned on or off directly in the Yabai Menu menu.
- **Smart Move** — choose Left, Right, Up, or Down for the focused tiled window. The app finds the nearest overlapping visual container from live geometry, so you do not need to reason about BSP branches.
- **Balance current Space** when you explicitly want yabai to rebalance it.
- **Floating-app management** directly from the menu, backed by the canonical `yabairc` configuration.
- **Git synchronization** for managed `yabairc` changes with conservative validation and conflict protection.
- **Stable host + replaceable runtime** — normal feature/policy updates are delivered through the runtime without replacing or re-signing the app bundle.

## Clipboard Cleaner

Clipboard cleaning requires no extra keyboard shortcut. In **Yabai Menu 1.2.1+**, the menu contains a checked **Automatic Clipboard Cleaner** item. Click it to turn automatic cleaning on or off. The default is **On**, and the preference persists across launches and runtime updates.

Current behavior:

- removes supported copy-injection or attribution footers appended to copied text;
- removes known tracking parameters from copied URLs, including `utm_*`, `fbclid`, `gclid`, `dclid`, `msclkid`, `ttclid`, `twclid`, `igshid`, `mc_cid`, `mc_eid` and related identifiers;
- preserves query parameters that are not recognized as tracking;
- leaves non-text clipboard content untouched;
- checks that the clipboard has not changed again before writing a cleaned result, so a delayed cleanup cannot overwrite a newer copy.

**On-device verification:** Host/Runtime 1.2.1 was manually installed and tested on a real Mac on 2026-09-06. The **Automatic Clipboard Cleaner** menu toggle is visible and the automatic clipboard cleaning works in normal use. This confirms the feature beyond CI/build-level verification.

Clipboard cleanup is runtime policy implemented on top of Host API 2. Future cleanup rules can normally be added through a runtime-only update.

## Runtime-defined preferences

Host 1.2.1 extends System Services with a bounded **runtime-defined boolean preference** mechanism. A runtime can declare a small, validated list of namespaced on/off settings; the host renders them as checked menu items and stores their values in the existing System Services state store.

This is deliberately generic rather than Clipboard-Cleaner-specific. Future runtime features that only need an on/off preference can add their own menu toggle without another host rebuild.

Preference declarations are restricted to short titles, boolean defaults and validated `runtime.*` keys. They do not provide arbitrary menu selectors, AppKit access, shell commands or native callbacks.

## System Services / Host API 2

Yabai Menu 1.2.0 introduced a reusable **System Services** boundary between native macOS APIs and the replaceable runtime. It is intentionally broader than a one-off clipboard hook so future features have a better chance of shipping without another full app replacement.

The host can emit bounded JSON system events including:

- clipboard text changes;
- host startup;
- active application changes;
- sleep/wake events;
- display-configuration changes.

The runtime can respond only with explicitly allowlisted operations. Today those include guarded clipboard text replacement, small namespaced persistent runtime-state changes, and validated boolean preference declarations rendered by Host 1.2.1+.

The runtime still does **not** receive arbitrary AppKit/Objective-C objects, filesystem access, shell execution, generic process execution or unrestricted network access. Adding new native authority still requires an explicit host release.

See [`docs/FEATURES.md`](docs/FEATURES.md) for the feature-oriented summary and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) for the host/runtime trust boundary and release model.

## Installation

Download the latest **Application** release ZIP, extract `Yabai Menu.app`, move it to Applications and launch it manually. Because the app is ad-hoc signed, macOS may require the usual first-launch approval and Accessibility permission for yabai interaction. Smart Move does not install a global event listener and does not require Input Monitoring.

From Host 1.1.0 onward, the app does not automatically replace its own bundle. Runtime updates are downloaded separately and activated outside the `.app` bundle.

## Runtime updates

**Upgrade to 1.3.0 for Smart Move and reliable floating rules.** Install the new Application ZIP
manually on each Mac that edits the shared dotfiles. Host 1.2.1 builds these rules
natively, so a runtime-only update cannot repair it. macOS may ask you to approve
the replacement app and its Accessibility access again.

Host 1.2.2 recognizes both Unicode spellings of accented application names (for
example `é` and `e` + combining accent), including after removing and re-adding an
app. Existing generated literal rules are migrated during the next successful
configuration sync. You can trigger it with **Save & Sync yabairc**. Migration
uses the usual syntax checks, auto-commit/push and live rule refresh; unrelated
dotfiles changes still pause synchronization. Layout and padding stay intact.
Custom regular expressions are preserved. No manual `yabairc` edit is needed.
Version 1.2.3 applies the corrected local rules before contacting GitHub and also
reconciles windows that are already open, so a network failure cannot leave an
old in-memory rule active.

Version 1.2.4 also handles applications that remain running after their last
window is closed. On the next activation, the client retries while the reopened
window becomes available and restores floating state automatically. This covers
System Settings and similar macOS/application window lifecycles where yabai may
not reapply a creation-time rule.

Runtime 1.2.2 requires Host API 3. Older hosts cannot install that runtime as a
substitute for the client upgrade. Future runtime-only updates remain supported.

The menu contains **Automatically Update Runtime**, **Check for Updates**, and **Restore Previous Runtime**. Runtime updates carry decision logic and policy while the native host remains stable whenever the existing Host API can support the change.

Host upgrades are intentionally manual. A new host is needed only when a feature requires native authority that the current Host API/System Services layer does not expose.

## Development

Read `AGENTS.md` and `docs/ARCHITECTURE.md` before changing or releasing the project. Runtime-first changes should keep native host files unchanged unless the existing Host API genuinely cannot implement the feature safely.

## License

See `LICENSE`.
