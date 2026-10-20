// The `cherri` command: ios_system calls cherri_main, which hands the
// arguments and the command's streams to the Go compiler (cherri_run).
#include <dlfcn.h>
#include <stdio.h>
#include <limits.h>
#include <unistd.h>

extern __thread FILE *thread_stdin;
extern __thread FILE *thread_stdout;
extern __thread FILE *thread_stderr;

extern int cherri_run(int argc, char **argv, int in, int out, int err, char *cwd);

// The Go runtime can't be unloaded, so keep this image mapped even if
// ios_system closes the framework after a command.
__attribute__((constructor)) static void pin(void) {
    Dl_info info;
    if (dladdr((void *)pin, &info) && info.dli_fname) {
        dlopen(info.dli_fname, RTLD_LAZY | RTLD_NODELETE);
    }
}

int cherri_main(int argc, char **argv) {
    int in = thread_stdin ? dup(fileno(thread_stdin)) : -1;
    int out = thread_stdout ? dup(fileno(thread_stdout)) : -1;
    int err = thread_stderr ? dup(fileno(thread_stderr)) : -1;
    // The command thread's directory; Go runs its file calls elsewhere.
    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd)) cwd[0] = 0;
    return cherri_run(argc, argv, in, out, err, cwd);
}
