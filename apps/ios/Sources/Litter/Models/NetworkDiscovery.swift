import Foundation
import Network
import UIKit

private let codexDiscoveryPorts: [UInt16] = [8390, 4222]

private struct DiscoveryCandidate: Hashable {
    let ip: String
    let name: String?
    let source: ServerSource
    let codexPortHint: UInt16?
}

private struct CandidateReachability: Sendable {
    let candidate: DiscoveryCandidate
    let codexPort: UInt16?
}

@MainActor
final class NetworkDiscovery: ObservableObject {
    @Published var servers: [DiscoveredServer] = []
    @Published var isScanning = false

    private var scanTask: Task<Void, Never>?
    private var activeScanID = UUID()

    func startScanning() {
        stopScanning()
        let scanID = UUID()
        activeScanID = scanID

        servers = []
        isScanning = true
        if OnDeviceCodexFeature.isEnabled {
            servers.append(DiscoveredServer(
                id: "local",
                name: UIDevice.current.name,
                hostname: "127.0.0.1",
                port: nil,
                source: .local,
                hasCodexServer: true
            ))
        }

        scanTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.discoverNetworkServersInBackground(scanID: scanID)
        }
    }

    func stopScanning() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    // MARK: - Discovery

    private nonisolated func discoverNetworkServersInBackground(scanID: UUID) async {
        defer {
            Task { @MainActor [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.isScanning = false
            }
        }
        guard !Task.isCancelled else { return }
        let isCurrent = await MainActor.run { [weak self] in
            guard let self else { return false }
            return self.activeScanID == scanID
        }
        guard isCurrent else { return }

        let localIPv4 = Self.localIPv4Address()?.0
        var cumulativeCandidates: [DiscoveryCandidate] = []

        // Run two passes to reduce discovery misses from transient Bonjour/Tailscale timing.
        for pass in 0..<2 {
            let bonjourTimeout: TimeInterval = pass == 0 ? 5.0 : 3.0
            let tailscaleTimeout: TimeInterval = pass == 0 ? 2.5 : 1.5
            let probeTimeout: TimeInterval = pass == 0 ? 1.0 : 1.4
            let probeAttempts = pass == 0 ? 2 : 3

            async let bonjourCandidates = Self.discoverBonjourCandidates(timeout: bonjourTimeout)
            async let tailscaleCandidates = Self.discoverTailscaleSSHCandidates(timeout: tailscaleTimeout)
            let mergedPass = Self.mergeCandidates(
                Array((await bonjourCandidates) + (await tailscaleCandidates)),
                excluding: localIPv4
            )
            cumulativeCandidates = Self.mergeCandidates(cumulativeCandidates + mergedPass, excluding: localIPv4)
            let reachable = await Self.filterCandidatesWithOpenServices(
                cumulativeCandidates,
                timeout: probeTimeout,
                attempts: probeAttempts
            )
            guard !Task.isCancelled else { return }
            let shouldApply = await MainActor.run { [weak self] in
                guard let self else { return false }
                return self.activeScanID == scanID
            }
            guard shouldApply else { return }
            await MainActor.run { [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.applyReachabilityResults(reachable)
            }

            if pass == 0 {
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func applyReachabilityResults(_ reachable: [CandidateReachability]) {
        for state in reachable.sorted(by: { Self.candidateSortOrder(lhs: $0.candidate, rhs: $1.candidate) }) {
            let candidate = state.candidate
            let id = "network-\(candidate.ip)"
            let discovered = DiscoveredServer(
                id: id,
                name: candidate.name ?? candidate.ip,
                hostname: candidate.ip,
                port: state.codexPort,
                source: candidate.source,
                hasCodexServer: state.codexPort != nil
            )

            if let index = servers.firstIndex(where: { $0.id == id }) {
                // Prefer the candidate with better source rank or codex endpoint.
                let existing = servers[index]
                let betterSource = Self.sourceRank(candidate.source) < Self.sourceRank(existing.source)
                let hasCodexUpgrade = discovered.hasCodexServer && !existing.hasCodexServer
                let betterCodexPort = discovered.hasCodexServer && existing.hasCodexServer && discovered.port != existing.port
                let betterName = (existing.name == existing.hostname) && (discovered.name != discovered.hostname)
                if betterSource || hasCodexUpgrade || betterCodexPort || betterName {
                    servers[index] = discovered
                }
            } else {
                servers.append(discovered)
            }
        }
    }

    nonisolated private static func candidateSortOrder(lhs: DiscoveryCandidate, rhs: DiscoveryCandidate) -> Bool {
        let leftRank = sourceRank(lhs.source)
        let rightRank = sourceRank(rhs.source)
        if leftRank != rightRank {
            return leftRank < rightRank
        }
        let leftName = lhs.name ?? lhs.ip
        let rightName = rhs.name ?? rhs.ip
        return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
    }

    nonisolated private static func sourceRank(_ source: ServerSource) -> Int {
        switch source {
        case .bonjour: return 0
        case .tailscale: return 1
        default: return 2
        }
    }

    nonisolated private static func mergeCandidates(
        _ candidates: [DiscoveryCandidate],
        excluding localIPv4: String?
    ) -> [DiscoveryCandidate] {
        var merged: [String: DiscoveryCandidate] = [:]
        for candidate in candidates {
            guard isIPv4Address(candidate.ip), candidate.ip != localIPv4 else { continue }
            if let existing = merged[candidate.ip] {
                if sourceRank(candidate.source) < sourceRank(existing.source) {
                    merged[candidate.ip] = candidate
                } else if existing.name == nil, candidate.name != nil {
                    merged[candidate.ip] = candidate
                } else if existing.codexPortHint == nil, candidate.codexPortHint != nil {
                    merged[candidate.ip] = candidate
                }
            } else {
                merged[candidate.ip] = candidate
            }
        }
        return Array(merged.values)
    }

    nonisolated private static func isPortOpenOnce(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.setTrue() {
                        connection.cancel()
                        cont.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if resumed.setTrue() {
                        connection.cancel()
                        cont.resume(returning: false)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if resumed.setTrue() {
                    connection.cancel()
                    cont.resume(returning: false)
                }
            }
        }
    }

    nonisolated private static func isPortOpen(
        host: String,
        port: UInt16,
        timeout: TimeInterval,
        attempts: Int
    ) async -> Bool {
        let retries = max(1, attempts)
        for attempt in 0..<retries {
            if await isPortOpenOnce(host: host, port: port, timeout: timeout) {
                return true
            }
            if attempt < retries - 1 {
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
        return false
    }

    nonisolated private static func filterCandidatesWithOpenServices(
        _ candidates: [DiscoveryCandidate],
        timeout: TimeInterval,
        attempts: Int
    ) async -> [CandidateReachability] {
        await withTaskGroup(of: CandidateReachability?.self) { group in
            for candidate in candidates {
                group.addTask {
                    let hasSSH = await isPortOpen(
                        host: candidate.ip,
                        port: 22,
                        timeout: timeout,
                        attempts: attempts
                    )
                    var codexPort: UInt16?
                    if let hint = candidate.codexPortHint {
                        if await isPortOpen(
                            host: candidate.ip,
                            port: hint,
                            timeout: timeout,
                            attempts: attempts
                        ) {
                            codexPort = hint
                        }
                    }
                    for port in codexDiscoveryPorts {
                        if codexPort != nil { break }
                        if await isPortOpen(
                            host: candidate.ip,
                            port: port,
                            timeout: timeout,
                            attempts: attempts
                        ) {
                            codexPort = port
                            break
                        }
                    }

                    // Bonjour records are already service-level signals; keep them even when probes flake.
                    let includeOnBonjourSignal = candidate.source == .bonjour
                    guard hasSSH || codexPort != nil || includeOnBonjourSignal else {
                        return nil
                    }
                    return CandidateReachability(candidate: candidate, codexPort: codexPort)
                }
            }
            var reachable: [CandidateReachability] = []
            for await state in group {
                if let state {
                    reachable.append(state)
                }
            }
            return reachable
        }
    }

    private static func discoverBonjourCandidates(timeout: TimeInterval) async -> [DiscoveryCandidate] {
        async let ssh = discoverBonjourCandidates(
            serviceType: "_ssh._tcp.",
            timeout: timeout,
            codexService: false
        )
        async let codex = discoverBonjourCandidates(
            serviceType: "_codex._tcp.",
            timeout: timeout,
            codexService: true
        )
        return mergeCandidates(Array((await ssh) + (await codex)), excluding: nil)
    }

    private static func discoverBonjourCandidates(
        serviceType: String,
        timeout: TimeInterval,
        codexService: Bool
    ) async -> [DiscoveryCandidate] {
        let browser = BonjourServiceDiscoverer(serviceType: serviceType, codexService: codexService)
        return await browser.discover(timeout: timeout)
    }

    nonisolated private static func discoverTailscaleSSHCandidates(timeout: TimeInterval) async -> [DiscoveryCandidate] {
        guard let url = URL(string: "http://100.100.100.100/localapi/v0/status") else {
            return []
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        for attempt in 0..<2 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    continue
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let peers = json["Peer"] as? [String: Any] else {
                    continue
                }

                var candidates: [DiscoveryCandidate] = []
                for peer in peers.values {
                    guard let peerDict = peer as? [String: Any] else { continue }
                    if let online = peerDict["Online"] as? Bool, !online {
                        continue
                    }
                    let hostName = cleanedHostName(peerDict["HostName"] as? String)
                        ?? cleanedHostName(peerDict["DNSName"] as? String)
                    let ips = (peerDict["TailscaleIPs"] as? [String]) ?? []
                    guard let ipv4 = ips.first(where: { isIPv4Address($0) }) else { continue }
                    candidates.append(DiscoveryCandidate(ip: ipv4, name: hostName, source: .tailscale, codexPortHint: nil))
                }
                return candidates
            } catch {
                if attempt == 0 {
                    try? await Task.sleep(for: .milliseconds(180))
                }
            }
        }
        return []
    }

    nonisolated private static func cleanedHostName(_ value: String?) -> String? {
        guard var value, !value.isEmpty else { return nil }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        if value.hasSuffix(".local") {
            value = String(value.dropLast(6))
        }
        return value.isEmpty ? nil : value
    }

    nonisolated fileprivate static func ipv4Address(fromSockaddrData data: Data) -> String? {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return nil }
            let sockaddrPtr = base.assumingMemoryBound(to: sockaddr.self)
            guard sockaddrPtr.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
            let sinPtr = base.assumingMemoryBound(to: sockaddr_in.self)
            var addr = sinPtr.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return String(cString: buffer)
        }
    }

    nonisolated private static func isIPv4Address(_ value: String) -> Bool {
        var addr = in_addr()
        return value.withCString { cstr in
            inet_pton(AF_INET, cstr, &addr) == 1
        }
    }

    nonisolated private static func localIPv4Address() -> (String, String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard ptr.pointee.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            _ = ptr.pointee.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                inet_ntop(AF_INET, &sin.pointee.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            return (String(cString: buf), name)
        }
        return nil
    }
}

@MainActor
private final class BonjourServiceDiscoverer: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private struct ServiceRecord {
        let name: String
        let codexPortHint: UInt16?
    }

    private let serviceType: String
    private let codexService: Bool
    private let browser = NetServiceBrowser()
    private var services: [NetService] = []
    private var results: [String: ServiceRecord] = [:]
    private var pendingServices: Set<ObjectIdentifier> = []
    private var continuation: CheckedContinuation<[DiscoveryCandidate], Never>?
    private var timeoutTask: Task<Void, Never>?
    private var resolveDrainTask: Task<Void, Never>?
    private var isFinished = false
    private var requestedStop = false

    init(serviceType: String, codexService: Bool) {
        self.serviceType = serviceType
        self.codexService = codexService
    }

    func discover(timeout: TimeInterval) async -> [DiscoveryCandidate] {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            browser.delegate = self
            browser.searchForServices(ofType: serviceType, inDomain: "local.")
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                let nanos = UInt64(max(timeout, 0.25) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                self.stopAndDrain()
            }
        }
    }

    private func stopAndDrain() {
        guard !requestedStop else { return }
        requestedStop = true
        browser.stop()
        if pendingServices.isEmpty {
            finish()
            return
        }
        resolveDrainTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(900))
            self.finish()
        }
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        timeoutTask?.cancel()
        resolveDrainTask?.cancel()
        timeoutTask = nil
        resolveDrainTask = nil
        if !requestedStop {
            browser.stop()
        }
        for service in services {
            service.stop()
            service.delegate = nil
        }
        let discovered = results.map {
            DiscoveryCandidate(ip: $0.key, name: $0.value.name, source: .bonjour, codexPortHint: $0.value.codexPortHint)
        }
        continuation?.resume(returning: discovered)
        continuation = nil
    }

    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        finish()
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        if requestedStop, pendingServices.isEmpty {
            finish()
        } else if !requestedStop {
            finish()
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard !isFinished else { return }
        services.append(service)
        pendingServices.insert(ObjectIdentifier(service))
        service.delegate = self
        service.resolve(withTimeout: 2.5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        pendingServices.remove(ObjectIdentifier(sender))
        guard let addresses = sender.addresses else { return }
        let codexPort: UInt16? = {
            guard codexService else { return nil }
            guard sender.port > 0, sender.port <= Int(UInt16.max) else { return 8390 }
            return UInt16(sender.port)
        }()
        for address in addresses {
            guard let ip = NetworkDiscovery.ipv4Address(fromSockaddrData: address) else { continue }
            results[ip] = ServiceRecord(name: sender.name, codexPortHint: codexPort)
            break
        }
        if requestedStop, pendingServices.isEmpty {
            finish()
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        pendingServices.remove(ObjectIdentifier(sender))
        if requestedStop, pendingServices.isEmpty {
            finish()
        }
    }
}

/// Thread-safe flag for one-shot continuation resumption.
private final class LockedFlag: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()
    /// Returns `true` the first time it's called; `false` thereafter.
    func setTrue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
