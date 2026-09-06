# Yabai Menu

Native macOS menu-bar controller for yabai with BSP visualization, drag-and-warp window management, floating-app controls, safe yabairc synchronization, runtime updates, and an automatic Clipboard Cleaner.

## Highlights

- **Automatic Clipboard Cleaner** — when you copy text, Yabai Menu can clean it automatically before paste. It removes the trailing `Čítajte viac:` attribution injected by Živé/Aktuality and strips known URL tracking parameters such as `utm_*`, `fbclid`, `gclid`, `msclkid`, `ttclid` and related identifiers while preserving functional query parameters.
- **BSP branch inspection** — hold Control + Shift and hover a tiled window to highlight its parent BSP branch without changing the layout.
- **Visual drag-and-warp** — hold Control + Option and drag a tiled window toward a target edge to move it within the BSP tree.
- **Balance current Space** and undo the last supported warp.
- **Floating-app management** directly from the menu, backed by the canonical `yabairc` configuration.
- **Git synchronization** for managed `yabairc` changes with conservative validation and conflict protection.
- **Stable host + replaceable runtime** — normal feature/policy updates are delivered through the runtime without replacing or re-signing the app bundle.

## Clipboard Cleaner

Clipboard cleaning is automatic; there is no extra keyboard shortcut to press.

Current behavior:

- removes Živé/Aktuality copy-injection footers beginning with `Čítajte viac:` when they point back to `zive.aktuality.sk`;
- removes known tracking parameters from copied URLs, including `utm_*`, `fbclid`, `gclid`, `dclid`, `msclkid`, `ttclid`, `twclid`, `igshid`, `mc_cid`, `mc_eid` and related identifiers;
- preserves query parameters that are not recognized as tracking;
- leaves non-text clipboard content untouched;
- checks that the clipboard has not changed again before writing a cleaned result, so a delayed cleanup cannot overwrite a newer copy.

Clipboard cleanup is runtime policy implemented on top of Host API 2. That means future cleanup rules can normally be added through a runtime-only update.

## System Services / Host API 2

Yabai Menu 1.2.0 introduces a reusable **System Services** boundary between native macOS APIs and the replaceable runtime. It is intentionally broader than a one-off clipboard hook so future features have a better chance of shipping without another full app replacement.

The host can emit bounded JSON system events including:

- clipboard text changes;
- host startup;
- active application changes;
- sleep/wake events;
- display-configuration changes.

The runtime can respond only with explicitly allowlisted operations. Today those include guarded clipboard text replacement and small namespaced persistent runtime-state changes.

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
