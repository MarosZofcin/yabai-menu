# Yabai Menu

Yabai Menu is a small, native macOS menu-bar controller for [yabai](https://github.com/asmvik/yabai). It is written in Swift and AppKit and does not require Hammerspoon, Electron, or another runtime.

> [!IMPORTANT]
> This first release is intentionally opinionated. It expects a Git repository at `~/dotfiles` and a yabai configuration at `~/dotfiles/yabai/yabairc`, normally linked from `~/.config/yabai/yabairc`. See **Current scope** before installing.

## What is dynamic tiling?

Traditional desktop window management is manual: every window opens at an arbitrary position and the user repeatedly drags and resizes it. Static tiling improves this with a fixed set of predefined zones, but those zones do not naturally adapt as windows come and go.

Dynamic tiling treats the desktop as a live layout. Opening, closing, moving, or floating a window changes the available space, and the window manager recalculates the remaining window frames automatically. The result is a desktop that continuously uses the available screen area without requiring manual cleanup.

This is interesting because it:

- keeps every managed window visible and non-overlapping
- makes layouts predictable enough for keyboard-driven navigation
- removes repetitive dragging and resizing
- scales from a laptop screen to multi-display workspaces
- allows selected applications to float while everything else remains tiled
- turns the window layout into scriptable state instead of a collection of manually positioned rectangles

## How yabai implements dynamic tiling

[yabai](https://github.com/asmvik/yabai) extends the built-in macOS window manager instead of replacing it. Its primary dynamic layout is **binary space partitioning (BSP)**. A Space begins as one region; adding a managed window splits an existing region into two child regions. Repeating that process builds a binary tree whose leaves are windows. When a window is inserted, removed, swapped, warped, or resized, yabai updates that tree and recalculates the affected frames.

The official [yabai manual](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc) exposes three per-Space layouts:

- `bsp` — dynamic binary-space-partitioned tiling
- `stack` — multiple windows share one frame and are selected as a stack
- `float` — yabai leaves window placement to macOS and the user

Useful BSP controls include automatic or explicit split direction, insertion position, split ratio, gaps, padding, balancing, swapping, warping, stacking, zooming, and directional focus. See the official [configuration examples](https://github.com/asmvik/yabai/tree/master/examples) and [wiki](https://github.com/asmvik/yabai/wiki) for practical setups.

Yabai Menu does not implement a second tiling engine. It is a native control surface for yabai: it reports yabai's state, shows the layout associated with each display's active Space, manages `manage=off` rules, and sends changes to the running yabai process.

## Platforms and macOS versions

yabai is a **macOS-only** window manager. There are no yabai builds for Windows or Linux; those platforms use different window systems and different tiling window managers. On macOS, the core BSP model is consistent across supported versions, while the available system integrations and required permissions depend on the operating-system release and hardware architecture.

According to the current [official requirements](https://github.com/asmvik/yabai#requirements-and-caveats):

| Platform | Supported macOS versions |
|---|---|
| Intel x86-64 | Big Sur 11+, Monterey 12+, Ventura 13+, Sonoma 14+, Sequoia 15+, Tahoe 26+ |
| Apple Silicon | Monterey 12+, Ventura 13+, Sonoma 14+, Sequoia 15+, Tahoe 26+ |

Across these platforms:

- **Accessibility permission is required** so yabai can inspect and move application windows.
- **Screen Recording permission is required only for window animations.**
- **Partially disabling System Integrity Protection is optional.** Standard tiling works through public accessibility APIs. The optional [scripting addition](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) enables deeper WindowServer/Dock integrations and features that need elevated control.
- **Displays must use separate Spaces.** On macOS 11–12 this is configured in Mission Control preferences; on macOS 13 and later it is in Desktop & Dock → Mission Control.
- On newer macOS versions, some multi-display focus commands also depend on the Desktop & Stage Manager settings documented in yabai's requirements.

Always check the [latest yabai release](https://github.com/asmvik/yabai/releases) and its [changelog](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md) before upgrading macOS, because private macOS behavior can change between releases.

## Why Yabai Menu exists

The yabai community already has useful graphical projects and status surfaces. Examples include [YabaiIndicator](https://github.com/xiamaz/YabaiIndicator), [yabai-bar](https://github.com/kcmyang/yabai-bar), [simple-bar-lite](https://github.com/Jean-Tinland/simple-bar-lite), and [barik](https://github.com/mocki-toki/barik). They visualize Spaces, expose workspace switching, replace or augment the menu bar, or provide a broader desktop dashboard.

Those are valuable tools, but they solve a different primary problem. In our search, we did not find one small native utility that combined the workflow we considered essential:

1. Detect the application the user is working in right now.
2. Add or remove that application from the yabai floating blacklist with one click.
3. Keep the blacklist visible and editable inside the existing `yabairc`, rather than hiding it in a second database.
4. Validate the complete configuration before saving it.
5. Apply the change immediately without restarting the whole window manager.
6. Commit and synchronize the same configuration safely between multiple Macs.
7. Show yabai, display-layout, and synchronization health in one native menu.

That narrow workflow is the reason for Yabai Menu. It is not intended to replace the richer bars, launchers, hotkey tools, or configuration frameworks around yabai. It adds a focused control and synchronization layer for users who already keep their yabai configuration in Git.

### What makes this tool different

| Concern | Yabai Menu approach |
|---|---|
| Runtime | Native Swift/AppKit menu-bar app; no Electron or Hammerspoon runtime |
| Blacklist ownership | One marked block in the existing `yabairc` |
| Current-app workflow | One-click float/unfloat for the foreground application |
| Live behavior | Rebuilds only the managed yabai rules and applies them to open windows |
| Multi-Mac workflow | Pull-before-edit, commit, push, hourly polling, wake sync, and manual sync |
| Safety | Clean-worktree checks, shell syntax validation, atomic writes, fast-forward preference, and conflict abort |
| Visibility | yabai state, per-display active layout, current app, floating apps, GitHub state, and last sync time |

## Features

- yabai running/stopped status
- BSP/float layout status for every display
- current foreground application
- add or remove applications from the floating-app blacklist
- one canonical blacklist block inside `yabairc`; no sidecar database
- start, stop, and reload yabai
- conservative GitHub synchronization
- synchronization at launch, after wake, every hour, before blacklist changes, and on demand
- visible GitHub state and last successful synchronization time
- optional launch at login
- Option-click inspection of the clicked tiled window's BSP ancestor branches

## Detailed behavior

### At application launch

1. Yabai Menu becomes a menu-bar-only app.
2. It locates `~/dotfiles/yabai/yabairc` and reads existing `manage=off` rules.
3. It queries yabai for its service, display, and Space state.
4. It checks the current foreground application.
5. It synchronizes the clean dotfiles branch with its configured upstream.
6. It starts the hourly synchronization timer and listens for system wake events.

### When you choose “Float current app”

1. The app synchronizes first, so the edit starts from the newest GitHub version.
2. It reads the current blacklist from `yabairc`.
3. It creates an anchored regular-expression rule for the foreground application.
4. On the first edit, existing one-line floating rules are migrated into the marked managed block.
5. The entire prospective `yabairc` is checked with `/bin/sh -n`.
6. The valid file is written atomically while preserving executable permissions.
7. Managed rules in the running yabai instance are removed and rebuilt from the file.
8. `yabai -m rule --apply` applies the new rules to windows that are already open.
9. Only `yabai/yabairc` is committed with the message `Update yabai floating apps`.
10. The clean branch is synchronized back to GitHub.

Removing an application follows the same process. Windows that were floating because of the removed managed rule are returned to tiling where possible.

### When another Mac changes the blacklist

At launch, after wake, once per hour, or after **Sync Now**, the receiving Mac fetches the upstream branch. A clean behind branch is fast-forwarded, the updated rules are loaded from `yabairc`, and they are applied to the running yabai instance. If the Mac is asleep or offline, it catches up during the next successful synchronization.

### Inspecting a BSP branch

Hold **Option** and click a tiled window on a BSP Space. Yabai Menu shows a
non-interactive, transparent frame around that window's nearest BSP parent
branch. Continue holding Option and click the same window again to move one
level upward; the final level is the complete BSP tree for that Space.

The inspection overlay neither changes the layout nor accepts mouse events. It
uses yabai's per-window split metadata together with the current frames. If
those values do not describe one unambiguous hierarchy, Yabai Menu hides the
overlay instead of guessing. This interaction requires Yabai Menu itself to be
permitted in **System Settings → Privacy & Security → Accessibility**.

### Synchronization states

| Menu state | Meaning |
|---|---|
| `GitHub: Synced` | Fetch/pull/push completed and the branch matches its upstream |
| `GitHub: Syncing…` | A Git operation is currently running |
| `GitHub: Local changes` | The repository contains uncommitted work; automatic mutation is paused |
| `GitHub: Conflict` | Local and remote commits could not be rebased safely; the rebase was aborted |
| `GitHub: Not synchronized` | Authentication, network, upstream, or another Git error prevented synchronization |

`Last sync` records the date and time of the latest successful complete synchronization. It is not updated after a failed or partial attempt.

## How the blacklist works

Yabai Menu reads existing one-line `manage=off` rules from `yabairc`. On the first edit, it migrates them into a marked block:

```sh
# --- YABAI MENU: FLOATING APPS BEGIN ---
# Managed by Yabai Menu. This is the single source of truth for floating apps.
# ...rules...
# --- YABAI MENU: FLOATING APPS END ---
```

Only this block is managed. Before writing, the complete shell script is validated with `sh -n`; the update is atomic and preserves executable permissions. Changes are also applied dynamically to a running yabai instance, so a full restart is normally unnecessary.

## GitHub synchronization

The app uses the system `/usr/bin/git` and the existing `origin`/upstream configuration in `~/dotfiles`. It never stores GitHub credentials. HTTPS credentials are read by Git through macOS Keychain; SSH repositories use the user's existing SSH setup.

Synchronization pauses instead of modifying the repository when it finds uncommitted changes. Fast-forward updates are preferred. If a rebase conflicts, it is aborted and local commits are preserved.

Because automatic synchronization can pull and push the whole dotfiles branch, read the source and make sure this workflow matches your repository before using the app.

## Best practices

1. **Keep `yabairc` under version control.** The expected canonical file is `~/dotfiles/yabai/yabairc`; link it to yabai's active config location instead of maintaining two copies.
2. **Start with a clean repository.** Before the first launch, run `git -C ~/dotfiles status` and commit or stash unrelated work. Yabai Menu intentionally pauses when it sees uncommitted changes.
3. **Configure one upstream branch on every Mac.** Both machines should track the same branch, normally `origin/main`, and should agree on the dotfiles layout.
4. **Authenticate Git separately on each Mac.** Yabai Menu never copies credentials. Configure macOS Keychain for HTTPS or an SSH key on the iMac and MacBook independently.
5. **Run one manual sync before editing.** Confirm that the menu reports `GitHub: Synced` and shows a current timestamp on both machines.
6. **Enable “Launch Yabai Menu at Login” on every participating Mac.** This starts the menu app and its launch/wake/hourly synchronization. It does not replace yabai's own launchd service.
7. **Treat the marked block as app-owned.** Manual rules and general yabai configuration belong outside the `YABAI MENU: FLOATING APPS` markers. If you edit inside the block manually, preserve both markers and one complete rule per line.
8. **Avoid simultaneous edits on two Macs.** The app synchronizes before each change, which makes conflicts rare, but two truly concurrent edits can still diverge. Resolve that state in Git before continuing.
9. **Use “Edit yabairc” for deliberate manual changes.** Commit those changes yourself before asking Yabai Menu to synchronize again.
10. **Prefer specific app patterns.** Exact app-name rules reduce accidental matches. Remember that some application names are localized by macOS, so verify the visible name on every Mac that uses a different system language.
11. **Do not disable SIP unless you need scripting-addition features.** Ordinary tiling and floating rules use the Accessibility API. Review yabai's official [SIP guidance](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) before enabling advanced features.
12. **Recheck after macOS or yabai upgrades.** Launch yabai manually, verify Accessibility permission, run **Sync Now**, and test one reversible float/unfloat action before relying on the setup.
13. **Keep a recovery path.** Because every app-generated change is committed, `git log -- yabai/yabairc` and `git revert <commit>` provide a clear audit and rollback path.

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- yabai installed at `/opt/homebrew/bin/yabai` or `/usr/local/bin/yabai`
- Accessibility permission for both yabai and Yabai Menu (needed for global Option-click inspection)
- Git-backed yabai config at `~/dotfiles/yabai/yabairc`
- an upstream branch configured for `~/dotfiles`

## Install

1. Download the versioned `Yabai-Menu-<version>.zip` asset from Releases. Do not download GitHub's automatic “Source code” archives.
2. Unzip and move `Yabai Menu.app` to `/Applications`.
3. Open the app. It appears only in the menu bar.
4. Enable **Launch Yabai Menu at Login** if you want background synchronization after login and wake.

The downloadable app is ad-hoc signed for local use. A paid Apple Developer certificate is not required. If macOS blocks the first launch, Control-click the app and choose **Open**.

## Build from source

Only Apple's Command Line Tools are required:

```sh
git clone https://github.com/MarosZofcin/yabai-menu.git
cd yabai-menu
./build.sh
```

The build removes Finder/resource-fork metadata before signing, creates both
`dist/Yabai Menu.app` and a versioned ZIP, and then extracts and validates the
ZIP as a second-machine distribution test. The archive deliberately excludes
extended attributes, resource forks, quarantine data, and ACLs.

## Launch troubleshooting

The app executable is `YabaiMenu` (without a space). If Finder shows a crossed-circle icon or macOS reports a launch failure, first verify the downloaded bundle:

```sh
codesign --verify --deep --strict --verbose=4 "/Applications/Yabai Menu.app"
ls -l "/Applications/Yabai Menu.app/Contents/MacOS/YabaiMenu"
"/Applications/Yabai Menu.app/Contents/MacOS/YabaiMenu"
```

If `ls -l` does not begin with an executable mode such as `-rwxr-xr-x`, the transfer also stripped the executable permission. If verification reports `com.apple.FinderInfo`, the bundle was modified by filesystem metadata after signing. A current release archive should have neither problem. Re-download the versioned release asset rather than repackaging the app with Finder. As a local recovery for an already affected copy, restore the permission before signing again:

```sh
chmod 755 "/Applications/Yabai Menu.app/Contents/MacOS/YabaiMenu"
xattr -cr "/Applications/Yabai Menu.app"
codesign --force --deep --sign - "/Applications/Yabai Menu.app"
codesign --verify --deep --strict --verbose=4 "/Applications/Yabai Menu.app"
open "/Applications/Yabai Menu.app"
```

Apple documents why Finder information and resource forks are forbidden in a signed app bundle in [Technical Q&A QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html).

## Current scope

The app began as a personal utility and deliberately follows one dotfiles layout. Good next contributions would be:

- choose or auto-detect the yabairc path
- opt-in/configurable Git synchronization
- universal Apple Silicon and Intel builds
- notarized releases
- configurable synchronization interval

## Official yabai resources

- [yabai repository and overview](https://github.com/asmvik/yabai)
- [yabai manual / command reference](https://github.com/asmvik/yabai/blob/master/doc/yabai.asciidoc)
- [yabai wiki](https://github.com/asmvik/yabai/wiki)
- [installation and configuration examples](https://github.com/asmvik/yabai/tree/master/examples)
- [latest releases](https://github.com/asmvik/yabai/releases)
- [changelog](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md)
- [requirements and caveats](https://github.com/asmvik/yabai#requirements-and-caveats)
- [System Integrity Protection and scripting addition](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection)
- [yabai issue tracker](https://github.com/asmvik/yabai/issues)
- [skhd hotkey daemon](https://github.com/asmvik/skhd)

## License

[MIT](LICENSE)
