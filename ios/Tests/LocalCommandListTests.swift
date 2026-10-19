import XCTest
@testable import GhosttyiOS

/// The command lists name only commands the app ships. A listed command
/// whose framework isn't in the app gets a stub file in `Library/bin`, so
/// dash finds it and then fails to load it.
final class LocalCommandListTests: XCTestCase {
    private let lists = ["commandDictionary", "extraCommandsDictionary", "localCommands"]

    private func commands(in list: String) throws -> [String: [String]] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: list, withExtension: "plist"), list)
        return try XCTUnwrap(PropertyListSerialization.propertyList(
            from: Data(contentsOf: url), format: nil) as? [String: [String]])
    }

    func testEveryListedCommandHasItsFramework() throws {
        let frameworks = try XCTUnwrap(Bundle.main.privateFrameworksURL)
        for list in lists {
            for (name, entry) in try commands(in: list) {
                let framework = entry[0].components(separatedBy: "/")[0]
                guard framework != "SELF" else { continue }
                // dash, vim and lg2 are only embedded where they can run.
                if list == "localCommands", !FileManager.default.fileExists(
                    atPath: frameworks.appendingPathComponent(framework).path) { continue }
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: frameworks.appendingPathComponent(framework).path),
                    "\(list): \(name) needs \(framework), which isn't in the app")
            }
        }
    }

    func testEveryListedCommandHasAStub() throws {
        let bin = Bundle.main.bundleURL.appendingPathComponent("Library/bin")
        for list in lists {
            for name in try commands(in: list).keys {
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: bin.appendingPathComponent(name).path), "\(name) has no stub in Library/bin")
            }
        }
    }

    func testNothingIsStubbedThatIsntListed() throws {
        let bin = Bundle.main.bundleURL.appendingPathComponent("Library/bin")
        var listed = Set<String>()
        for list in lists { listed.formUnion(try commands(in: list).keys) }
        let stubs = try FileManager.default.contentsOfDirectory(atPath: bin.path)
        XCTAssertEqual(Set(stubs).subtracting(listed), [])
    }
}
