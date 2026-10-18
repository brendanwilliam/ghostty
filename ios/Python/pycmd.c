// `python3` as an ios_system command: ios_system dlopens this framework and
// calls python3_main(argc, argv) on a thread of its own, with the command's
// streams in the thread-local thread_stdin/out/err.
#include <Python/Python.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

// Runs argv the way `python3 [-c code | -m module | script] args` does, but
// catches KeyboardInterrupt itself: Py_RunMain answers an unhandled one by
// sending SIGINT to the whole process, which would take the app down.
static const char *driver =
    "import sys, os, runpy, traceback\n"
    "def _main():\n"
    "    args = sys.argv[1:]\n"
    "    try:\n"
    "        if args and args[0] == '-c':\n"
    "            sys.argv = ['-c'] + args[2:]\n"
    "            sys.path.insert(0, '')\n"
    "            exec(compile(args[1], '<string>', 'exec'), {'__name__': '__main__'})\n"
    "        elif args and args[0] == '-m':\n"
    "            sys.argv = args[1:]\n"
    "            sys.path.insert(0, '')\n"
    "            runpy.run_module(args[1], run_name='__main__', alter_sys=True)\n"
    "        elif args:\n"
    "            sys.argv = args\n"
    "            sys.path.insert(0, os.path.dirname(os.path.abspath(args[0])))\n"
    "            runpy.run_path(args[0], run_name='__main__')\n"
    "        else:\n"
    "            sys.argv = ['']\n"
    "            sys.path.insert(0, '')\n"
    "            exec(compile(sys.stdin.read(), '<stdin>', 'exec'), {'__name__': '__main__'})\n"
    "        return 0\n"
    "    except SystemExit as e:\n"
    "        if e.code is None: return 0\n"
    "        if isinstance(e.code, int): return e.code\n"
    "        print(e.code, file=sys.stderr)\n"
    "        return 1\n"
    "    except KeyboardInterrupt:\n"
    "        traceback.print_exc()\n"
    "        return 130\n"
    "    except BaseException:\n"
    "        traceback.print_exc()\n"
    "        return 1\n"
    "_rc = _main()\n"
    "sys.stdout.flush(); sys.stderr.flush()\n";

// The copies (pycmd, pycmdA...) share one Python.framework, so the state
// the interrupt needs lives in Python itself (sys._pycmd_thread), not in
// per-copy globals. One interpreter at a time: it is process-wide.

// Called from any thread (Ctrl-C), on any copy; returns 1 if it raised
// KeyboardInterrupt in the interpreter running on `thread`. No SIGINT handler is
// installed (that would replace the app's), so PyErr_SetInterrupt has
// nothing to run; instead raise KeyboardInterrupt in the interpreter's
// thread, which Python delivers between bytecodes.
int python3_interrupt(unsigned long thread) {
    if (!Py_IsInitialized()) return 0;
    // PyGILState_Ensure keeps a pointer to the first interpreter ever
    // created, which is stale after a Py_Finalize/Py_Initialize cycle. Make
    // a thread state for the current main interpreter instead.
    PyThreadState *state = PyThreadState_New(PyInterpreterState_Main());
    PyEval_AcquireThread(state);
    int delivered = 0;
    PyObject *id = PySys_GetObject("_pycmd_thread");
    // Only the interpreter running on `thread`: it is one per process, and
    // another tab's Ctrl-C must not stop it.
    if (id && PyLong_AsUnsignedLong(id) == thread)
        delivered = PyThreadState_SetAsyncExc(thread, PyExc_KeyboardInterrupt);
    PyThreadState_Clear(state);
    PyEval_ReleaseThread(state);
    PyThreadState_Delete(state);
    return delivered;
}

static int bundledHome(char *out, size_t size) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFURLRef url = CFBundleCopyResourceURL(bundle, CFSTR("python"), NULL, NULL);
    if (!url) return 0;
    Boolean ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)out, size);
    CFRelease(url);
    return ok;
}

int python3_main(int argc, char **argv) {
    char home[1024];
    if (!bundledHome(home, sizeof home)) {
        fprintf(thread_stderr, "python3: no bundled python folder\n");
        return 1;
    }
    // Python writes to file descriptors, not to ios_system's FILE streams.
    int in = thread_stdin ? dup(fileno(thread_stdin)) : -1;
    int out = thread_stdout ? dup(fileno(thread_stdout)) : -1;
    int err = thread_stderr ? dup(fileno(thread_stderr)) : -1;

    if (Py_IsInitialized()) {
        fprintf(thread_stderr, "python3: another python3 is running; one at a time\n");
        return 1;
    }
    PyConfig config;
    PyConfig_InitPythonConfig(&config);
    config.parse_argv = 0;
    config.install_signal_handlers = 0;
    config.home = Py_DecodeLocale(home, NULL);
    PyStatus status = PyConfig_SetBytesArgv(&config, argc, argv);
    if (!PyStatus_Exception(status)) status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        fprintf(thread_stderr, "python3: %s\n", status.err_msg ? status.err_msg : "init failed");
        return 1;
    }
    {
        PyObject *id = PyLong_FromUnsignedLong(PyThread_get_thread_ident());
        PySys_SetObject("_pycmd_thread", id);
        Py_XDECREF(id);
    }

    char setup[512];
    snprintf(setup, sizeof setup,
        "import sys, os\n"
        "sys.stdin = os.fdopen(%d, 'r', closefd=False) if %d >= 0 else sys.stdin\n"
        "sys.stdout = os.fdopen(%d, 'w', buffering=1, closefd=False) if %d >= 0 else sys.stdout\n"
        "sys.stderr = os.fdopen(%d, 'w', buffering=1, closefd=False) if %d >= 0 else sys.stderr\n",
        in, in, out, out, err, err);
    PyRun_SimpleString(setup);

    int code = 1;
    PyObject *main = PyImport_AddModule("__main__");
    PyObject *globals = main ? PyModule_GetDict(main) : NULL;
    if (globals) {
        PyObject *r = PyRun_String(driver, Py_file_input, globals, globals);
        if (r) {
            Py_DECREF(r);
            PyObject *rc = PyDict_GetItemString(globals, "_rc");
            if (rc) code = (int)PyLong_AsLong(rc);
        } else PyErr_Print();
    }
    Py_FinalizeEx();
    if (in >= 0) close(in);
    if (out >= 0) close(out);
    if (err >= 0) close(err);
    return code;
}
