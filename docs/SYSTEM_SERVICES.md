# System Services extension guide

Host API 2 adds a reusable native capability category for runtime-driven behavior.
The design rule is: **events carry data into the runtime; allowlisted operations
carry validated intent back to the host**. Runtime never receives native objects
or arbitrary callbacks.

## Existing events

- `host.started`
- `clipboard.text.changed`
- `workspace.application.activated`
- `workspace.didWake`
- `workspace.willSleep`
- `display.configuration.changed`

## Existing operations

- `clipboard.replaceText`
- `state.set`
- `state.remove`

Clipboard replacement is valid only for the clipboard event that produced it.
The host rechecks `NSPasteboard.changeCount` before writing so a delayed runtime
response cannot overwrite a newer user copy. Runtime state is restricted to small
primitive values under `runtime.*` keys in the app's own UserDefaults domain.

## How future agents should extend functionality

Before proposing a new host release, first ask whether the feature can be expressed
as a pure decision over an existing event and existing operation. If yes, change
only `Runtime/runtime.js` / `Runtime/manifest.json` and ship a runtime release.

If the feature needs more input but no new native authority, consider adding a
new bounded event payload in a host release so multiple future policies can reuse
it. If the feature needs a new native action, add one narrowly typed operation
with host-side validation rather than exposing a generic AppKit, Objective-C,
filesystem, shell, process, network or URL execution bridge.

Unknown operations must remain ignored/fail-closed. Keep payload and operation
counts bounded. Do not let runtime choose native selectors, executable paths,
filesystem paths, arbitrary defaults domains or command arguments.

The purpose of this layer is to make future full-app upgrades less frequent while
preserving a small trusted native boundary; it is not a plugin escape hatch.
