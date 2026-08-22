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

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- yabai installed at `/opt/homebrew/bin/yabai` or `/usr/local/bin/yabai`
- Git-backed yabai config at `~/dotfiles/yabai/yabairc`
- an upstream branch configured for `~/dotfiles`

## Install

1. Download `Yabai-Menu.zip` from Releases.
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

The result is written to `dist/Yabai Menu.app` and ad-hoc signed.

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
