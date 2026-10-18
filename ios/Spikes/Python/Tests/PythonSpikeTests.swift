import XCTest
import ios_system

/// Runs `python3` through ios_system the way the terminal app would, and
/// records numbers for the spike README.
final class PythonSpikeTests: XCTestCase {
    private static let ready: Void = {
        initializeEnvironment()
        let plist = Bundle.main.path(forResource: "pythonCommands", ofType: "plist")!
        _ = addCommandList(plist)
    }()

    private var scratch: URL!

    override func setUpWithError() throws {
        _ = Self.ready
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        FileManager.default.changeCurrentDirectoryPath(scratch.path)
    }

    /// Runs one command line; returns what it printed to stdout and stderr.
    @discardableResult
    private func run(_ command: String, input: String = "") -> (out: String, err: String, status: Int32, seconds: Double) {
        let outURL = scratch.appendingPathComponent("out.txt")
        let errURL = scratch.appendingPathComponent("err.txt")
        let inURL = scratch.appendingPathComponent("in.txt")
        try? input.write(to: inURL, atomically: true, encoding: .utf8)
        let session = strdup(UUID().uuidString)
        defer { free(session) }
        ios_switchSession(session)
        ios_setContext(session)
        thread_stdin = nil
        thread_stdout = nil
        thread_stderr = nil
        ios_setStreams(fopen(inURL.path, "r"), fopen(outURL.path, "w"), fopen(errURL.path, "w"))
        let pid = ios_fork()
        let start = Date()
        let status = ios_system(command)
        ios_waitpid(pid)
        ios_releaseThreadId(pid)
        let seconds = Date().timeIntervalSince(start)
        // ios_system closes the streams it was given when the command ends.
        let out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        return (out, err, status, seconds)
    }


    func testPrintsFromDashC() {
        let r = run("python3 -c \"print(6 * 7)\"")
        XCTAssertEqual(r.out, "42\n", "\(r)")
        print("SPIKE first-run seconds:", r.seconds)
    }

    func testRunsAScriptFromDocuments() throws {
        try "import sys, json, math, sqlite3, ctypes, zlib\nprint(json.dumps({'pi': round(math.pi, 3)}), sys.version_info[:2])\n"
            .write(to: scratch.appendingPathComponent("hello.py"), atomically: true, encoding: .utf8)
        let r = run("python3 hello.py")
        XCTAssertTrue(r.out.contains("{\"pi\": 3.142} (3, 14)"), "\(r)")
    }

    func testRunsManyTimesInOneProcess() {
        for i in 1...12 {
            let r = run("python3 -c \"print(\(i))\"")
            XCTAssertEqual(r.out, "\(i)\n", "run \(i): \(r)")
        }
    }

    func testStateDoesNotLeakBetweenRuns() {
        run("python3 -c \"import builtins; builtins.leak = 1\"")
        let r = run("python3 -c \"import builtins; print(hasattr(builtins, 'leak'))\"")
        XCTAssertEqual(r.out, "False\n", "\(r)")
    }

    func testReadsStdin() {
        let r = run("python3 -c \"print(int(input()) + 1)\"", input: "41\n")
        XCTAssertEqual(r.out, "42\n", "\(r)")
    }

    func testErrorsGoToStderrWithAStatus() {
        let r = run("python3 -c \"raise SystemExit(3)\"")
        XCTAssertEqual(r.status, 3, "\(r)")
        let e = run("python3 -c \"1/0\"")
        XCTAssertTrue(e.err.contains("ZeroDivisionError"), "\(e)")
    }

    func testPipesInAShellLine() {
        let r = run("echo 20 | python3 -c \"import sys; print(int(sys.stdin.read()) * 2)\"")
        XCTAssertEqual(r.out, "40\n", "\(r)")
    }

    func testStandardLibraryWorks() {
        let r = run("python3 -c \"import re, datetime, hashlib, collections, itertools, random, textwrap; print(hashlib.sha256(b'a').hexdigest()[:8])\"")
        XCTAssertEqual(r.out, "ca978112\n", "\(r)")
    }

    func testPipInstalledPackagesAreNotAssumed() {
        let r = run("python3 -c \"import ssl; print(ssl.OPENSSL_VERSION)\"")
        print("SPIKE ssl:", r)
    }

    /// Asks whichever copy of the command is running to raise
    /// KeyboardInterrupt. Every dlopen is balanced (see dash: a leaked
    /// reference pins the copy).
    private func interruptPython() {
        for suffix in ["", "A", "B", "C", "D", "E"] {
            let path = Bundle.main.privateFrameworksURL!.appendingPathComponent("\(suffix.isEmpty ? "pycmd" : "python\(suffix)").framework/\(suffix.isEmpty ? "pycmd" : "python\(suffix)")").path
            guard let handle = dlopen(path, RTLD_NOLOAD) else { continue }
            defer { dlclose(handle) }
            if let symbol = dlsym(handle, "python3_interrupt") {
                unsafeBitCast(symbol, to: (@convention(c) () -> Void).self)()
            }
        }
    }

    func testControlCStopsAPureLoop() {
        let done = expectation(description: "loop ended")
        var result: (out: String, err: String, status: Int32, seconds: Double)?
        let thread = Thread {
            result = self.run("python3 -c \"while True: pass\"")
            done.fulfill()
        }
        thread.start()
        Thread.sleep(forTimeInterval: 0.7)
        let asked = Date()
        interruptPython()
        wait(for: [done], timeout: 5)
        print("SPIKE interrupt latency:", Date().timeIntervalSince(asked), result as Any)
        XCTAssertTrue(result?.err.contains("KeyboardInterrupt") ?? false, "\(String(describing: result))")
    }

    func testControlCStopsSleep() {
        let done = expectation(description: "sleep ended")
        var result: (out: String, err: String, status: Int32, seconds: Double)?
        Thread {
            result = self.run("python3 -c \"import time; time.sleep(3)\"")
            done.fulfill()
        }.start()
        Thread.sleep(forTimeInterval: 0.7)
        let asked = Date()
        interruptPython()
        wait(for: [done], timeout: 10)
        // The exception is raised when the C call returns: sleep isn't cut short.
        print("SPIKE sleep interrupt took:", Date().timeIntervalSince(asked), result as Any)
        XCTAssertTrue(result?.err.contains("KeyboardInterrupt") ?? false, "\(String(describing: result))")
    }


    func testReadsAProgramFromStdin() {
        let r = run("python3", input: "print(1 + 1)\n")
        XCTAssertEqual(r.out, "2\n", "\(r)")
    }

    func testAnImportedModuleInTheCurrentDirectory() throws {
        try "VALUE = 99\n".write(to: scratch.appendingPathComponent("mymod.py"), atomically: true, encoding: .utf8)
        let r = run("python3 -c \"import mymod; print(mymod.VALUE)\"")
        XCTAssertEqual(r.out, "99\n", "\(r)")
    }

    func testMemoryAfterManyRuns() {
        func rss() -> Int {
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
            }
            return Int(info.resident_size) / 1_000_000
        }
        let before = rss()
        for i in 1...30 { run("python3 -c \"print(\(i))\"") }
        print("SPIKE rss MB before/after 30 runs:", before, rss())
    }
}
