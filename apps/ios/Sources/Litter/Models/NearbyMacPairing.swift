#if !targetEnvironment(macCatalyst)
import Foundation
import NearbyInteraction
import Observation
import UIKit

/// iOS-only first-launch onboarding: browse for a nearby `_litter-pair._tcp.`
/// service, open a WebSocket pair session via Rust, run NISession against
/// the Mac's NI discovery token, and save a SavedServer on accept. Runs
/// only when SavedServerStore has no user-remembered servers. The class
/// is single-shot: each attempt runs a fresh instance via `start()`.
///
/// Wiring: platform (Swift) owns Bonjour browse + NISession; Rust owns the
/// pair protocol state machine and reports transitions through a polled
/// event stream. We re-expose state as an `@Observable` so SwiftUI can
/// render the onboarding view directly.
@MainActor
@Observable
final class NearbyMacPairing: NSObject {
    static let shared = NearbyMacPairing()

    /// Bonjour service type we advertise on and browse for pairing.
    private static let pairServiceType = "_litter-pair._tcp."
    /// How long to browse for a pair service before showing a "couldn't
    /// find" fallback UI.
    private static let browseTimeout: TimeInterval = 20
    /// Distance threshold at which we auto-send pair_request. Chosen for
    /// BLE fallback (no U1/U2 on current Macs), not UWB precision.
    private static let pairDistanceThreshold: Float = 1.0
    /// Upper bound on the entire onboarding flow before we treat it as a
    /// timeout and let the user fall back to manual discovery.
    private static let flowTimeout: TimeInterval = 60

    // MARK: - Public observable state

    var state: NearbyMacPairingState = .searching
    var discoveredMacName: String?
    var lastDistance: Float?
    var isRunning: Bool = false

    /// Set when pair_accept arrives. Consumed by `LitterApp`/ContentView to
    /// open a connection and dismiss onboarding.
    var completedServer: SavedServer?

    // MARK: - Internals

    private let appClient = AppClient()
    private var browser: BonjourServiceDiscoverer?
    private var browseTask: Task<Void, Never>?
    private var flowTimeoutTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var pairClient: PairClientHandle?
    private var niSession: NISession?
    private var niDelegateBox: NIDelegateBox?
    private var pendingMacDiscoveryToken: NIDiscoveryToken?
    private var didSendPairRequest = false
    private var deviceName: String = UIDevice.current.name
    private weak var appModel: AppModel?

    override private init() {
        super.init()
    }

    /// Start the onboarding flow. Idempotent while running. No-op if the
    /// user already has remembered servers.
    func startIfNeeded(appModel: AppModel) {
        guard !isRunning else { return }
        guard SavedServerStore.rememberedServers().isEmpty else {
            LLog.info("pair", "skipping onboarding, user already has remembered servers")
            return
        }
        guard NISession.isSupported else {
            LLog.info("pair", "NISession unsupported on this device; skipping onboarding")
            return
        }
        self.appModel = appModel
        isRunning = true
        state = .searching
        discoveredMacName = nil
        lastDistance = nil
        completedServer = nil
        didSendPairRequest = false
        startFlowTimeout()
        startBrowse()
    }

    /// User tapped "Skip" / "Set up manually" — stop everything and let
    /// ContentView dismiss the onboarding sheet.
    func cancel() {
        isRunning = false
        teardown()
    }

    /// Retry after a rejected or failed attempt. Same entry point as
    /// `startIfNeeded` but without the remembered-server check.
    func retry() {
        guard appModel != nil else { return }
        teardown()
        state = .searching
        discoveredMacName = nil
        lastDistance = nil
        completedServer = nil
        didSendPairRequest = false
        isRunning = true
        startFlowTimeout()
        startBrowse()
    }

    // MARK: - Browse

    private func startBrowse() {
        let browser = BonjourServiceDiscoverer(serviceType: Self.pairServiceType)
        self.browser = browser
        browseTask = Task { @MainActor [weak self] in
            let seeds = await browser.discover(timeout: Self.browseTimeout)
            guard let self, self.isRunning else { return }
            self.browser = nil
            // Pick the first responsive pair service. The Mac only
            // advertises a single service per process.
            guard let pick = seeds.first(where: { $0.port != nil }) else {
                LLog.info("pair", "no pair service seen within timeout")
                self.state = .failed
                return
            }
            self.discoveredMacName = pick.name
            LLog.info(
                "pair",
                "pair service discovered",
                fields: [
                    "name": pick.name,
                    "host": pick.host,
                    "port": Int(pick.port ?? 0)
                ]
            )
            self.connectAndHandshake(host: pick.host, port: pick.port ?? 0)
        }
    }

    // MARK: - WS connect + NI exchange

    private func connectAndHandshake(host: String, port: UInt16) {
        state = .connecting
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            do {
                // Start NISession on this side first so we have a discovery
                // token to ship in the hello.
                let session = NISession()
                let delegate = NIDelegateBox { [weak self] distance in
                    Task { @MainActor in self?.handleDistanceUpdate(distance) }
                } invalidated: { [weak self] err in
                    Task { @MainActor in self?.handleNIInvalidated(err) }
                }
                session.delegate = delegate
                self.niDelegateBox = delegate
                self.niSession = session

                guard let token = session.discoveryToken else {
                    LLog.warn("pair", "NISession produced no discovery token")
                    self.state = .failed
                    return
                }
                let tokenB64 = try encodeDiscoveryToken(token)

                let client = try await self.appClient.pairFromIphone(
                    host: host,
                    port: port,
                    deviceName: self.deviceName,
                    niDiscoveryTokenB64: tokenB64
                )
                // User may have cancelled while we were awaiting the
                // connection; drop the just-opened client on the floor
                // instead of leaving it orphaned.
                guard self.isRunning else {
                    Task { await client.stop() }
                    return
                }
                self.pairClient = client
                self.state = .handshaking
                self.startEventPoll()
            } catch {
                LLog.error("pair", "pair_from_iphone failed", error: error)
                self.state = .failed
            }
        }
    }

    private func startEventPoll() {
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while let self, self.isRunning, let client = self.pairClient {
                if let event = await client.pollEvent() {
                    self.handle(event: event)
                } else {
                    // No event — sleep 80ms to avoid spinning.
                    try? await Task.sleep(nanoseconds: 80_000_000)
                }
            }
        }
    }

    private func handle(event: PairEvent) {
        switch event {
        case let .clientPeerAccepted(niDiscoveryTokenB64):
            handleMacNIToken(b64: niDiscoveryTokenB64)
        case let .clientPairAccepted(codexWsUrl, lanIp):
            handlePairAccepted(codexWsUrl: codexWsUrl, lanIp: lanIp)
        case .peerRejected:
            state = .rejected
            isRunning = false
        case let .disconnected(reason):
            LLog.info("pair", "disconnected", fields: ["reason": reason])
            if state != .paired, state != .rejected, state != .failed {
                state = .failed
                isRunning = false
            }
        case .hostPeerConnected, .hostPairRequest, .distanceUpdate:
            // Host-side events; iPhone ignores.
            break
        }
    }

    private func handleMacNIToken(b64: String) {
        guard let session = niSession else { return }
        guard let tokenData = Data(base64Encoded: b64), !tokenData.isEmpty,
              let macToken = decodeDiscoveryToken(tokenData)
        else {
            LLog.warn("pair", "mac NI discovery token was empty or undecodable")
            state = .failed
            return
        }
        pendingMacDiscoveryToken = macToken
        let config = NINearbyPeerConfiguration(peerToken: macToken)
        session.run(config)
        LLog.info("pair", "NISession started against mac token")
    }

    private func handleDistanceUpdate(_ distance: Float?) {
        lastDistance = distance
        if let distance {
            // Fire-and-forget distance ping for the Mac UI affordance.
            try? pairClient?.submitNiDistance(distanceM: distance)
            if !didSendPairRequest, distance <= Self.pairDistanceThreshold {
                didSendPairRequest = true
                state = .awaitingConfirm
                LLog.info(
                    "pair",
                    "distance threshold reached",
                    fields: ["distance_m": distance]
                )
                try? pairClient?.submitPairRequest(distanceM: distance)
            }
        }
    }

    private func handleNIInvalidated(_ error: Error) {
        LLog.warn("pair", "NISession invalidated", fields: ["error": String(describing: error)])
        // Without NI ranging we can't get to the pair threshold
        // automatically; surface a failure so the user can fall back to
        // manual discovery.
        if !didSendPairRequest {
            state = .failed
        }
    }

    private func handlePairAccepted(codexWsUrl: String, lanIp: String) {
        state = .paired
        LLog.info(
            "pair",
            "pair accepted",
            fields: ["codex_ws_url": codexWsUrl, "lan_ip": lanIp]
        )
        let port = Self.extractPort(fromWebSocketURL: codexWsUrl) ?? 8390
        let nameOut = discoveredMacName ?? lanIp
        let saved = SavedServer(
            id: "mac-pair-\(lanIp)",
            name: nameOut,
            hostname: lanIp,
            port: port,
            codexPorts: [port],
            sshPort: nil,
            source: .bonjour,
            hasCodexServer: true,
            wakeMAC: nil,
            preferredConnectionMode: .directCodex,
            preferredCodexPort: port,
            sshPortForwardingEnabled: nil,
            websocketURL: codexWsUrl,
            rememberedByUser: true
        )
        var list = SavedServerStore.load()
        list.removeAll { $0.id == saved.id || $0.hostname == saved.hostname }
        list.append(saved)
        SavedServerStore.save(list)
        completedServer = saved
        isRunning = false
        teardown()
    }

    private static func extractPort(fromWebSocketURL url: String) -> UInt16? {
        guard let parsed = URL(string: url), let port = parsed.port,
              port > 0, port <= Int(UInt16.max) else {
            return nil
        }
        return UInt16(port)
    }

    // MARK: - Timeout + teardown

    private func startFlowTimeout() {
        flowTimeoutTask?.cancel()
        flowTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.flowTimeout * 1_000_000_000))
            guard let self, self.isRunning else { return }
            if self.state == .searching || self.state == .connecting
                || self.state == .handshaking || self.state == .awaitingConfirm {
                LLog.info("pair", "flow timeout reached")
                self.state = .failed
            }
        }
    }

    private func teardown() {
        browseTask?.cancel()
        browseTask = nil
        browser = nil
        flowTimeoutTask?.cancel()
        flowTimeoutTask = nil
        pollTask?.cancel()
        pollTask = nil
        if let client = pairClient {
            pairClient = nil
            Task { await client.stop() }
        }
        if let session = niSession {
            session.invalidate()
            niSession = nil
        }
        niDelegateBox = nil
        pendingMacDiscoveryToken = nil
    }
}

// MARK: - NI token coding helpers

private enum NICodingError: Error {
    case archiveFailed
}

private func encodeDiscoveryToken(_ token: NIDiscoveryToken) throws -> String {
    let data = try NSKeyedArchiver.archivedData(
        withRootObject: token,
        requiringSecureCoding: true
    )
    return data.base64EncodedString()
}

private func decodeDiscoveryToken(_ data: Data) -> NIDiscoveryToken? {
    return try? NSKeyedUnarchiver.unarchivedObject(
        ofClass: NIDiscoveryToken.self,
        from: data
    )
}

// MARK: - NI delegate shim

/// Minimal NSObject delegate box so `NearbyMacPairing` (an `Observable`
/// class) can stay non-NSObject. Delegates the two callbacks we care
/// about: `didUpdate nearbyObjects` → distance updates, and session
/// invalidation → teardown hook.
private final class NIDelegateBox: NSObject, NISessionDelegate, @unchecked Sendable {
    private let onDistance: (Float?) -> Void
    private let onInvalidated: (Error) -> Void

    init(
        onDistance: @escaping (Float?) -> Void,
        invalidated: @escaping (Error) -> Void
    ) {
        self.onDistance = onDistance
        self.onInvalidated = invalidated
    }

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        // We paired with exactly one peer (the Mac) so the first object is
        // ours.
        let distance = nearbyObjects.first?.distance
        onDistance(distance)
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        onInvalidated(error)
    }

    func sessionWasSuspended(_ session: NISession) {}
    func sessionSuspensionEnded(_ session: NISession) {}
}
#endif
