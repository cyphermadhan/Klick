import Foundation
import Network
import os

/// Discovers other walkie instances on the local network via Bonjour.
///
/// Advertising is handled by `UDPTransport` — when the transport starts, it
/// publishes its UDP listener under `_walkie._udp.`. This class only *browses*,
/// subscribing the caller to the changing set of peers.
///
/// Peer identity uses the Bonjour service name (typically the device name).
/// Your own service will appear in the browse results; filter it out by
/// matching against the name you used to advertise.
@MainActor
final class BonjourBrowser: ObservableObject {
    @Published private(set) var peers: [PeerInfo] = []
    @Published private(set) var isBrowsing = false
    @Published private(set) var errorMessage: String?

    static let serviceType = "_walkie._udp."

    private var browser: NWBrowser?
    private let log = Logger(subsystem: "com.klick.walkietalkie", category: "BonjourBrowser")

    /// The service name to filter out of results (i.e. this device's own
    /// advertised name). Set by the owner before `start()`.
    var selfName: String?

    func start() {
        guard browser == nil else { return }
        errorMessage = nil

        let descriptor = NWBrowser.Descriptor.bonjour(type: Self.serviceType, domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: descriptor, using: params)

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isBrowsing = true
                    self.log.info("Bonjour browser ready")
                case let .failed(err):
                    self.isBrowsing = false
                    self.errorMessage = err.localizedDescription
                    self.log.error("Bonjour browser failed: \(String(describing: err))")
                case .cancelled:
                    self.isBrowsing = false
                default: break
                }
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                self?.updatePeers(from: results)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        peers = []
    }

    private func updatePeers(from results: Set<NWBrowser.Result>) {
        var next: [PeerInfo] = []
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint else { continue }
            if let selfName, name == selfName { continue }
            next.append(PeerInfo(name: name, endpoint: result.endpoint))
        }
        // Stable order: alphabetical by name.
        peers = next.sorted { $0.name < $1.name }
    }
}
