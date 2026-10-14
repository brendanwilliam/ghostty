import Citadel
import Foundation
import Network
import NIOCore
import NIOTransportServices

/// Something that happened to a connection's network path.
enum RouteEvent: Sendable, Equatable {
    /// The path can (or can no longer) carry traffic, e.g. Wi-Fi dropped.
    case viable(Bool)
    /// A better path appeared (e.g. Wi-Fi after cellular); the connection
    /// still works on the old one.
    case betterPathAvailable
}

/// Makes SSH connections over Network.framework, which (unlike BSD
/// sockets) tells us when the phone's network changes under a connection,
/// and keeps idle connections checked with TCP keepalives so a dead one
/// is noticed in seconds rather than minutes.
enum Transport {
    static let group = NIOTSEventLoopGroup(loopCount: 1)

    /// How long to wait for TCP to connect on one route.
    static let connectTimeout: TimeAmount = .seconds(8)

    /// Connect over `route` and authenticate.
    static func connect(
        route: HostRoute,
        authentication: @escaping @Sendable () -> SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> (SSHClient, AsyncStream<RouteEvent>) {
        let (events, continuation) = AsyncStream<RouteEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.keepaliveInterval = 5
        tcp.keepaliveCount = 3
        let bootstrap = NIOTSConnectionBootstrap(group: group).tcpOptions(tcp)

        var settings = SSHClientSettings(
            host: route.address,
            port: route.port,
            authenticationMethod: authentication,
            hostKeyValidator: hostKeyValidator)
        settings.connectTimeout = connectTimeout

        do {
            let client = try await SSHClient.connect(to: settings, bootstrap: bootstrap) {
                [RouteEventHandler(continuation)]
            }
            return (client, events)
        } catch {
            continuation.finish()
            throw error
        }
    }
}

/// Passes Network.framework's path events on, ahead of SSH.
private final class RouteEventHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    private let continuation: AsyncStream<RouteEvent>.Continuation

    init(_ continuation: AsyncStream<RouteEvent>.Continuation) {
        self.continuation = continuation
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let update as NIOTSNetworkEvents.ViabilityUpdate:
            continuation.yield(.viable(update.isViable))
        case is NIOTSNetworkEvents.BetterPathAvailable:
            continuation.yield(.betterPathAvailable)
        default:
            break
        }
        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        continuation.finish()
    }
}
