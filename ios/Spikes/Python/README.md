# Python spike: CPython as an ios_system command

Throwaway spike. Question: can `python3` run inside the local shell, offline,
as an App Store-safe bundled command? Run on the iOS simulator only (a phone
run is still to do).

    ../../scripts/fetch-ios-system.sh   # once
    ./fetch-python.sh                   # BeeWare Python-Apple-support, CPython 3.14
    xcodegen generate
    xcodebuild test -project PythonSpike.xcodeproj -scheme PythonSpike \
      -destination 'platform=iOS Simulator,name=iPhone 17 Pro'

## Result: go (with the caveats below)

14 tests pass. Python runs as a command inside ios_system, in the same
process as the app, with no fork/exec and no JIT.

| Question | Answer |
| --- | --- |
| `python3 -c`, script file, stdin program, `import` from the cwd | works |
| stdout/stderr/stdin and exit status through ios_system streams and pipes (`echo 20 \| python3 ...`) | works |
| stdlib: json, math, sqlite3, ctypes, zlib, hashlib, re, ssl (OpenSSL 3.5) | works |
| Run repeatedly (30 runs in one process) | works; memory flat (RSS 277 MB before and after, test host included) |
| State leaking between runs | none (`builtins` changes don't survive) |
| Start time | about 20 ms warm, 100 ms for the very first run |
| Ctrl-C on a pure-Python loop | works: KeyboardInterrupt in 11 ms, status 130 |
| Ctrl-C during `time.sleep(3)` | delayed: the exception is raised when the C call returns (took 2.3 s) |
| Two `python3` at once | refused with a message ("one at a time") |
| Size (device) | Python.framework 8 MB; stdlib about 28 MB without `test/` (37 MB), `idlelib`, `tkinter`, `turtledemo`, `ensurepip` |

## What it took (these are the lessons)

- **Wire-up.** ios_system loads a framework and calls an exported function.
  `Sources/pycmd/pycmd.c` exports `python3_main(argc, argv)`;
  `Resources/pythonCommands.plist` maps `python3` and `python` to it. It links
  Python.framework and ios_system (for `thread_stdin/out/err`).
- **Copies.** Like dash, ios_system won't run one framework's main twice; it
  loads fresh copies named `<command>A` to `E`. So there are six frameworks
  built from the same source: `pycmd` plus `pythonA` to `pythonE`. The base
  can't be called `python`: `python.framework` and `Python.framework` are the
  same folder on a case-insensitive disk, and signing fails. The copies are
  recycled: 30 runs worked.
- **Streams.** Python writes to file descriptors, not to ios_system's `FILE`
  streams, so the command `dup`s `fileno(thread_stdout)` etc. and replaces
  `sys.stdin/stdout/stderr` before running anything.
- **Don't use `Py_RunMain`.** On an unhandled `KeyboardInterrupt` it kills
  the whole process with `kill(getpid(), SIGINT)`. A small Python driver
  (in `pycmd.c`) handles `-c`, `-m`, a script and stdin itself, catches
  KeyboardInterrupt, and returns the status.
- **No signal handlers.** `install_signal_handlers = 0`, because Python's
  SIGINT handler would replace the app's (libghostty's).
- **Interrupt.** `python3_interrupt()` raises KeyboardInterrupt in the
  interpreter's thread with `PyThreadState_SetAsyncExc`, from any thread.
  `PyErr_SetInterrupt` does nothing without Python's own SIGINT handler.
  `PyGILState_Ensure` is wrong after a finalize/initialize cycle (it keeps a
  stale pointer to the first interpreter), so the interrupt makes its own
  thread state for `PyInterpreterState_Main()`.
- **The six copies share one interpreter.** Call the interrupt on one copy
  only (calling it on each delivered it six times). Only one `python3` can
  run at a time in the process; a second says so and exits 1.
- **dlopen balance.** Looking up a copy with `dlopen(RTLD_NOLOAD)` needs a
  matching `dlclose`, or the copy stays pinned (the same bug the patched dash
  had).

## Not done / follow-ups before shipping

- **App Store: extension modules** (done in the app's build phase; see ios/README.md). The 67 `.so` files in `lib-dynload` are
  loose files, which App Review rejects on device. BeeWare's testbed
  (`Python.xcframework/build/utils.sh`, `install_python`) converts each into
  its own framework with a stub left in the stdlib. The simulator doesn't
  enforce this, so it's untested here. Do it as part of an Xcode build phase.
- **Trim the stdlib** (drop `test/`, `idlelib`, `tkinter`, `turtledemo`,
  `ensurepip`, unused extension modules) to cut about 40 MB.
- **REPL.** `python3` with no arguments reads a program from stdin. An
  interactive prompt needs `code.interact` plus line editing from the
  backend; not tried.
- **Concurrency.** The spike runs one Python at a time (one interpreter per
  process, finalized after each run). The app now runs each program in a
  sub-interpreter (shared GIL, legacy extension modules allowed), so
  programs overlap; see `ios/Python/pycmd.c` and `ios/README.md`.
- **Sleep and other C calls aren't interrupted** until they return.
- **Wire into the app.** Add the six frameworks, `pythonCommands.plist` (via
  `addCommandList`), `PYTHONHOME`-style resources and an `ios/scripts`
  fetch step to the main project, then stub files in `Library/bin`
  (`python3`, `python`), then bridge the backend's Ctrl-C to
  `python3_interrupt` the way it does for dash.
- **Phone run** (device slices, memory limits, suspension).
