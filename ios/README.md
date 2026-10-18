# Ghostty for iOS

An iOS terminal built on libghostty (Ghostty's terminal emulator and Metal
renderer). It connects to a Mac (or any SSH server) on the local network, and
**This iPhone** runs a shell on the phone itself, with no network.

<img src="docs/smoke-test.png" width="300" alt="Ghostty rendering on the iOS simulator">

## Build

Requirements: Xcode 27, [Zig 0.16.0](https://ziglang.org/download/), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
# Prebuilt command frameworks for the on-device shell (checked by SHA-256).
ios/scripts/fetch-ios-system.sh

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

## Local terminal (This iPhone)

The first entry in the host list opens a shell that runs on the phone, built
on [ios_system](https://github.com/holzschu/ios_system) (the library behind
a-Shell). It works in Airplane Mode and uses the same tabs and splits as SSH
hosts. `Sources/Local/LocalBackend.swift` implements `TerminalBackend`, so
libghostty draws it like any other session.

- **Shell:** dash, running as one long-lived command per tab. Variables,
  `cd`, `&&`, loops and scripts work. `~/.dashrc` is read at startup.
- **Commands:** the BSD file and text tools (`ls`, `cat`, `grep`, `sed`,
  `awk`, `tar`, `find`, ...), `less`, `vim`, and `lg2` (libgit2's `git`).
  Commands are compiled into frameworks inside the app; nothing is
  downloaded or run from outside it.
- **Files:** `$HOME` is the app's Documents folder, so files show up in the
  Files app under On My iPhone > Ghostty.
- **No real TTY:** ios_system commands read and write pipes. The backend
  echoes and edits typed lines itself (`LineDiscipline`), and passes raw
  bytes through while a full-screen program (vim, less) has the keyboard.
- **Ctrl-C:** stops commands that wait for input or print output (`cat`,
  `find`, ...), and gives a fresh prompt when dash is idle. A loop in dash
  itself (`while true; do :; done`) is stopped by our build of dash
  (`Patches/dash-ios.patch`), which checks an interrupt flag between
  commands. Any other command that computes without ever blocking (an awk
  loop) can't be stopped: ios_system uses `pthread_cancel`, which needs a
  blocking call. The app says so, and closing the tab leaves that thread
  spinning until the app quits.
- **Lifetime:** iOS suspends the app in the background, which pauses
  commands. Local tabs aren't saved; they start fresh with the app.
- **How dash finds commands:** it looks for executable files on `PATH`, and
  ios_system puts `<app>/Library/bin` there. A build phase fills it with
  empty stub files named after every command, so dash can see them.
- **Environment:** dash reads the real process environment, so `HOME`,
  `TERM`, `ENV` and the rest are set once at launch, before libghostty
  starts (`LocalEnvironment.prepareProcess`). libghostty keeps a pointer to
  `environ` from startup, so nothing may add to it later.

**Building dash.** `ios/scripts/build-dash.sh` builds dash and its copies
(dashA to dashE) from holzschu/dash_iOS at a pinned commit, with the patch,
for device and for the arm64 simulator, and replaces the prebuilt
`Frameworks/dash*.xcframework`. Run it after `fetch-ios-system.sh`, then
`xcodegen generate`. Without it the prebuilt dash works on devices but
can't stop a loop.

**Terminal definitions.** A device has no terminfo, so `Terminfo/` (compiled
with `tic` from xterm-256color and Ghostty's entry) is bundled and
`TERMINFO` points at it; this is what dash's "Cannot read termcap database"
warning needed.

**Simulator.** vim and lg2 are only published for devices (and Intel
simulators), so an Apple-silicon simulator can't load them as shipped. Run
`ios/scripts/make-sim-frameworks.sh` (after `fetch-ios-system.sh`) to make
simulator copies of them (the device builds with their platform changed,
signed ad hoc; local testing only, never shipped), then `xcodegen generate`.
dash comes from `build-dash.sh` above. Without a dash simulator slice the
simulator falls back to a small built-in prompt
(`LocalBackend.Shell.builtin`) that supports pipes and redirection but not
`&&`, `;` or variables. `LocalBackendTests` always use the built-in prompt;
`LocalDashTests` run the real shell wherever dash is embedded.
