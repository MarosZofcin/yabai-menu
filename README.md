# Yabai Menu

Yabai Menu is a small, native macOS menu-bar controller for [yabai](https://github.com/asmvik/yabai). It is written in Swift and AppKit and does not require Hammerspoon, Electron, or another runtime.

Version 1.0.2 also makes yabai's normally invisible BSP structure understandable
on screen: it can show which tiled windows belong together, move a tiled window
to a new position with the mouse, and rebalance the result without requiring the
user to learn yabai commands.

**[Download the stable host bootstrap (1.1.0)](https://github.com/MarosZofcin/yabai-menu/releases/tag/v1.1.0)**

> [!IMPORTANT]
> This first release is intentionally opinionated. It expects a Git repository at `~/dotfiles` and a yabai configuration at `~/dotfiles/yabai/yabairc`, normally linked from `~/.config/yabai/yabairc`. See **Current scope** before installing.

## New to tiling? Start here

On a normal Mac, windows behave like sheets of paper on a desk. They can overlap,
leave unused gaps, and stay wherever you dragged them. A tiling window manager
does the arranging for you. When two windows are open, they may each receive half
of the screen. Open a third and one of those halves is divided again. Close a
window and the others automatically fill the space it left behind.

**yabai is the program that performs this automatic arrangement.** Yabai Menu
does not replace yabai. It gives yabai a small menu-bar interface and makes part
of its normally invisible layout visible and controllable with the mouse.

A beginner can think of the main actions like this:

| If you want to… | Use… | What happens |
|---|---|---|
| understand why some windows resize together | **Control+Shift+hover** | a cyan frame shows the smallest group containing the window |
| place one tiled window beside another | **Control+Option+drag** | a green preview shows the new position before yabai moves it |
| make uneven tiles similar in size again | **Balance Current Space** | yabai resets the split proportions on the current desktop |
| reverse the last supported visual move | **Undo Last Warp** | the moved window returns to its recorded previous neighbour |
| let one application behave like a normal movable macOS window | **Float current app** | the application is excluded from automatic tiling |

For example, suppose Mail occupies the left half of the screen while Safari and
Notes share the right half. The three windows are not merely rectangles: they
form a hidden family tree. Safari and Notes are a smaller pair inside the larger
pair made from Mail and the entire right side. Showing that relationship is
useful because it explains which windows will change size together.

The new visual tools are interesting because they do not invent a second layout
system. Yabai Menu reconstructs yabai's hidden BSP relationships, draws
click-through previews over the real windows, and still asks yabai to perform
every actual move. If the relationship cannot be determined safely, the app
refuses the operation instead of guessing.

## What is dynamic tiling?

Traditional desktop window management is manual: every window opens at an arbitrary position and the user repeatedly drags and resizes it. Static tiling improves this with a fixed set of predefined zones, but those zones do not naturally adapt as windows come and go.

Dynamic tiling treats the desktop as a live layout. Opening, closing, moving, or floating a window changes the available space, and the window manager recalculates the remaining window frames automatically. The result is a desktop that continuously uses the available screen area without requiring manual cleanup.

This is interesting because it:

- automatically uses the available area for managed windows; application
  minimum sizes can still force overlap in very crowded layouts
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
- automatic shell validation, commit, and push when `yabai/yabairc` is the only locally changed file
- runtime-only updates from verified GitHub Release assets at launch, after wake, and every six hours; native app replacement is manual
- **Reload yabai** saves and synchronizes a valid manual `yabairc` edit before restarting the service
- visible GitHub state and last successful synchronization time
- optional launch at login
- Control+Shift hover inspection of the nearest BSP parent branch
- Control+Option drag-and-warp with visual directional drop zones
- balance current BSP Space and exact Undo where the original sibling is one leaf
- optional detailed diagnostics containing input, tree, coordinate, command, and pre/post state data

## Visual BSP controls, explained from scratch

### What is a BSP branch?

With ordinary macOS window management, every window is an independent rectangle
that can be placed anywhere. Yabai's BSP mode works differently. Imagine the
desktop as a sheet of paper. Yabai first cuts it into two regions. Either region
can then be cut in two again, and the process continues as more windows appear.

Every cut creates a **branch**. A branch can contain two windows, or two larger
groups of windows. This hidden structure matters because yabai does not merely
remember where a window happens to be drawn; it remembers where that window
belongs in the series of splits. When one window is added, removed, or moved,
yabai recalculates the affected branch automatically.

This is powerful, but the tree is normally invisible. Two windows may look as
if they are simply next to each other while belonging to different branches.
That makes it difficult to predict which windows will resize together or where
a newly opened window should be moved. Yabai Menu 1.0.2 adds a visual layer over
that hidden structure.

| Tool | What you do | What appears | Does it change the layout? |
|---|---|---|---|
| Inspect branch | Hold **Control+Shift** and move the pointer over a tiled window | A cyan outline around its nearest parent branch | No |
| Drag-and-warp | Hold **Control+Option** and drag one tiled window onto another | Blue source outline and green destination half | Yes, through yabai |
| Balance | Choose **Balance Current Space** from the menu | Yabai redistributes space more evenly | It changes split ratios, not the tree order |
| Undo | Choose **Undo Last Warp** after a supported move | The moved window returns to its recorded sibling | Yes |

### 1. See which windows belong together

1. Hold **Control+Shift**.
2. Do not click. Simply move the mouse pointer over a tiled window.
3. A cyan frame appears around the smallest BSP branch containing that window.
4. Move the pointer to another tiled window to inspect its branch.
5. Release either key and the frame disappears.

The cyan overlay is only an explanation of the current layout. It is
transparent, always above normal windows, does not accept clicks, does not move
anything, and does not change keyboard focus. This is useful when you want to
understand why a set of windows resizes together before making a change.

### 2. Move a tiled window without learning `warp` commands

Yabai already provides a powerful `warp` command, but normally the user must
decide whether to warp north, east, south, or west and specify the target in a
command. Yabai Menu turns that operation into visual drag and drop:

1. Hold **Control+Option** before pressing the mouse button.
2. Press and hold a tiled window. A blue frame marks it as the source.
3. Drag the pointer over a *different* tiled window.
4. Move toward the upper, right, lower, or left side of that target. A green
   half-window preview shows exactly where the source will be inserted.
5. Release the mouse button while the desired green destination is visible.

The physical macOS window drag is suppressed. Instead, Yabai Menu sends native
`--insert` and `--warp` operations to yabai. Yabai removes the source from its
old branch, inserts it beside the chosen target, and recalculates the surrounding
layout. The window therefore remains tiled; it is not temporarily converted to
a floating window.

For example, if a newly opened window appears in an inconvenient part of the
layout, hold **Control+Option**, drag it over the window it should sit beside,
and release over the required green edge. The user chooses the destination
visually while Yabai Menu derives the corresponding direction and command.

### 3. Clean up the result with Balance and Undo

**Balance Current Space** asks yabai to redistribute the available area through
the current BSP tree. It is useful after manual resizing or several moves. It
does not change which windows are siblings; it only makes the split ratios more
even.

**Undo Last Warp** reverses the most recent drag-and-warp when the original
single-window sibling can be addressed exactly by yabai. The menu disables Undo
when the old destination was an entire multi-window branch, because guessing an
approximate rollback could create a different tree.

### Why the implementation is interesting

Yabai does not return a ready-made tree diagram. Yabai Menu reconstructs the
relevant hierarchy from yabai's current window state and `split-type` /
`split-child` relationships. It also handles real layouts in which application
minimum sizes make small tiled windows overlap or extend beyond their assigned
region. If the available information could describe more than one equally
plausible tree, the app deliberately shows nothing instead of highlighting or
moving the wrong branch.

The overlays work across displays and Spaces, stay click-through, and use
yabai's own operations for every layout mutation. Yabai remains the only tiling
engine and the source of truth.

## macOS Privacy & Security permissions, step by step

The visual controls need two macOS permissions: **Accessibility** and **Input
Monitoring**. These names can sound alarming, so this section explains exactly
why they are needed, how to enable them, and what Yabai Menu does with them.

Install the app in `/Applications` before granting permissions. This helps macOS
remember the copy you will actually use instead of a temporary copy left in
Downloads. Open `Yabai Menu.app`; its square-grid icon appears in the menu bar,
not in the Dock.

### 1. Allow Accessibility

Accessibility permission lets an app inspect and control the macOS user
interface. Yabai Menu needs it to identify the window under the pointer and to
prevent the ordinary free-moving window drag while a tiled drag-and-warp is in
progress. yabai needs its own Accessibility permission to resize and move the
windows after Yabai Menu sends it a command.

1. Click the **Yabai Menu** icon in the menu bar.
2. If the menu says `Accessibility: Required`, choose **Open Accessibility
   Settings**.
3. Alternatively, open **Apple menu → System Settings → Privacy & Security →
   Accessibility**. You may need to scroll down in the sidebar.
4. If **Yabai Menu** is already listed, turn its switch on.
5. If it is not listed, click the **+** button, authenticate with Touch ID or an
   administrator password, choose `/Applications/Yabai Menu.app`, and click
   **Open**. Then turn its switch on.
6. Make sure **yabai** is also allowed in this list. If it is missing, start the
   yabai service once and follow yabai's permission prompt.

Apple treats Accessibility as a powerful permission. Grant it only after you
have decided that you trust the application and its source. You can revoke it at
any time by returning to the same settings page and turning the switch off.

### 2. Allow Input Monitoring

Input Monitoring allows an app to notice mouse, trackpad, or keyboard activity
while another application is active. Yabai Menu needs it because
Control+Shift+hover and Control+Option+drag must work while the pointer is over
Safari, Terminal, Finder, or any other tiled app rather than over Yabai Menu.

1. Click the **Yabai Menu** icon in the menu bar.
2. If the menu says `Input Monitoring: Required`, choose **Open Input Monitoring
   Settings**.
3. Alternatively, open **Apple menu → System Settings → Privacy & Security →
   Input Monitoring**.
4. Turn on **Yabai Menu**. If it is absent, click **+**, select
   `/Applications/Yabai Menu.app`, click **Open**, and enable it.
5. If macOS asks you to quit and reopen the app, accept. Otherwise choose **Quit
   Yabai Menu** from its menu and open it again yourself.

The current Yabai Menu code listens only for mouse movement, the left mouse
button, dragging, and changes to modifier keys such as Control, Shift, and
Option. It does not subscribe to ordinary character key presses and does not
record what you type.

### 3. Confirm that both permissions are working

1. Open the Yabai Menu menu again.
2. Confirm that it shows `Accessibility: Allowed`, `Input Monitoring: Allowed`,
   and `BSP tools: Ready`.
3. Choose **Test BSP Highlight in 3 Seconds**.
4. Move the pointer over an ordinary tiled window and wait. A cyan frame should
   briefly appear around its nearest BSP group.

Yabai Menu checks the permission state repeatedly and starts its mouse listener
automatically once both permissions are active. Restarting the app is still the
most reliable way to make macOS apply a newly granted permission. yabai's own
documentation also requires restarting yabai after its Accessibility permission
is granted.

### If the switch is on but the feature still does not work

- Quit Yabai Menu, turn its permission off and on again, then reopen it.
- If the app was moved or replaced after permission was granted, remove the old
  Yabai Menu entry with the **−** button and add the copy from `/Applications`
  again. A newly built ad-hoc-signed version can sometimes need fresh approval.
- Restart yabai after enabling its Accessibility permission.
- Confirm that the current Space uses the `bsp` layout. The visual tree tools do
  not apply to floating Spaces, floating windows, or ambiguous stacked windows.
- Use **Test BSP Highlight in 3 Seconds** before trying drag-and-warp. This
  separates a permission/listener problem from a drag-target problem.

### Privacy and diagnostic data

Yabai Menu has no telemetry service and does not upload mouse events, typed
text, window details, or diagnostic logs. Its normal Git synchronization pushes
only the configured dotfiles changes to the Git remote that the user already
set up. Whether that remote repository is private or public is controlled on
the Git hosting account, not by Yabai Menu.

**Detailed Diagnostic Logging** is off by default. When enabled, it can record
application/window metadata, pointer coordinates, modifier and drag decisions,
the reconstructed BSP tree, yabai commands, and before/after state. The rotating
log stays locally at `~/Library/Logs/Yabai Menu/interaction.jsonl`. **Export
Diagnostics to Desktop** creates a local text file for the user to inspect and
share manually; nothing is sent automatically. Turn detailed logging off again
after reproducing a problem if that information is sensitive.

Apple's own explanations of these permissions are available in
[Accessibility access](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac)
and [Input Monitoring](https://support.apple.com/guide/mac-help/control-access-to-input-monitoring-on-mac-mchl4cedafb6/mac).

## Detailed behavior

### At application launch

1. Yabai Menu becomes a menu-bar-only app.
2. It locates `~/dotfiles/yabai/yabairc` and reads existing `manage=off` rules.
3. It queries yabai for its service, display, and Space state.
4. It checks the current foreground application.
5. It synchronizes the clean dotfiles branch with its configured upstream.
6. It checks GitHub Releases for a newer Yabai Menu build.
7. It starts the hourly configuration-sync timer, the six-hour update timer, and listens for system wake events.

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

At launch, after wake, once per hour, or after **Save & Sync yabairc**, Yabai Menu first checks the working tree. If `yabai/yabairc` is the only changed file, the complete script is validated with `/bin/sh -n`, committed as **Update yabai configuration**, and synchronized automatically. Changes in any other file still pause synchronization so unrelated work is never committed implicitly.

The receiving Mac then fetches the upstream branch. A clean behind branch is fast-forwarded, the updated rules are loaded from `yabairc`, and they are applied to the running yabai instance. **Reload yabai** uses the same safe save-and-sync path before restarting yabai. If the Mac is asleep or offline, it catches up during the next successful synchronization.

### Inspecting and editing a BSP layout

Hold **Control+Shift** and move the pointer over an ordinary tiled window on a
BSP Space. Yabai Menu passively shows a cyan, non-interactive overlay around
that window's nearest BSP parent branch. No click is needed and the inspector
never changes the layout.

Hold **Control+Option**, press a tiled window, drag over a different tiled
window, and release over its upper, right, lower, or left edge. A blue outline
marks the source and a green half-window preview marks the selected drop zone.
Yabai Menu suppresses the physical window drag and asks yabai to insert and
warp the source at the selected edge, so it stays tiled. Version 1.0.2 moves one
ordinary BSP leaf at a time; stacked windows are rejected rather than handled
ambiguously.

The menu also provides **Balance Current Space**, **Undo Last Warp**, and a
three-second highlight test. Undo is enabled only when it can exactly target
the source's recorded original single-window sibling. A former sibling that is
itself a multi-window branch cannot be addressed exactly by yabai's
window-targeted `warp`, so the app reports that exact Undo is unavailable.

The overlays never accept mouse events or focus. They use yabai's split-child
metadata and current frames and fail closed if those values do not describe one
unambiguous hierarchy. Reconstruction also accounts for valid sibling overlap
caused by applications whose minimum window size is larger than yabai's assigned
region; overlay frames are clipped to the owning display.

On first launch, Yabai Menu requests both **Accessibility** and **Input
Monitoring** for the global mouse listener. Their current state and direct links
to both System Settings panes remain visible in the menu. The app checks the
permissions again in the background and starts the listener automatically once
both are granted.

If an interaction does not behave as expected, enable **Detailed Diagnostic
Logging**, reproduce the problem, and choose **Export Diagnostics to Desktop**.
Detailed logging is off by default because it records window metadata and every
relevant input/query decision. The exported text report always includes the
current app/macOS/yabai, permission, display, Space, mouse-configuration, and
listener state; when logging was enabled it also includes pointer and overlay
coordinates, modifier and drag decisions, reconstructed branch paths, every
yabai command with output and timing, and pre/post mutation state. The
underlying JSON-lines log is kept at
`~/Library/Logs/Yabai Menu/interaction.jsonl`; it rotates at 16 MB and the
export includes both the current and previous segment.

### Synchronization states

| Menu state | Meaning |
|---|---|
| `GitHub: Synced` | Fetch/pull/push completed and the branch matches its upstream |
| `GitHub: Syncing…` | A Git operation is currently running |
| `GitHub: Local changes` | Files other than `yabai/yabairc` contain uncommitted work, or the edited `yabairc` failed validation; automatic mutation is paused |
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

## Stable host and runtime-only updates (1.1.0+)

**Install [host 1.1.0](https://github.com/MarosZofcin/yabai-menu/releases/tag/v1.1.0)
manually once on each Mac**, replacing the old app while it is quit. Grant
Accessibility and Input Monitoring to this host if macOS requires it.

The host never replaces, edits or re-signs its own app bundle. Automatic updates
now install only a JSON/JavaScript runtime under
`~/Library/Application Support/Yabai Menu/Runtime/`. The runtime currently owns
BSP reconstruction, Git integration planning/messages, selected menu composition
and timer settings. Native I/O, privacy controls, event/drag orchestration, safe
blacklist serialization and drawing remain in the host.

Runtime updates are checked after launch/wake and every six hours. They are
verified against the official repository's release URL, asset size, SHA-256
digest and Host API, then run the regression tests before activation. The app
stays open and the permission-bearing binary stays unchanged. This is the
design for avoiding update-induced consent resets; real AX/Input Monitoring
retention on both Macs still requires an on-device check. OS/MDM changes can
still revoke consent.

The menu shows **host and runtime versions separately**. Use **Automatically
Update Runtime** to pause/resume checks, **Restore Previous Runtime** to recover
(and pause updates), or **Host Releases (Manual Installation)** for native upgrades.
Ordinary runtime errors leave the host running. An invalid persisted package
falls back to the sealed bootstrap; network/update failures retain the current
runtime. Host updates may still require new macOS approvals.

**For contributors and AI agents:** read [AGENTS.md](AGENTS.md) and
[the architecture/release contract](docs/ARCHITECTURE.md). A runtime release must
not rebuild the host; CI downloads and tests against the exact released binary.
Increment `Runtime/manifest.json` for runtime releases, not Info.plist. A new host
version requires a justified, explicitly approved manual upgrade.

The trust root is HTTPS plus this GitHub repository's publishing authority.
The checksum is not an independent publisher signature. Runtime JS is evaluated
in bounded workers without exposed filesystem, network or process-launching APIs;
it is not an unrestricted shell-plugin system.

## GitHub synchronization

The app uses the system `/usr/bin/git` and the existing `origin`/upstream configuration in `~/dotfiles`. It never stores GitHub credentials. HTTPS credentials are read by Git through macOS Keychain; SSH repositories use the user's existing SSH setup.

Synchronization auto-commits a valid change to yabai/yabairc only; unrelated uncommitted changes pause synchronization. Fast-forward updates are preferred. If a rebase conflicts, it is aborted and local commits are preserved.

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
9. **Use “Edit yabairc” for deliberate manual changes.** Save the file and choose **Reload yabai** or **Save & Sync yabairc**. If it passes shell validation and no other dotfiles are modified, Yabai Menu commits and synchronizes it automatically.
10. **Prefer specific app patterns.** Exact app-name rules reduce accidental matches. Remember that some application names are localized by macOS, so verify the visible name on every Mac that uses a different system language.
11. **Do not disable SIP unless you need scripting-addition features.** Ordinary tiling and floating rules use the Accessibility API. Review yabai's official [SIP guidance](https://github.com/asmvik/yabai/wiki/Disabling-System-Integrity-Protection) before enabling advanced features.
12. **Recheck after macOS or yabai upgrades.** Launch yabai manually, verify Accessibility permission, run **Save & Sync yabairc**, and test one reversible float/unfloat action before relying on the setup.
13. **Keep a recovery path.** Because every app-generated change is committed, `git log -- yabai/yabairc` and `git revert <commit>` provide a clear audit and rollback path.

## Requirements

- Apple Silicon Mac
- macOS 13 or later
- yabai installed at `/opt/homebrew/bin/yabai` or `/usr/local/bin/yabai`
- Accessibility permission for yabai and Yabai Menu
- Input Monitoring permission for Yabai Menu's BSP mouse controls
- Git-backed yabai config at `~/dotfiles/yabai/yabairc`
- an upstream branch configured for `~/dotfiles`

## Install

1. Download the versioned `Yabai-Menu-<version>.zip` asset from Releases. Do not download GitHub's automatic “Source code” archives.
2. Unzip and move `Yabai Menu.app` to `/Applications`.
3. Open the app. It appears only in the menu bar.
4. Follow the complete [Privacy & Security permission guide](#macos-privacy--security-permissions-step-by-step). Enable **Yabai Menu** under both Accessibility and Input Monitoring, and make sure yabai has its own Accessibility permission.
5. Enable **Launch Yabai Menu at Login** if you want background synchronization and automatic update checks after login and wake.

Host 1.1.0 must be installed manually once on each Mac. Later runtime releases
update automatically without replacing the app; native host upgrades stay manual.

The downloadable app is ad-hoc signed for local use. A paid Apple Developer certificate is not required. If macOS blocks the first launch, Control-click the app and choose **Open**.

## Build from source

Apple's Command Line Tools and Node.js (22 in CI) are required:

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
