import XCTest
@testable import GhosttyiOS

final class AcknowledgementsTests: XCTestCase {
    func testEveryEntryHasItsLicenseText() {
        for item in Acknowledgements.all {
            let text = item.text
            XCTAssertNotNil(text, "\(item.name): \(item.file).txt isn't in the bundle")
            XCTAssertGreaterThan(text?.count ?? 0, 400, "\(item.name): the license text is too short")
        }
    }

    func testEntriesAreUnique() {
        let ids = Acknowledgements.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        let files = Acknowledgements.all.map(\.file)
        XCTAssertEqual(files.count, Set(files).count)
    }

    func testPythonsLicenseIsThere() throws {
        let python = try XCTUnwrap(Acknowledgements.all.first { $0.id == "python" })
        let text = try XCTUnwrap(python.text)
        XCTAssertTrue(text.contains("PYTHON SOFTWARE FOUNDATION LICENSE VERSION 2"))
        XCTAssertTrue(text.contains("Python Software Foundation"))
    }

    func testTheLinkingExceptionIsNamedForLibgit2() throws {
        let item = try XCTUnwrap(Acknowledgements.all.first { $0.id == "libgit2" })
        XCTAssertTrue(try XCTUnwrap(item.text).localizedCaseInsensitiveContains("linking exception"))
    }
}
