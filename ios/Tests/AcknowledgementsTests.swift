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

    func testCherrisLicenseAndSourceAreThere() throws {
        let item = try XCTUnwrap(Acknowledgements.all.first { $0.id == "cherri" })
        let text = try XCTUnwrap(item.text)
        XCTAssertTrue(text.contains("GNU GENERAL PUBLIC LICENSE"))
        XCTAssertTrue(text.contains("bcc0095754e2cc0baaeb4d93dae172b8153b4716"))
    }

    func testTheLinkingExceptionIsNamedForLibgit2() throws {
        let item = try XCTUnwrap(Acknowledgements.all.first { $0.id == "libgit2" })
        XCTAssertTrue(try XCTUnwrap(item.text).localizedCaseInsensitiveContains("linking exception"))
    }

    /// The BSD advertising clause: files in the tools still carry it, so
    /// both acknowledgements are shown.
    func testTheBSDAcknowledgementsAreShown() throws {
        let tools = try XCTUnwrap(Acknowledgements.all.first { $0.id == "bsd-tools" })
        let text = try XCTUnwrap(tools.text)
        XCTAssertTrue(text.contains("This product includes software developed by the University of California, Berkeley and its contributors."))
        XCTAssertTrue(text.contains("This product includes software developed by the NetBSD Foundation, Inc. and its contributors."))
    }

    func testTheAppleLicenseAndTheOtherNoticesAreThere() throws {
        let apsl = try XCTUnwrap(Acknowledgements.all.first { $0.id == "apsl" }?.text)
        XCTAssertTrue(apsl.contains("APPLE PUBLIC SOURCE LICENSE"))
        let other = try XCTUnwrap(Acknowledgements.all.first { $0.id == "other-notices" }?.text)
        XCTAssertTrue(other.contains("RSA Data Security"))
        XCTAssertTrue(other.contains("BEER-WARE"))
    }
}
