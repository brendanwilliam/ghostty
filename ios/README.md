# Ghostty for iOS

An iOS terminal built on libghostty (Ghostty's terminal emulator and Metal
renderer). Version 1 connects to a Mac (or any SSH server) on the local
network.

<img src="docs/smoke-test.png" width="300" alt="Ghostty rendering on the iOS simulator">

## Build

Requirements: Xcode 27, [Zig 0.16.0](https://ziglang.org/download/), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
# From the repository root: build GhosttyKit with iOS device and simulator slices.
zig build -Demit-xcframework=true -Demit-macos-app=false -Dxcframework-target=ios

cd ios
cp Config/Local.xcconfig.example Config/Local.xcconfig   # set your team ID and bundle ID
xcodegen generate
open GhosttyiOS.xcodeproj
```

Rebuild the XCFramework whenever the Zig core changes. That build also
installs Ghostty's themes into `zig-out/share/ghostty/themes`; a build phase
copies them into the app as `GhosttyResources/themes`.

## Configuration

Each terminal uses a layered Ghostty config. Later layers win:

1. **App defaults:** `Resources/defaults.ghostty`.
2. **The host's own Ghostty config:** fetched over SSH each time you connect,
   before the shell opens, and cached per host.
   - It reads the standard locations (`~/.config/ghostty/config[.ghostty]` and
     `~/Library/Application Support/com.mitchellh.ghostty/config[.ghostty]`)
     and follows `config-file` includes.
   - Custom themes are fetched too.
   - Options that don't apply on the phone are dropped: `command`,
     `initial-command`, `working-directory`, keybinds, and `macos-*`/`gtk-*`
     window options. Settings → Host configs lists what was dropped.
   - You can turn this off per host.
3. **Settings:** the app's own `config.ghostty`, in `Library/Application Support/config/ghostty/` (which the app sets as `XDG_CONFIG_HOME`; the container root isn't writable on a device).
   - Settings has quick controls for common options, an **All options** list
     covering every Ghostty option with its docs, and a raw file editor.
   - Edits are checked with libghostty before they're saved, and they apply to
     open terminals immediately.

Fonts the phone doesn't have (e.g. a Mac-only font) fall back to the built-in
JetBrains Mono.

**Terminal width.** Settings sets how many columns fit across the screen in
portrait (default 80). The font is scaled to fit, and landscape keeps the same
font, so it shows more columns. Pinching a terminal sets a custom width for
that host.

**Option catalog.** `Resources/ConfigCatalog.json` is generated from
Ghostty's docs. To regenerate it:

```sh
zig build -Demit-webdata=true -Demit-xcframework=false -Demit-macos-app=false -Dapp-runtime=none --prefix /tmp/webdata
ghostty +show-config --default > /tmp/defaults.txt
ios/scripts/gen-config-catalog.py /tmp/webdata/share/ghostty/webdata/config.mdx /tmp/defaults.txt > ios/Resources/ConfigCatalog.json
```

## Touch

When the running program tracks the mouse (Claude Code's `/tui fullscreen`,
vim with `mouse=a`, htop, tmux, and others), touches are sent to it as mouse
events. libghostty encodes them in whatever format the program asked for.

| Gesture | Mouse-aware program | Otherwise |
| --- | --- | --- |
| Tap | Click at that cell (the keyboard isn't touched) | Show the keyboard, or clear the selection |
| One-finger drag | Mouse wheel | Scrollback (arrow keys in pagers like `less`) |
| Flick | Keeps scrolling and slows down, like an iOS list; any touch stops it | Same |
| Long-press and drag | Select text (sent with Shift, so the program doesn't see it) | Select text |
| Two-finger tap | Show or hide the keyboard | Show or hide the keyboard |
| Pinch | Zoom | Zoom |

Setting `mouse-reporting = false` in Settings turns this off.

## Key bar

The row above the keyboard has Escape, Control, Option, Command, Shift, and
Tab (shown with their Apple keyboard symbols), arrows, and a few symbols. The
row scrolls; the hide-keyboard key stays pinned at its right edge.

Control, Option, Command, and Shift latch: tap one, then the next key you type
gets it. Command makes Ghostty's shortcuts reachable without a hardware
keyboard (Cmd+T new tab, Cmd+D split, Cmd+V paste, Cmd+K clear). Option+Backspace
deletes a word.

## Dictation

The keyboard's microphone key works. Words are typed into the terminal as you
speak, so they appear in the program's own input (Claude Code's prompt, the
shell line) and wrap there. When dictation revises a word it already typed,
only the changed part is backspaced over and retyped. Input methods that
compose text (Japanese, Chinese) show their marked text underlined at the
cursor and send it once it's chosen.

Dictation never presses Return. A dictated new line is sent as a pasted
newline when the program uses bracketed paste (Claude Code, zsh, fish), so it
adds a line instead of sending the message or running the command. Elsewhere
it's dropped.

## Tabs and splits

Each tab or split is another shell on the same host, over its own SSH
connection. Use the toolbar's tabs menu or Ghostty's usual keybinds from a
hardware keyboard (Cmd+T, Cmd+D / Cmd+Shift+D, Cmd+[ / Cmd+], Cmd+W, and so on;
your Mac config's `keybind` lines aren't imported).

- **Split** stacks panes in portrait (Ghostty's split down) and puts them side
  by side in landscape (split right). The menu also offers the other direction.
- Tap a pane to focus it. That tap isn't sent to the program, even one that
  tracks the mouse. Unfocused panes are dimmed (`unfocused-split-opacity`).
- Drag a divider to resize; double-tap it to equalize. Zoom shows the focused
  split alone.
- Panes in a split use the font a lone pane would (fitted to your column count
  across the full screen) and show however many columns fit.
- `exit` closes just that pane; closing the last tab goes back to the host
  list. A dropped connection leaves the pane open with **Reconnect**.
- Going back to the host list (or anywhere else in the app) leaves a host's tabs
  running; the host shows "2 tabs open", and opening it returns to them. Swipe
  the host and tap **End Sessions** to end them all.

## Sessions that survive the app

iOS suspends the app soon after you leave it and may quit it at any time, and
that drops its SSH connections. When the host has
[zmx](https://github.com/neurosnap/zmx), each tab runs its shell inside a zmx
session on the host instead, so it keeps running (Claude Code included) while
the app is in the background, swiped away, or relaunched.

- Coming back reattaches each pane. zmx redraws the screen as it attaches, and
  the old screen stays up until it has, so there's no blank flash.
- A dropped connection reattaches by itself ("Reconnecting…"), backing off,
  and retries as soon as the network comes back. **Reconnect** appears only
  if that gives up.
- The tabs and splits are saved. After a relaunch the host still shows
  "3 tabs open", and opening it restores the layout with every pane attached
  to its session.
- `exit` ends a pane's session. Closing a tab or split (Cmd+W, the menu) and
  **End Sessions** end their sessions on the host too. If the host can't be
  reached, they're ended the next time it can.
- Sessions are named `gios-<device>-<pane>`. On the Mac, `zmx list` shows them
  and `zmx attach gios-…` opens the same shell there.
- If a host doesn't have zmx, a banner offers to install it with Homebrew
  (`brew install neurosnap/tap/zmx`). Until then tabs are plain shells that
  end with the connection. Turn it off per host with **Keep sessions running**.

The app runs `$SHELL -lc '… zmx attach <name>'` as the PTY's command (an SSH
exec request with a PTY, like `ssh -t`). That needs one addition to Citadel,
so the project pins a fork of Citadel 0.12.0 with `withPTY(_:command:)`.

## Connect to your Mac

1. On the Mac, turn on **System Settings → General → Sharing → Remote Login**.
2. In the app, tap the key icon and copy this device's public key. Then append
   it to `~/.ssh/authorized_keys` on the Mac, e.g. with Universal Clipboard:
   `pbpaste >> ~/.ssh/authorized_keys`.
3. Add the Mac. It shows up under **On this network** through Bonjour, or you
   can enter its hostname (`Your-Mac.local`) and your username.
4. On the first connection, compare the host key fingerprint with the output
   of `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the Mac.

If the server refuses the key, the app asks for a password. A password can
also be saved per host in the Keychain.

## Architecture

```
SwiftUI (UI/)  ──►  TerminalSurfaceView (Ghostty/)  ──►  libghostty surface
                         │      ▲                         (manual IO mode)
                 write/resize   │ output
                         ▼      │
                    TerminalBackend (Session/)
                         │
                    SSHBackend (SSH/, Citadel + SwiftNIO SSH)
```

- **Manual IO mode.** iOS can't spawn processes, so this fork adds a `manual`
  termio backend to libghostty (`src/termio/Manual.zig`). The host feeds
  program output with `ghostty_surface_write_output` and receives terminal
  input through `io_write_cb`/`io_resize_cb` on `ghostty_surface_config_s`.
  `ghostty_surface_session_exited` ends the session.
- **`TerminalBackend`** is the seam for future backends. A local on-device
  runtime (so CLI tools and Claude Code can run on the phone) would implement
  the same protocol. No Ghostty or UI changes are needed for that.
- **Keys.** An Ed25519 device key is generated with CryptoKit and stored in
  the Keychain (`AfterFirstUnlockThisDeviceOnly`, not synced).
- **Host keys.** Host keys are trusted on first use after you confirm the
  fingerprint. A changed key fails the connection; you have to forget the
  old key in host settings before connecting again.

## Tests

```sh
cd ios
xcodebuild test -project GhosttyiOS.xcodeproj -scheme GhosttyiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The SSH integration tests run against a real sshd when these variables are
set. A throwaway `sshd -f <config>` running as your user on a high port works:

```sh
TEST_RUNNER_GHOSTTY_TEST_SSH_PORT=2222 \
TEST_RUNNER_GHOSTTY_TEST_SSH_USER=$USER \
TEST_RUNNER_GHOSTTY_TEST_SSH_KEY_SEED=<hex ed25519 seed> \
xcodebuild test ...
```

With zmx installed on that host, `TEST_RUNNER_GHOSTTY_TEST_ZMX=1` also runs
a session through a dropped connection and back.

To also test the config fetch, add `SetEnv XDG_CONFIG_HOME=<fixture>` to that
sshd's config. The fixture's `ghostty/config` should set
`cursor-style = underline` and an `initial-command`, and include
(`config-file = extra.ghostty`) a file that sets
`scrollback-limit-lines = 4242`. Then set
`TEST_RUNNER_GHOSTTY_TEST_SSH_CONFIG_FIXTURE=1`.

`TEST_RUNNER_GHOSTTY_TEST_VISUAL=1` shows sample output full screen for 8
seconds so you can screenshot it. It uses a theme, an 80-column fit, and the
key bar. `TEST_RUNNER_GHOSTTY_TEST_VISUAL_SETTINGS=1` does the same for the
Settings screen. `TEST_RUNNER_GHOSTTY_TEST_VISUAL_SPLITS=1` shows two tabs,
one split in two.

## Not yet supported

- Local (on-device) shells.
- Files app integration.
- Restoring tabs and splits after a relaunch on hosts without zmx.
- A confirmation UI for OSC 52 clipboard access (these requests are denied).
- Agent forwarding, port forwarding, and jump hosts.
