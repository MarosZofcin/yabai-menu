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

For a runtime release:

1. Keep `Sources/`, `Resources/`, `Package.swift`, and `build.sh` unchanged.
2. Increment ONLY `Runtime/manifest.json` version and update CHANGELOG.md.
3. Run `node scripts/package-runtime.js` and the macOS regression workflow.
4. CI must test the new runtime with the EXACT previously released host app,
   not rebuild it. The host signature and binary hash must remain unchanged.
5. Publish `runtime-vX.Y.Z` with `Yabai-Menu-Runtime-X.Y.Z.json`. CI handles it.
   Never overwrite a release asset/tag. Do not mark a runtime release latest.

For an unavoidable host change:

1. Explain why the existing Host API cannot implement the change; obtain user
   approval for the permission-changing manual host upgrade.
2. Increment Info.plist version AND build. Increment Host API only if incompatible.
3. Keep an offline bootstrap runtime bundled; test all current features.
4. Publish a NEW host ZIP, never silently replace existing installations.
5. Tell the user the host update can require new macOS approval. Distinguish
   CI verification from a real two-Mac Accessibility/Input Monitoring test.

Do not migrate user layout/margins into release defaults or overwrite dotfiles.
`~/dotfiles/yabai/yabairc` remains the canonical user configuration. Only that
file may be auto-committed, with syntax validation and unrelated-change checks.

## Honesty and verification

Current runtime extraction is substantial but not total: BSP reconstruction,
Git integration planning/messages, selected menu composition and timers are
external. Native event/drag orchestration, AX rendering, blacklist serialization,
Git I/O and validation remain host code. Do not claim these are already external.
Expand the declarative API deliberately; do not replace it with arbitrary shell.

Read the security/trust and residual-limit sections in the architecture doc.
