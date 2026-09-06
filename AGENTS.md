# Required development contract

Read `docs/ARCHITECTURE.md` before changing or releasing this project.

## Runtime-first, frozen host

The user explicitly chose a stable ad-hoc-signed native host so ordinary updates
do not replace the binary that holds Accessibility/Input Monitoring consent.
Do not reintroduce whole-app auto-replacement, re-signing, TCC resets, quarantine
removal, or silent permission changes. Never promise permissions are permanent.

Default changes belong in `Runtime/runtime.js` and `Runtime/manifest.json`.
JavaScript receives JSON and returns JSON; no ObjC/native object, filesystem,
shell, generic git/yabai command runner, or network bridge may be exported.
Do not put untrusted text into executable shell scripts. Host safety checks are
not runtime policy and may not be moved into downloaded code.

Host 1.2.0 adds a reusable **System Services** boundary. Prefer it before adding
new native code. The host may emit bounded, documented JSON events to runtime
and may execute only explicitly allowlisted native operations. Current event
families include clipboard text changes, host lifecycle, workspace application
activation/wake/sleep, and display-configuration changes. Current operation
families include guarded clipboard text replacement and small namespaced runtime
state set/remove operations.

Host 1.2.1 adds a generic **runtime-declared boolean preference** surface inside
that same System Services category. Before adding a new hard-coded menu toggle,
use `dispatch("preferences", {})` if the feature only needs an on/off setting.
Each declaration is limited to a short title, a unique validated `runtime.*` key,
and a boolean default. The host renders it as a checked menu item and persists
explicit user choices in the existing System Services state dictionary. Keep the
matching metadata in `Runtime/manifest.json` synchronized so packaging tests can
validate the declaration. Do not use preferences as a backdoor for selectors,
arbitrary actions, paths, commands or native callbacks.

Extend runtime policy freely within existing events/operations/preferences.
Adding a new native authority, broad bridge, arbitrary AppKit selector,
filesystem/shell/process/network access, or unbounded payload still requires an
explicit host release and review. Unknown operations must fail closed or be
ignored; runtime must never gain native objects directly.

For a runtime release:

1. Keep `Sources/`, `Resources/`, `Package.swift`, and `build.sh` unchanged.
2. Increment ONLY `Runtime/manifest.json` version and update CHANGELOG.md.
3. Run `node scripts/package-runtime.js` and the macOS regression workflow.
4. CI must test the new runtime with the EXACT previously released host app,
   not rebuild it. The host signature and binary hash must remain unchanged.
5. Publish `runtime-vX.Y.Z` with `Yabai-Menu-Runtime-X.Y.Z.json`. CI handles it.
   Never overwrite a release asset/tag. Do not mark a runtime release latest.

For an unavoidable host change:

1. Explain why the existing Host API/System Services capability set cannot
   implement the change; obtain user approval for the permission-changing manual
   host upgrade.
2. Increment Info.plist version AND build. Increment Host API only if incompatible.
3. Keep an offline bootstrap runtime bundled; test all current features.
4. Publish a NEW host ZIP, never silently replace existing installations.
5. Tell the user the host update can require new macOS approval. Distinguish
   CI verification from a real two-Mac Accessibility/Input Monitoring test.

Do not migrate user layout/margins into release defaults or overwrite dotfiles.
`~/dotfiles/yabai/yabairc` remains the canonical user configuration. Only that
file may be auto-committed, with syntax validation and unrelated-change checks.

## Release list presentation

Use short version-first release titles: `X.Y.Z · Aplikácia` for host ZIP releases
and `X.Y.Z · Runtime` for runtime releases. Keep tags and asset filenames stable:
the updater depends on them. GitHub Latest belongs to the current host.
The release workflow maintains these titles. Its one-time draft cleanup is
restricted to owner-approved IDs 374946008 and 374946963; do not generalize
it to deleting other drafts or tags.

## Honesty and verification

Current runtime extraction is substantial but not total: BSP reconstruction,
Git integration planning/messages, selected menu composition, timers, clipboard
cleaning policy, runtime preference declarations and other System Services
decisions are external. Native event capture/execution, validation/rendering of
preference controls, drag orchestration, AX rendering, blacklist serialization,
Git I/O and validation remain host code. Do not claim these are already external.
Expand the declarative API deliberately; do not replace it with arbitrary shell.

Read the security/trust and residual-limit sections in the architecture doc.
