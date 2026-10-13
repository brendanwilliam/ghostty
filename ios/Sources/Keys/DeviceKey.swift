import CryptoKit
import Foundation
import UIKit

/// The Ed25519 key this device uses to authenticate to SSH servers.
/// Generated on first use and stored in the Keychain; the private key
/// never leaves the device. Users authorize it by adding the public key
/// to `~/.ssh/authorized_keys` on the server.
enum DeviceKey {
    private static let account = "device-ed25519"

    /// Load the device key, generating and storing one if needed.
    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        if let raw = try Keychain.read(account) {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
        }
        let key = Curve25519.Signing.PrivateKey()
        try Keychain.write(key.rawRepresentation, for: account)
        return key
    }

    /// Replace the device key. Servers that trusted the old key will no
    /// longer accept this device until the new public key is added.
    static func regenerate() throws -> Curve25519.Signing.PrivateKey {
        try Keychain.delete(account)
        return try loadOrCreate()
    }

    /// The public key as a single `authorized_keys` line.
    static func authorizedKeysLine(for key: Curve25519.Signing.PrivateKey, comment: String) -> String {
        let blob = OpenSSH.publicKeyBlob(ed25519: key.publicKey.rawRepresentation)
        return "ssh-ed25519 \(blob.base64EncodedString()) \(comment)"
    }

    /// SHA256 fingerprint in OpenSSH's format, for display.
    static func fingerprint(for key: Curve25519.Signing.PrivateKey) -> String {
        OpenSSH.fingerprint(blob: OpenSSH.publicKeyBlob(ed25519: key.publicKey.rawRepresentation))
    }

    static var defaultComment: String {
        let name = UIDevice.current.name
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return "ghostty-ios@\(name.isEmpty ? "device" : name)"
    }
}

/// OpenSSH wire-format helpers.
enum OpenSSH {
    /// Encode an SSH "string": a big-endian uint32 length then the bytes.
    static func string(_ bytes: Data) -> Data {
        var length = UInt32(bytes.count).bigEndian
        var out = Data(bytes: &length, count: 4)
        out.append(bytes)
        return out
    }

    /// The public key blob for an Ed25519 key (RFC 8709).
    static func publicKeyBlob(ed25519 raw: Data) -> Data {
        string(Data("ssh-ed25519".utf8)) + string(raw)
    }

    /// `SHA256:<unpadded base64>` like `ssh-keygen -l`.
    static func fingerprint(blob: Data) -> String {
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    /// Fingerprint of a key in `authorized_keys`/`known_hosts` form
    /// (`<type> <base64> [comment]`).
    static func fingerprint(openSSHPublicKey: String) -> String? {
        let parts = openSSHPublicKey.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return nil }
        return fingerprint(blob: blob)
    }
}
