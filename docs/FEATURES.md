# Features

## Automatic Clipboard Cleaner

Yabai Menu 1.2.0 added automatic clipboard cleaning as a built-in background capability. Host 1.2.1 adds a visible on/off control for it directly in the menu.

When text is copied, Yabai Menu checks it in the background and can replace the clipboard with a cleaned version before paste. No extra shortcut is required.

The menu item **Automatic Clipboard Cleaner** is enabled by default. Click it to turn cleaning off or back on. The setting is persistent and remains independent from runtime-update settings.

Current cleanup rules:

- Remove the trailing `Čítajte viac:` attribution that Živé/Aktuality pages append to copied text.
- Remove known tracking parameters from URLs, including `utm_*`, `fbclid`, `gclid`, `msclkid`, `ttclid` and related identifiers.
- Preserve functional query parameters that are not recognized as tracking.
- Leave non-text clipboard content alone.
- Protect against races so a delayed cleanup result cannot overwrite a newer copy.

### Verified behavior

Host/Runtime **1.2.1** was manually installed and exercised on a real Mac on **2026-09-06**. The **Automatic Clipboard Cleaner** toggle is visible in the menu and the automatic cleanup works in normal copy/paste use. Treat this as on-device confirmation in addition to CI and self-tests.

The clipboard cleaner is implemented as runtime policy on top of Host API 2. Future cleanup rules can therefore usually be delivered as runtime-only updates without replacing the app.

## Runtime-defined menu preferences

Host 1.2.1 adds a generic preference surface to System Services. Runtime code may declare a bounded list of boolean preferences using validated `runtime.*` keys, a short display title and a boolean default value.

The host renders those declarations as standard checked menu items and persists their values in the existing namespaced System Services state store. Runtime code receives the current state with each system event and decides its behavior accordingly.

This mechanism is intentionally generic: future runtime features that only need an on/off setting can add a menu toggle through a runtime-only release rather than requiring another native host build.

Preference declarations do not grant selectors, arbitrary menu actions, AppKit access, shell access, filesystem access or native callbacks. The host still controls the entire native authority boundary.

## System Services / Host API 2

Host 1.2.0 introduces a reusable System Services bridge between macOS and the replaceable runtime.

The host emits bounded JSON events such as:

- clipboard text changed
- host started
- active application changed
- system wake/sleep
- display configuration changed

The runtime may return only explicitly allowlisted operations. Current native operations include guarded clipboard text replacement and small namespaced runtime state updates. Host 1.2.1 additionally renders validated boolean preference declarations as menu toggles.

This is deliberately more general than a clipboard-specific hook: future features that can be expressed using these existing event, operation and preference categories can ship through the runtime update mechanism instead of requiring a new host build.

The bridge does not expose arbitrary AppKit or Objective-C objects, filesystem access, shell commands, generic process execution or unrestricted network access to downloaded runtime code.
