import Foundation
import ios_system

/// Process-wide setup for ios_system, done once.
enum LocalEnvironment {
    /// The shell's home: the app's Documents folder, which the Files app shows.
    static let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    private static let once: Void = {
        initializeEnvironment()
        setenv("HOME", home.path, 1)
        setenv("TERM", "xterm-256color", 1)
        setenv("LANG", "en_US.UTF-8", 1)
        setenv("LC_CTYPE", "UTF-8", 1)
        setlocale(LC_CTYPE, "UTF-8")
        // Commands from frameworks that ios_system's dictionary doesn't
        // list (dash, vim, less, lg2).
        if let extra = Bundle.main.path(forResource: "spikeCommands", ofType: "plist") {
            if let error = addCommandList(extra) { NSLog("addCommandList: \(error)") }
        }
    }()

    static func prepare() {
        _ = once
    }

    /// Frameworks embedded in this build; dash, vim and lg2 only ship
    /// device slices, so the simulator build leaves them out.
    static var embeddedFrameworks: [String] {
        let url = Bundle.main.privateFrameworksURL!
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return names.filter { $0.hasSuffix(".framework") }.map { String($0.dropLast(10)) }.sorted()
    }
}
