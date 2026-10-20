// Entry point that lets the Cherri compiler run as a command inside the app.
//
// Cherri is a command-line program: it keeps its state in package-level
// variables, reads os.Args, and calls os.Exit. The build script rewrites
// os.Exit to iosExit, renames main to cherriMain and generates resetState
// (reset_state.go); cherri_run then runs one compile at a time, each starting
// from the initial state, with the command's own stdin, stdout and stderr.

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"unsafe"

	"github.com/electrikmilk/args-parser"
)

type exitCode int

// iosExit replaces os.Exit: it unwinds to cherri_run instead of ending the app.
func iosExit(code int) {
	panic(exitCode(code))
}

var runLock sync.Mutex

// Required by -buildmode=c-archive; never called.
func main() {}

//export cherri_run
func cherri_run(argc C.int, argv **C.char, inFD, outFD, errFD C.int) (status C.int) {
	runLock.Lock()
	defer runLock.Unlock()

	argvs := unsafe.Slice(argv, int(argc))
	osArgs := make([]string, 0, len(argvs))
	for _, a := range argvs {
		osArgs = append(osArgs, C.GoString(a))
	}

	stdin := os.NewFile(uintptr(inFD), "stdin")
	stdout := os.NewFile(uintptr(outFD), "stdout")
	stderr := os.NewFile(uintptr(errFD), "stderr")
	// The fds are duplicates made by the caller, ours to close.
	defer stdin.Close()
	defer stdout.Close()
	defer stderr.Close()
	os.Stdin, os.Stdout, os.Stderr = stdin, stdout, stderr

	defer func() {
		switch r := recover().(type) {
		case nil:
		case exitCode:
			status = C.int(r)
		default:
			fmt.Fprintf(stderr, "cherri: %v\n", r)
			status = 1
		}
	}()

	os.Args = osArgs
	resetState()
	parseIOSArgs(osArgs)
	cherriMain()
	status = 0
	if _, err := os.Stat(inputPath); err == nil && inputPath != outputPath {
		if err := os.Rename(inputPath, outputPath); err != nil {
			fmt.Fprintf(stderr, "cherri: %v\n", err)
			status = 1
		} else {
			fmt.Fprintf(stdout, "Wrote %s\n", outputPath)
		}
	}
	return status
}

// parseIOSArgs mirrors args-parser's parsing of os.Args and turns signing
// off: the app has no way to sign, so the output is an unsigned Shortcut.
func parseIOSArgs(osArgs []string) {
	args.Args = make(map[string]string)
	for i, a := range osArgs {
		if i == 0 {
			continue
		}
		if strings.Contains(a, "--") {
			a = strings.TrimPrefix(a, "--")
		} else if strings.Contains(a, "-") {
			a = strings.TrimPrefix(a, "-")
		}
		if kv := strings.Split(a, "="); strings.Contains(a, "=") && len(kv) > 1 {
			args.Args[kv[0]] = kv[1]
			continue
		}
		args.Args[a] = ""
	}
	args.Args["skip-sign"] = ""
}
