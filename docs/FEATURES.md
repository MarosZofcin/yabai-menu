# Features

## Automatic Clipboard Cleaner

Yabai Menu 1.2.0 adds automatic clipboard cleaning as a built-in background capability.

When text is copied, Yabai Menu checks it in the background and can replace the clipboard with a cleaned version before paste. No extra shortcut is required.

Current cleanup rules:

- Remove the trailing `Čítajte viac:` attribution that Živé/Aktuality pages append to copied text.
- Remove known tracking parameters from URLs, including `utm_*`, `fbclid`, `gclid`, `msclkid`, `ttclid` and related identifiers.
- Preserve functional query parameters that are not recognized as tracking.
- Leave non-text clipboard content alone.
- Protect against races so a delayed cleanup result cannot overwrite a newer copy.

The clipboard cleaner is implemented as runtime policy on top of Host API 2. Future cleanup rules can therefore usually be delivered as runtime-only updates without replacing the app.

## System Services / Host API 2

Host 1.2.0 introduces a reusable System Services bridge between macOS and the replaceable runtime.

The host emits bounded JSON events such as:

- clipboard text changed
- host started
- active application changed
- system wake/sleep
- display configuration changed

The runtime may return only explicitly allowlisted operations. Current native operations include guarded clipboard text replacement and small namespaced runtime state updates.

This is deliberately more general than a clipboard-specific hook: future features that can be expressed using these existing event and operation categories can ship through the runtime update mechanism instead of requiring a new host build.

The bridge does not expose arbitrary AppKit or Objective-C objects, filesystem access, shell commands, generic process execution or unrestricted network access to downloaded runtime code.
