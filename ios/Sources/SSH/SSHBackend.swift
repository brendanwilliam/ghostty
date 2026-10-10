import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// Errors surfaced to the user when an SSH session can't be established.
enum SSHSessionError: LocalizedError {
    case hostKeyRejected
    case hostKeyMismatch(expected: String, presented: String)
    case authenticationFailed

    var errorDescription: String? {
        switch self {
        case .hostKeyRejected:
            return "Host key was not trusted"
        case .hostKeyMismatch(let expected, let presented):
            return """
            HOST KEY CHANGED. Expected \(expected) but the server presented \(presented). \
            This could mean someone is intercepting the connection. If the server was \
            reinstalled, forget its key in host settings and reconnect.
            """
        case .authenticationFailed:
            return "Authentication failed"
        }
    }
}

/// Credentials offered to the server, in order: the device key, then
/// the password (if provided).
struct SSHCredentials: Sendable {
    var username: String
    var deviceKey: Curve25519.Signing.PrivateKey?
    var password: String?
}

/// A `TerminalBackend` that runs an interactive shell over SSH.
final class SSHBackend: TerminalBackend, @unchecked Sendable {
    let events: AsyncStream<TerminalBackendEvent>
    private let eventContinuation: AsyncStream<TerminalBackendEvent>.Continuation

    private let input: AsyncStream<Data>
    private let inputContinuation: AsyncStream<Data>.Continuation
    private let resizes: AsyncStream<TerminalSize>
    private let resizeContinuation: AsyncStream<TerminalSize>.Continuation

    private let host: Host
    private let credentials: SSHCredentials
    private let approveUnknownHostKey: @Sendable (String) async -> Bool

    private let lock = NSLock()
    private var client: SSHClient?
    private var closed = false

    /// - Parameter approveUnknownHostKey: Called with the server's key
    ///   fingerprint the first time we connect to a host. Return true to
    ///   trust and remember it.
    init(
        host: Host,
        credentials: SSHCredentials,
        approveUnknownHostKey: @escaping @Sendable (String) async -> Bool
    ) {
        self.host = host
        self.credentials = credentials
        self.approveUnknownHostKey = approveUnknownHostKey
        (events, eventContinuation) = AsyncStream.makeStream()
        (input, inputContinuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (resizes, resizeContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func start(size: TerminalSize) async throws {
        defer { eventContinuation.finish() }

        let validator = TOFUHostKeyValidator(
            endpoint: host.endpoint,
            approve: approveUnknownHostKey)

        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: host.hostname,
                port: host.port,
                authenticationMethod: .custom(KeyThenPasswordAuth(credentials: credentials)),
                hostKeyValidator: .custom(validator),
                reconnect: .never,
                connectTimeout: .seconds(15))
        } catch {
            if let hostKeyError = validator.failure { throw hostKeyError }
            if case SSHClientError.allAuthenticationOptionsFailed = error {
                throw SSHSessionError.authenticationFailed
            }
            if error is AuthenticationFailed {
                throw SSHSessionError.authenticationFailed
            }
            throw error
        }

        let shouldClose: Bool = lock.withLock {
            self.client = client
            return closed
        }
        if shouldClose {
            try? await client.close()
            return
        }

        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: host.term,
            terminalCharacterWidth: size.columns,
            terminalRowHeight: size.rows,
            terminalPixelWidth: size.widthPixels,
            terminalPixelHeight: size.heightPixels,
            terminalModes: SSHTerminalModes([:]))

        var exitCode: Int32? = 0
        let outputFinished = ManagedFlag()
        do {
            try await client.withPTY(request) { inbound, outbound in
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [input] in
                        for await data in input {
                            try await outbound.write(ByteBuffer(bytes: data))
                        }
                    }
                    group.addTask { [resizes] in
                        for await size in resizes {
                            try await outbound.changeSize(
                                cols: size.columns,
                                rows: size.rows,
                                pixelWidth: size.widthPixels,
                                pixelHeight: size.heightPixels)
                        }
                    }

                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.eventContinuation.yield(.output(Data(buffer: buffer)))
                        }
                    }
                    outputFinished.set()
                    group.cancelAll()
                }
            }
        } catch let failed as SSHClient.CommandFailed {
            exitCode = Int32(truncatingIfNeeded: failed.exitCode)
        } catch let error as ChannelError where outputFinished.isSet {
            // The server closed the channel after the shell exited, so
            // Citadel's own close fails. That's a normal end of session.
            _ = error
        } catch {
            exitCode = nil
            eventContinuation.yield(.exited(code: nil, message: "Disconnected: \(error.localizedDescription)"))
            try? await client.close()
            return
        }

        try? await client.close()
        eventContinuation.yield(.exited(code: exitCode, message: "Connection to \(host.displayName) closed"))
    }

    func write(_ data: Data) {
        inputContinuation.yield(data)
    }

    func resize(_ size: TerminalSize) {
        resizeContinuation.yield(size)
    }

    func close() {
        let client: SSHClient? = lock.withLock {
            closed = true
            return self.client
        }
        inputContinuation.finish()
        resizeContinuation.finish()
        if let client {
            Task { try? await client.close() }
        }
    }
}

/// A thread-safe one-way flag.
private final class ManagedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// Offers the device key first, then a password if one was provided.
private final class KeyThenPasswordAuth: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let credentials: SSHCredentials
    private var offeredKey = false
    private var offeredPassword = false

    init(credentials: SSHCredentials) {
        self.credentials = credentials
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        if !offeredKey, let key = credentials.deviceKey, availableMethods.contains(.publicKey) {
            offeredKey = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: NIOSSHPrivateKey(ed25519Key: key)))))
            return
        }

        if !offeredPassword, let password = credentials.password, availableMethods.contains(.password) {
            offeredPassword = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(
                username: credentials.username,
                serviceName: "",
                offer: .password(.init(password: password))))
            return
        }

        nextChallengePromise.succeed(nil)
    }
}

/// Validates host keys against `KnownHosts`, asking the user to approve
/// keys for hosts we haven't seen and hard-failing on changed keys.
private final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let endpoint: String
    private let approve: @Sendable (String) async -> Bool
    private let lock = NSLock()
    private var _failure: SSHSessionError?

    var failure: SSHSessionError? { lock.withLock { _failure } }

    init(endpoint: String, approve: @escaping @Sendable (String) async -> Bool) {
        self.endpoint = endpoint
        self.approve = approve
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        switch KnownHosts.shared.check(endpoint: endpoint, key: key) {
        case .trusted:
            validationCompletePromise.succeed(())

        case .unknown(let fingerprint):
            let endpoint = endpoint
            let approve = approve
            Task {
                if await approve(fingerprint) {
                    KnownHosts.shared.trust(endpoint: endpoint, key: key)
                    validationCompletePromise.succeed(())
                } else {
                    self.fail(.hostKeyRejected, validationCompletePromise)
                }
            }

        case .mismatch(let expected, let presented):
            fail(.hostKeyMismatch(expected: expected, presented: presented), validationCompletePromise)
        }
    }

    private func fail(_ error: SSHSessionError, _ promise: EventLoopPromise<Void>) {
        lock.withLock { _failure = error }
        promise.fail(error)
    }
}
