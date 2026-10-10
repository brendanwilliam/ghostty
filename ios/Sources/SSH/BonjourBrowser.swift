import Foundation
import Network

/// Discovers SSH servers (e.g. Macs with Remote Login enabled) on the
/// local network via Bonjour.
@MainActor
final class BonjourBrowser: ObservableObject {
    struct Service: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let endpoint: NWEndpoint
    }

    @Published private(set) var services: [Service] = []
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_ssh._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let services = results.compactMap { result -> Service? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Service(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in
                self?.services = services.sorted { $0.name < $1.name }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Resolve a discovered service to a hostname (e.g. `My-Mac.local`)
    /// and port.
    static func resolve(_ service: Service) async -> (host: String, port: Int)? {
        guard case .service(let name, let type, let domain, _) = service.endpoint else { return nil }
        let resolver = ServiceResolver(name: name, type: type, domain: domain)
        return await resolver.resolve()
    }
}

/// Resolves a Bonjour service with NetService, which (unlike
/// NWConnection) yields the advertised `.local` hostname rather than an
/// address that may change. All state is touched on the main queue.
private final class ServiceResolver: NSObject, NetServiceDelegate, @unchecked Sendable {
    private let service: NetService
    private var continuation: CheckedContinuation<(host: String, port: Int)?, Never>?

    init(name: String, type: String, domain: String) {
        service = NetService(domain: domain, type: type, name: name)
        super.init()
    }

    func resolve() async -> (host: String, port: Int)? {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                self.continuation = continuation
                self.service.delegate = self
                self.service.resolve(withTimeout: 5)
            }
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return finish(nil) }
        let trimmed = host.hasSuffix(".") ? String(host.dropLast()) : host
        finish((trimmed, sender.port))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        finish(nil)
    }

    private func finish(_ result: (host: String, port: Int)?) {
        service.stop()
        continuation?.resume(returning: result)
        continuation = nil
    }
}
