# Yabai Menu

Native macOS menu-bar controller for yabai with BSP visualization, drag-and-warp window management, floating-app controls, safe yabairc synchronization, runtime updates, and an automatic Clipboard Cleaner.

## Highlights

- **Automatic Clipboard Cleaner** — when enabled, copied text is cleaned automatically before paste. It removes injected copy-attribution footers and strips known URL tracking parameters such as `utm_*`, `fbclid`, `gclid`, `msclkid`, `ttclid` and related identifiers while preserving functional query parameters. It can be turned on or off directly in the Yabai Menu menu.
- **BSP branch inspection** — hold Control + Shift and hover a tiled window to highlight its parent BSP branch without changing the layout.
- **Visual drag-and-warp** — hold Control + Option and drag a tiled window toward a target edge to move it within the BSP tree.
- **Balance current Space** and undo the last supported warp.
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

Download the latest **Application** release ZIP, extract `Yabai Menu.app`, move it to Applications and launch it manually. Because the app is ad-hoc signed, macOS may require the usual first-launch approval and Accessibility/Input Monitoring permissions for the yabai interaction features.

From Host 1.1.0 onward, the app does not automatically replace its own bundle. Runtime updates are downloaded separately and activated outside the `.app` bundle.

## Runtime updates

The menu contains **Automatically Update Runtime**, **Check for Updates**, and **Restore Previous Runtime**. Runtime updates carry decision logic and policy while the native host remains stable whenever the existing Host API can support the change.

Host upgrades are intentionally manual. A new host is needed only when a feature requires native authority that the current Host API/System Services layer does not expose.

## Development

Read `AGENTS.md` and `docs/ARCHITECTURE.md` before changing or releasing the project. Runtime-first changes should keep native host files unchanged unless the existing Host API genuinely cannot implement the feature safely.

## License

See `LICENSE`.
