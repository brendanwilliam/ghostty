// `python3` as an ios_system command: ios_system dlopens this framework and
// calls python3_main(argc, argv) on a thread of its own, with the command's
// streams in the thread-local thread_stdin/out/err.
#include <Python/Python.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <objc/objc-sync.h>

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

// Every run is its own sub-interpreter of one process-wide interpreter that
// is started on first use and never finalized: runs can overlap, start in
// milliseconds, and share nothing but the GIL. (The copies of this
// framework, pycmd and pythonA...E, share one Python.framework, so
// everything process-wide lives in Python or behind the lock below, never in
// this file's globals.)

// A lock that all copies of this framework share: the main bundle object.
#define PROCESS_LOCK ((id)CFBundleGetMainBundle())

static int bundledHome(char *out, size_t size) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFURLRef url = CFBundleCopyResourceURL(bundle, CFSTR("python"), NULL, NULL);
    if (!url) return 0;
    Boolean ok = CFURLGetFileSystemRepresentation(url, true, (UInt8 *)out, size);
    CFRelease(url);
    return ok;
}

// Starts the main interpreter if no run has yet, and leaves the GIL free.
static const char *ensureInterpreter(const char *home) {
    const char *failure = NULL;
    objc_sync_enter(PROCESS_LOCK);
    if (!Py_IsInitialized()) {
        PyConfig config;
        PyConfig_InitPythonConfig(&config);
        config.parse_argv = 0;
        // Python's SIGINT handler would replace the app's (libghostty's).
        config.install_signal_handlers = 0;
        config.home = Py_DecodeLocale(home, NULL);
        PyStatus status = Py_InitializeFromConfig(&config);
        PyConfig_Clear(&config);
        if (PyStatus_Exception(status)) {
            failure = status.err_msg ? status.err_msg : "init failed";
        } else {
            // The thread that started it doesn't keep the interpreter.
            PyEval_SaveThread();
        }
    }
    objc_sync_exit(PROCESS_LOCK);
    return failure;
}

// Ctrl-C: raise KeyboardInterrupt in the run on `thread`. Called from any
// thread, on any copy; returns 1 if a run on that thread was found. No SIGINT
// handler is installed, so PyErr_SetInterrupt would have nothing to run.
int python3_interrupt(unsigned long thread) {
    if (!Py_IsInitialized()) return 0;
    PyThreadState *attached = PyThreadState_New(PyInterpreterState_Main());
    PyEval_AcquireThread(attached);
    int delivered = 0;
    // Runs start and end holding the GIL, so the list of interpreters can't
    // change under us.
    for (PyInterpreterState *interp = PyInterpreterState_Head(); interp && !delivered;
         interp = PyInterpreterState_Next(interp)) {
        PyThreadState *probe = PyThreadState_New(interp);
        PyThreadState *previous = PyThreadState_Swap(probe);
        PyObject *id = PySys_GetObject("_pycmd_thread");
        if (id && PyLong_AsUnsignedLong(id) == thread)
            delivered = PyThreadState_SetAsyncExc(thread, PyExc_KeyboardInterrupt);
        PyThreadState_Clear(probe);
        PyThreadState_Swap(previous);
        PyThreadState_Delete(probe);
    }
    PyThreadState_Clear(attached);
    PyEval_ReleaseThread(attached);
    PyThreadState_Delete(attached);
    return delivered;
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

    const char *failure = ensureInterpreter(home);
    if (failure) {
        fprintf(thread_stderr, "python3: %s\n", failure);
        return 1;
    }

    PyThreadState *attached = PyThreadState_New(PyInterpreterState_Main());
    PyEval_AcquireThread(attached);
    PyInterpreterConfig interpreterConfig = {
        // Single-phase extension modules (most of the standard library on
        // iOS) need the shared allocator and the shared GIL.
        .use_main_obmalloc = 1,
        .allow_fork = 0,
        .allow_exec = 0,
        .allow_threads = 1,
        // A daemon thread left running would stop the interpreter ending.
        .allow_daemon_threads = 0,
        .check_multi_interp_extensions = 0,
        .gil = PyInterpreterConfig_SHARED_GIL,
    };
    PyThreadState *run = NULL;
    PyStatus status = Py_NewInterpreterFromConfig(&run, &interpreterConfig);
    if (PyStatus_Exception(status) || !run) {
        PyEval_ReleaseThread(attached);
        PyThreadState_Delete(attached);
        fprintf(thread_stderr, "python3: %s\n", status.err_msg ? status.err_msg : "no interpreter");
        return 1;
    }

    {
        PyObject *id = PyLong_FromUnsignedLong(PyThread_get_thread_ident());
        PySys_SetObject("_pycmd_thread", id);
        Py_XDECREF(id);
        // A new interpreter starts with the first run's argv; set ours.
        PyObject *list = PyList_New(0);
        for (int i = 0; i < argc; i++) {
            PyObject *arg = PyUnicode_DecodeFSDefault(argv[i]);
            PyList_Append(list, arg);
            Py_XDECREF(arg);
        }
        PySys_SetObject("argv", list);
        Py_XDECREF(list);
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
    Py_EndInterpreter(run);
    // Back to the thread state this run began with, to give it up.
    PyThreadState_Swap(attached);
    PyThreadState_Clear(attached);
    PyThreadState_DeleteCurrent();

    if (in >= 0) close(in);
    if (out >= 0) close(out);
    if (err >= 0) close(err);
    return code;
}
