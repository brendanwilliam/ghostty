# Local shell spike (phase 1, throwaway)

An on-device shell built on [ios_system](https://github.com/holzschu/ios_system),
to de-risk the offline terminal before it goes into the app. `LocalBackend`
implements the app's own `TerminalBackend` protocol
(`ios/Sources/Session/TerminalBackend.swift`, compiled in unchanged), so it
can move into the app as is. SwiftTerm stands in for libghostty here,
because libghostty needs a Zig build.

## Build

```sh
cd ios/Spikes/LocalShell
./fetch-frameworks.sh     # pinned xcframeworks, SHA-256 checked
xcodegen generate
open LocalShellSpike.xcodeproj
```

dash, vim and lg2 ship only device (and Intel simulator) slices, so the
simulator build leaves them out. Test those on a phone.

## Self-test

Launch with `-selftest` to type a script into the backend and save the
transcript to `Documents/selftest.txt`. `SIMCTL_CHILD_SPIKE_STEPS` replaces
the script: steps separated by `;;`, each typed with Enter. `^C`, `^D` and
`^[A` (up arrow) are sent without Enter, and `^R<cols>x<rows>` resizes.
Add `-raw` for a byte-level transcript, and `-debug` to trace input,
`ios_system` calls and output on stderr.

Don't use `simctl launch --console-pty` for pager tests: it gives the app
a real `/dev/tty`, which `less` reads keys from instead of ios_system.

## Findings (simulator, iOS 26.5)

Works:
- Commands, pipes and redirection: `ls`, `cat`, `grep`, `sed`, `sort`,
  `head`, `tr`, `wc`, `find`, `tar czf/tzf`, `ln -s`, `awk '…'`, `>`, `>>`.
- `isatty` is true for commands, so `ls` prints colors.
- Cooked input to a running command (`cat`), and Ctrl-D ends it.
- Line editing at the prompt: backspace, Ctrl-U, up/down history.
- `less file` and `ls | less`: raw keys, alternate screen, `q` restores
  the screen. ios_system calls the app's `startInteractive()` hook to switch
  to raw input. Pagers read keys from ios_system's tty pipe; everything else
  reads stdin.
- `$COLUMNS`/`$LINES`, and the size used by programs started after a resize.
- The whole app is about 20 MB with every framework embedded.

Doesn't work, or needs a decision:
1. **No shell syntax without dash.** ios_system's own parser handles
   pipes and redirection only. `a && b` and `a; b` pass `&&`/`;` as
   arguments (`mkdir -p x && cd x` made directories named `&&` and `cd`).
   Quoting isn't POSIX either: `"\$2"` keeps the backslash. Running dash as
   the shell, or sending lines through `dash -c`, is the likely fix. That
   needs a device test.
2. **Missing commands:** `sleep` and `printf` aren't in ios_system.
3. **Ctrl-C** uses `pthread_cancel`. It stopped `cat` (blocked in read)
   at once, but a long `find /` ran on. CPU-bound loops (`python -c 'while
   1: pass'`) may ignore it too.
4. **Resize while a program runs** isn't picked up: `less` kept its old
   height after `ios_setWindowSize` sent SIGWINCH, even after a keypress.
   This matters for vim when the phone rotates.
5. **`cd ..` leaves `$HOME`** for the app container. `ios_setMiniRoot`
   can stop that.
6. ios_system keeps its current session **per thread**. Any call on a new
   thread (input, Ctrl-C) must call `ios_switchSession` first.
7. Python isn't in this spike. a-Shell's prebuilt Python is 3.11 from 2022.
   The likely route is CPython's official iOS build (3.13+, PEP 730), wired
   to ios_system's streams. That's a separate spike.

## Findings (iPhone 17 Pro Max, iOS 27.2)

Works:
- **dash**, both `dash -c '…'` and interactive `dash`: `&&`, `;`, `||`,
  `for`, `$((…))`, `$0`, `exit` back to the prompt. Eight runs in a row
  work. ios_system loads a fresh copy of dash for runs that overlap
  (`dashA`–`dashE`), so those have to be embedded too.
- **vim** (`vim -u NONE`): insert, Esc, `:wq` saves, `cat` shows the file.
  After a resize to 50x12 it redraws at 12 rows, so rotation is fine in
  vim (unlike `less`, finding 4).
- **lg2**: `init`, `add`, `config`, `commit`, `log`, `status`.
- `find /` finishes almost at once on device, because the sandbox blocks
  most of the filesystem.

Still open:
- **Ctrl-C does not stop a CPU-bound loop** (`dash -c 'while true; do
  i=$((i+1)); done'`). Later input goes to the stuck command's stdin. This
  needs a real fix before shipping: build dash from source and have it
  check an interrupt flag the backend sets, or add a "force quit tab"
  that abandons the thread.
- dash prints "Cannot read termcap database" because no terminfo is bundled
  (planned).
- The prompt shows `Documents` instead of `~` on device: `ios_getLogicalPWD`
  returns the `/private/var/…` path, and `$HOME` doesn't have that prefix.
  Compare resolved paths.

## On-device checklist

Install on a phone, then try:
- [ ] `dash`, then `echo a && echo b; for i in 1 2; do echo $i; done`, `exit`
- [ ] `dash -c 'x=1; [ $x = 1 ] && echo yes'`
- [ ] `vim notes.txt`: insert text, `:wq`, then `cat notes.txt`
- [ ] vim: rotate the phone while open. Does it redraw? (finding 4)
- [ ] `lg2 init repo`, `cd repo`, `echo hi > a`, `lg2 add a`,
      `lg2 commit -m first`, `lg2 log`
- [ ] Ctrl-C on `find / -name x` (finding 3)
- [ ] Airplane Mode on: everything above still works
- [ ] Files app → On My iPhone → LocalShellSpike shows `notes.txt`
