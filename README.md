# Yabai Menu

Yabai Menu is a small, native macOS menu-bar controller for [yabai](https://github.com/asmvik/yabai). It is written in Swift and AppKit and does not require Hammerspoon, Electron, or another runtime.

> [!IMPORTANT]
> This first release is intentionally opinionated. It expects a Git repository at `~/dotfiles` and a yabai configuration at `~/dotfiles/yabai/yabairc`, normally linked from `~/.config/yabai/yabairc`. See **Current scope** before installing.

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

## License

[MIT](LICENSE)
