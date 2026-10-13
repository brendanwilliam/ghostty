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

Rebuild the XCFramework whenever the Zig core changes.

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

`TEST_RUNNER_GHOSTTY_TEST_VISUAL=1` shows sample output full screen for 8
seconds so you can screenshot it.

## Not yet supported

- Local (on-device) shells.
- Files app integration.
- Tabs, splits, or multiple sessions.
- A confirmation UI for OSC 52 clipboard access (these requests are denied).
- Agent forwarding, port forwarding, and jump hosts.
- Reconnecting automatically after the app is suspended.
