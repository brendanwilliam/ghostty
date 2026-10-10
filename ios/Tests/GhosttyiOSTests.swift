import XCTest
@testable import GhosttyiOS

final class OpenSSHTests: XCTestCase {
    // Generated with `ssh-keygen -t ed25519 -C test`.
    private let publicLine = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICcLRx+LGXIadKIOj7r6Bozxy94ToXeS5WJlYHkyXfcq test"
    private let rawPublicHex = "270b471f8b19721a74a20e8fbafa068cf1cbde13a17792e562656079325df72a"
    private let fingerprint = "SHA256:lneuu2TSP899u2jLkWEzd2ugSRRF1vSOEh7BWF23V5Q"

    private var rawPublic: Data {
        var data = Data()
        var hex = rawPublicHex[...]
        while !hex.isEmpty {
            data.append(UInt8(hex.prefix(2), radix: 16)!)
            hex = hex.dropFirst(2)
        }
        return data
    }

    func testPublicKeyBlobMatchesSSHKeygen() {
        let blob = OpenSSH.publicKeyBlob(ed25519: rawPublic)
        XCTAssertEqual("ssh-ed25519 \(blob.base64EncodedString()) test", publicLine)
    }

    func testFingerprintMatchesSSHKeygen() {
        XCTAssertEqual(OpenSSH.fingerprint(blob: OpenSSH.publicKeyBlob(ed25519: rawPublic)), fingerprint)
        XCTAssertEqual(OpenSSH.fingerprint(openSSHPublicKey: publicLine), fingerprint)
    }
}

final class KnownHostsTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("known_hosts.json")
    }

    private let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICcLRx+LGXIadKIOj7r6Bozxy94ToXeS5WJlYHkyXfcq"
    private let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    func testTrustOnFirstUse() {
        let store = KnownHosts(url: url)
        guard case .unknown = store.check(endpoint: "mac.local:22", key: keyA) else {
            return XCTFail("expected unknown host")
        }

        store.trust(endpoint: "mac.local:22", key: keyA + " comment")
        XCTAssertEqual(store.check(endpoint: "mac.local:22", key: keyA), .trusted)

        // Persisted across instances.
        XCTAssertEqual(KnownHosts(url: url).check(endpoint: "mac.local:22", key: keyA), .trusted)
    }

    func testChangedKeyIsAMismatch() {
        let store = KnownHosts(url: url)
        store.trust(endpoint: "mac.local:22", key: keyA)
        guard case .mismatch = store.check(endpoint: "mac.local:22", key: keyB) else {
            return XCTFail("a changed host key must not be trusted")
        }

        store.forget(endpoint: "mac.local:22")
        guard case .unknown = store.check(endpoint: "mac.local:22", key: keyB) else {
            return XCTFail("expected unknown after forget")
        }
    }

    func testKeysAreScopedToPort() {
        let store = KnownHosts(url: url)
        store.trust(endpoint: "mac.local:22", key: keyA)
        guard case .unknown = store.check(endpoint: "mac.local:2222", key: keyA) else {
            return XCTFail("expected a different port to be unknown")
        }
    }
}

final class KeyInputTests: XCTestCase {
    func testUsageForCharacters() {
        XCTAssertEqual(KeyInput.usage(for: "a"), 0x04)
        XCTAssertEqual(KeyInput.usage(for: "C"), 0x06)
        XCTAssertEqual(KeyInput.usage(for: "z"), 0x1D)
        XCTAssertEqual(KeyInput.usage(for: "1"), 0x1E)
        XCTAssertEqual(KeyInput.usage(for: "0"), 0x27)
        XCTAssertEqual(KeyInput.usage(for: "/"), 0x38)
        XCTAssertNil(KeyInput.usage(for: "é"))
    }

    func testKeycodeIncludesKeyboardUsagePage() {
        XCTAssertEqual(KeyInput.keycode(.enter), 0x07_0028)
        XCTAssertEqual(KeyInput.keycode(.escape), 0x07_0029)
    }

    func testEventTextDropsControlAndFunctionKeys() {
        XCTAssertEqual(KeyInput.eventText("a"), "a")
        XCTAssertNil(KeyInput.eventText("\u{03}"))
        XCTAssertNil(KeyInput.eventText("\u{F700}"))
        XCTAssertNil(KeyInput.eventText(""))
    }
}
