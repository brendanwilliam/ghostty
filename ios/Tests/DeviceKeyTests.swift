import CryptoKit
import XCTest
@testable import GhosttyiOS

final class DeviceKeyTests: XCTestCase {
    private let key = Curve25519.Signing.PrivateKey()

    func testAuthorizeCommandIsOneLineThatAddsTheKey() {
        let line = DeviceKey.authorizedKeysLine(for: key, comment: "ghostty-ios@Brendans-iPhone")
        let command = DeviceKey.authorizeCommand(for: key, comment: "ghostty-ios@Brendans-iPhone")

        XCTAssertFalse(command.contains("\n"), "one command to paste")
        XCTAssertTrue(command.contains("'\(line)'"), "the key line, single-quoted")
        XCTAssertTrue(command.contains("chmod 700 ~/.ssh"))
        XCTAssertTrue(command.contains("chmod 600 ~/.ssh/authorized_keys"))
        XCTAssertTrue(command.contains("grep -qF"), "doesn't add the key twice")
        XCTAssertFalse(command.contains("pbpaste"), "nothing to copy first")
    }

    func testTheCommandCarriesOnlyThePublicKey() {
        let command = DeviceKey.authorizeCommand(for: key, comment: DeviceKey.defaultComment)
        let privateKey = key.rawRepresentation.base64EncodedString()
        XCTAssertFalse(command.contains(privateKey))
        XCTAssertFalse(command.contains("PRIVATE"))
    }

    func testTheCommentCantEscapeTheQuoting() {
        // The default comment keeps to letters, digits and hyphens, so the
        // device's name can't inject shell syntax.
        let comment = DeviceKey.defaultComment
        XCTAssertTrue(comment.allSatisfy { $0.isLetter || $0.isNumber || "-@".contains($0) }, comment)
    }
}
