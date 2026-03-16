import Foundation
import Network
import Observation
import UIKit

private let codexDiscoveryPorts: [UInt16] = [8390, 4222]

private struct DiscoveryCandidate: Hashable {
    let ip: String
    let name: String?
    let source: ServerSource
    let codexPortHint: UInt16?
}

struct TailscalePeerIdentity: Equatable {
    let ip: String
    let name: String?
}

struct TailscaleAvailability: Equatable, Sendable {
    let appInstalled: Bool
    let likelyActiveTunnel: Bool

    var shouldSurfaceDiscoveryNotice: Bool {
        appInstalled || likelyActiveTunnel
    }

    var logDescription: String {
        "installed=\(appInstalled) likelyActive=\(likelyActiveTunnel)"
    }
}

private struct CandidateReachability: Sendable {
    let candidate: DiscoveryCandidate
    let codexPort: UInt16?
    let sshPort: UInt16?
}

private struct TailscaleInterfaceSnapshot: Sendable {
    struct InterfaceRecord: Sendable {
        let name: String
        let family: String
        let address: String
        let flags: [String]
        let isTailscaleAddress: Bool
    }

    let localWiFiAddress: String?
    let localWiFiInterface: String?
    let activeTunnelInterfaces: [String]
    let tailscaleInterfaces: [String]
    let records: [InterfaceRecord]

    var hasLikelyActiveTailscaleTunnel: Bool {
        !activeTunnelInterfaces.isEmpty && !tailscaleInterfaces.isEmpty
    }

    var logDescription: String {
        let wifiSummary: String
        if let localWiFiInterface, let localWiFiAddress {
            wifiSummary = "\(localWiFiInterface)=\(localWiFiAddress)"
        } else {
            wifiSummary = "none"
        }

        let tunnelSummary = activeTunnelInterfaces.isEmpty
            ? "none"
            : activeTunnelInterfaces.joined(separator: ",")
        let tailscaleSummary = tailscaleInterfaces.isEmpty
            ? "none"
            : tailscaleInterfaces.joined(separator: ",")
        let recordsSummary = records.isEmpty
            ? "none"
            : records.map { record in
                let flags = record.flags.joined(separator: "+")
                return "\(record.name):\(record.family):\(record.address):\(flags)\(record.isTailscaleAddress ? ":tailscale" : "")"
            }.joined(separator: " | ")

        return "wifi=\(wifiSummary) likelyActive=\(hasLikelyActiveTailscaleTunnel) utun=\(tunnelSummary) tailscale=\(tailscaleSummary) records=\(recordsSummary)"
    }
}

private actor TailscaleDiscoveryDiagnostics {
    private(set) var notice: String?

    func markSuccess() {
        notice = nil
    }

    func record(_ notice: String) {
        if self.notice == nil {
            self.notice = notice
        }
    }
}

@MainActor
@Observable
final class NetworkDiscovery {
    var servers: [DiscoveredServer] = []
    var isScanning = false
    var tailscaleDiscoveryNotice: String?

    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID = UUID()
    @ObservationIgnored private var networkServerLastSeen: [String: Date] = [:]

    private let cacheKey = "litter.discovery.networkServers.v1"
    private let cacheRetention: TimeInterval = 7 * 24 * 60 * 60

    private struct CachedNetworkServer: Codable {
        let id: String
        let name: String
        let hostname: String
        let port: UInt16?
        let sshPort: UInt16?
        let source: String
        let hasCodexServer: Bool
        let wakeMAC: String?
        let lastSeenAt: TimeInterval
    }

    func startScanning() {
        stopScanning()
        let scanID = UUID()
        activeScanID = scanID
        tailscaleDiscoveryNotice = nil

        let cachedNetworkServers = loadCachedNetworkServers()
        let retainedNetworkServers = servers.filter { $0.source != .local }
        servers = Self.mergeNetworkServers(cachedNetworkServers + retainedNetworkServers)
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
        let tailscaleDiagnostics = TailscaleDiscoveryDiagnostics()
        let tailscaleAppInstalled = await MainActor.run { Self.isTailscaleAppInstalled() }

        // Run two passes to reduce discovery misses from transient Bonjour/Tailscale timing.
        // Within each pass, stream source results and probe completions progressively so
        // DiscoveryView can render rows as soon as they are found.
        for pass in 0..<2 {
            let bonjourTimeout: TimeInterval = pass == 0 ? 5.0 : 3.0
            let tailscaleTimeout: TimeInterval = pass == 0 ? 1.0 : 0.75
            let probeTimeout: TimeInterval = pass == 0 ? 1.0 : 1.4
            let probeAttempts = pass == 0 ? 2 : 3

            var passCandidates = cumulativeCandidates
            var probedIPs = Set<String>()
            var passReachable: [CandidateReachability] = []

            func probePendingCandidates() async {
                let pending = passCandidates.filter { candidate in
                    probedIPs.insert(candidate.ip).inserted
                }
                guard !pending.isEmpty else { return }

                let reachable = await Self.filterCandidatesWithOpenServices(
                    pending,
                    timeout: probeTimeout,
                    attempts: probeAttempts,
                    onReachable: { state in
                        Task { @MainActor [weak self] in
                            guard let self, self.activeScanID == scanID else { return }
                            self.applyReachabilityResults([state])
                        }
                    }
                )
                passReachable.append(contentsOf: reachable)
            }

            await withTaskGroup(of: [DiscoveryCandidate].self) { group in
                group.addTask { await Self.discoverBonjourCandidates(timeout: bonjourTimeout) }
                group.addTask {
                    await Self.discoverTailscaleSSHCandidates(
                        timeout: tailscaleTimeout,
                        appInstalled: tailscaleAppInstalled,
                        diagnostics: tailscaleDiagnostics
                    )
                }
                group.addTask {
                    await Self.discoverLocalSubnetCodexCandidates(
                        localIPv4: localIPv4,
                        timeout: pass == 0 ? 0.24 : 0.34,
                        attempts: pass == 0 ? 1 : 2
                    )
                }

                while let sourceCandidates = await group.next() {
                    guard !Task.isCancelled else { return }
                    let shouldContinue = await MainActor.run { [weak self] in
                        guard let self else { return false }
                        return self.activeScanID == scanID
                    }
                    guard shouldContinue else { return }

                    let merged = Self.mergeCandidates(sourceCandidates, excluding: localIPv4)
                    cumulativeCandidates = Self.mergeCandidates(cumulativeCandidates + merged, excluding: localIPv4)
                    passCandidates = Self.mergeCandidates(passCandidates + merged, excluding: localIPv4)

                    await probePendingCandidates()
                }
            }

            let tailscaleNotice = await tailscaleDiagnostics.notice
            await MainActor.run { [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.tailscaleDiscoveryNotice = tailscaleNotice
            }

            // Re-probe any candidates carried over from previous pass that were not
            // exercised in this pass to improve reliability after transient failures.
            await probePendingCandidates()

            guard !Task.isCancelled else { return }
            let shouldApply = await MainActor.run { [weak self] in
                guard let self else { return false }
                return self.activeScanID == scanID
            }
            guard shouldApply else { return }
            let passReachableSnapshot = passReachable
            await MainActor.run { [weak self] in
                guard let self, self.activeScanID == scanID else { return }
                self.applyReachabilityResults(passReachableSnapshot)
            }

            if pass == 0 {
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private func applyReachabilityResults(_ reachable: [CandidateReachability]) {
        guard !reachable.isEmpty else { return }
        let now = Date()
        for state in reachable.sorted(by: { Self.candidateSortOrder(lhs: $0.candidate, rhs: $1.candidate) }) {
            let candidate = state.candidate
            let id = "network-\(candidate.ip)"
            networkServerLastSeen[id] = now
            let discovered = DiscoveredServer(
                id: id,
                name: candidate.name ?? candidate.ip,
                hostname: candidate.ip,
                port: state.codexPort,
                sshPort: state.sshPort,
                source: candidate.source,
                hasCodexServer: state.codexPort != nil,
                wakeMAC: servers.first(where: { $0.id == id })?.wakeMAC
            )

            if let index = servers.firstIndex(where: { $0.id == id }) {
                let existing = servers[index]
                let preferredSource = Self.sourceRank(candidate.source) <= Self.sourceRank(existing.source)
                    ? candidate.source
                    : existing.source
                let preferredName = (existing.name == existing.hostname) && (discovered.name != discovered.hostname)
                    ? discovered.name
                    : existing.name
                servers[index] = DiscoveredServer(
                    id: existing.id,
                    name: preferredName,
                    hostname: discovered.hostname,
                    port: discovered.port,
                    sshPort: discovered.sshPort ?? existing.sshPort,
                    source: preferredSource,
                    hasCodexServer: discovered.hasCodexServer,
                    wakeMAC: existing.wakeMAC ?? discovered.wakeMAC,
                    sshPortForwardingEnabled: existing.sshPortForwardingEnabled
                )
            } else {
                servers.append(discovered)
            }
        }
        saveCachedNetworkServers()
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

    private static func mergeNetworkServers(_ candidates: [DiscoveredServer]) -> [DiscoveredServer] {
        var merged: [String: DiscoveredServer] = [:]
        for candidate in candidates where candidate.source != .local {
            if let existing = merged[candidate.id] {
                let betterSource = sourceRank(candidate.source) < sourceRank(existing.source)
                let hasCodexUpgrade = candidate.hasCodexServer && !existing.hasCodexServer
                let betterCodexPort = candidate.hasCodexServer && existing.hasCodexServer && candidate.port != existing.port
                let betterName = existing.name == existing.hostname && candidate.name != candidate.hostname
                if betterSource || hasCodexUpgrade || betterCodexPort || betterName {
                    merged[candidate.id] = candidate
                }
            } else {
                merged[candidate.id] = candidate
            }
        }
        return Array(merged.values).sorted { lhs, rhs in
            let lhsRank = sourceRank(lhs.source)
            let rhsRank = sourceRank(rhs.source)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func loadCachedNetworkServers() -> [DiscoveredServer] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        let decoder = JSONDecoder()
        guard let cached = try? decoder.decode([CachedNetworkServer].self, from: data) else {
            UserDefaults.standard.removeObject(forKey: cacheKey)
            return []
        }

        let now = Date()
        let maxAge = cacheRetention
        var pruned: [CachedNetworkServer] = []
        var loaded: [DiscoveredServer] = []
        networkServerLastSeen.removeAll(keepingCapacity: true)

        for entry in cached {
            guard now.timeIntervalSince1970 - entry.lastSeenAt <= maxAge else { continue }
            let source = ServerSource.from(entry.source)
            guard source != .local else { continue }
                let server = DiscoveredServer(
                    id: entry.id,
                    name: entry.name,
                    hostname: entry.hostname,
                    port: entry.port,
                    sshPort: entry.sshPort,
                    source: source,
                    hasCodexServer: entry.hasCodexServer,
                    wakeMAC: entry.wakeMAC
                )
            loaded.append(server)
            pruned.append(entry)
            networkServerLastSeen[entry.id] = Date(timeIntervalSince1970: entry.lastSeenAt)
        }

        if pruned.count != cached.count {
            persistCachedNetworkServers(pruned)
        }

        return loaded
    }

    private func saveCachedNetworkServers() {
        let now = Date()
        let cached = servers
            .filter { $0.source != .local }
            .map { server in
                let lastSeen = networkServerLastSeen[server.id] ?? now
                return CachedNetworkServer(
                    id: server.id,
                    name: server.name,
                    hostname: server.hostname,
                    port: server.port,
                    sshPort: server.sshPort,
                    source: server.source.rawString,
                    hasCodexServer: server.hasCodexServer,
                    wakeMAC: server.wakeMAC,
                    lastSeenAt: lastSeen.timeIntervalSince1970
                )
            }
        persistCachedNetworkServers(cached)
    }

    private func persistCachedNetworkServers(_ cached: [CachedNetworkServer]) {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(cached) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    nonisolated private static func mergeCandidates(
        _ candidates: [DiscoveryCandidate],
        excluding localIPv4: String?
    ) -> [DiscoveryCandidate] {
        var merged: [String: DiscoveryCandidate] = [:]
        for candidate in candidates {
            guard isIPv4Address(candidate.ip), candidate.ip != localIPv4 else { continue }
            if let existing = merged[candidate.ip] {
                let useCandidateSource = sourceRank(candidate.source) < sourceRank(existing.source)
                let resolvedName = existing.name ?? candidate.name
                let resolvedSource = useCandidateSource ? candidate.source : existing.source
                let resolvedPortHint = existing.codexPortHint ?? candidate.codexPortHint
                merged[candidate.ip] = DiscoveryCandidate(
                    ip: candidate.ip,
                    name: resolvedName,
                    source: resolvedSource,
                    codexPortHint: resolvedPortHint
                )
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
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        cont.resume(returning: true)
                    }
                case .failed, .cancelled:
                    if resumed.setTrue() {
                        connection.stateUpdateHandler = nil
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
                    connection.stateUpdateHandler = nil
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
        attempts: Int,
        onReachable: (@Sendable (CandidateReachability) -> Void)? = nil
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
                    // Bonjour hosts can expose app-server shortly after service resolution;
                    // give codex ports one longer retry window before classifying as SSH-only.
                    if codexPort == nil, candidate.source == .bonjour {
                        for port in codexDiscoveryPorts {
                            if await isPortOpen(
                                host: candidate.ip,
                                port: port,
                                timeout: max(0.8, timeout * 1.9),
                                attempts: attempts + 1
                            ) {
                                codexPort = port
                                break
                            }
                        }
                    }

                    // Bonjour records are already service-level signals; keep them even when probes flake.
                    let includeOnBonjourSignal = candidate.source == .bonjour
                    guard hasSSH || codexPort != nil || includeOnBonjourSignal else {
                        return nil
                    }
                    return CandidateReachability(
                        candidate: candidate,
                        codexPort: codexPort,
                        sshPort: hasSSH ? 22 : nil
                    )
                }
            }
            var reachable: [CandidateReachability] = []
            for await state in group {
                if let state {
                    reachable.append(state)
                    onReachable?(state)
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

    nonisolated static func parseTailscalePeerCandidates(
        data: Data,
        response: URLResponse
    ) throws -> [TailscalePeerIdentity] {
        enum ParseError: Error {
            case unsupportedSurface
            case invalidPayload
        }

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw ParseError.invalidPayload
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased()
        let preview = String(decoding: data.prefix(128), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if contentType?.contains("text/html") == true ||
            preview.hasPrefix("<!doctype html") ||
            preview.hasPrefix("<html") {
            throw ParseError.unsupportedSurface
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let peers = json["Peer"] as? [String: Any] else {
            throw ParseError.invalidPayload
        }

        var out: [TailscalePeerIdentity] = []
        out.reserveCapacity(peers.count)
        for peer in peers.values {
            guard let peerDict = peer as? [String: Any] else { continue }
            if let online = peerDict["Online"] as? Bool, !online {
                continue
            }
            let hostName = cleanedHostName(peerDict["HostName"] as? String)
                ?? cleanedHostName(peerDict["DNSName"] as? String)
            let ips = (peerDict["TailscaleIPs"] as? [String]) ?? []
            guard let ipv4 = ips.first(where: { isIPv4Address($0) }) else { continue }
            out.append(TailscalePeerIdentity(ip: ipv4, name: hostName))
        }

        return out
    }

    nonisolated private static func discoverTailscaleSSHCandidates(
        timeout: TimeInterval,
        appInstalled: Bool,
        diagnostics: TailscaleDiscoveryDiagnostics
    ) async -> [DiscoveryCandidate] {
        guard let url = URL(string: "http://100.100.100.100/localapi/v0/status") else {
            return []
        }

        let interfaceSnapshot = tailscaleInterfaceSnapshot()
        let availability = TailscaleAvailability(
            appInstalled: appInstalled,
            likelyActiveTunnel: interfaceSnapshot.hasLikelyActiveTailscaleTunnel
        )
        NSLog(
            "[tailscale] availability=%@ interface snapshot before request: %@",
            availability.logDescription,
            interfaceSnapshot.logDescription
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 0.25
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                NSLog("[tailscale] response status=%d contentType=%@", http.statusCode, contentType)
            }
            let peers = try parseTailscalePeerCandidates(data: data, response: response)
            await diagnostics.markSuccess()
            NSLog("[tailscale] got %d peers", peers.count)
            let candidates = peers.map {
                DiscoveryCandidate(ip: $0.ip, name: $0.name, source: .tailscale, codexPortHint: nil)
            }
            NSLog("[tailscale] returning %d candidates", candidates.count)
            return candidates
        } catch {
            let notice: String
            let responsePreview = (error as NSError).localizedDescription
            if let urlError = error as? URLError, urlError.code == .timedOut {
                notice = "Tailscale peer discovery timed out. Add a server manually with its MagicDNS name or Tailscale IP."
            } else {
                notice = "Tailscale peer discovery is unavailable right now. Add a server manually with its MagicDNS name or Tailscale IP."
            }
            if availability.shouldSurfaceDiscoveryNotice {
                await diagnostics.record(notice)
            } else {
                NSLog("[tailscale] suppressing notice because Tailscale does not look installed or active")
            }
            NSLog("[tailscale] request error: %@", responsePreview)
            NSLog("[tailscale] interface snapshot after error: %@", tailscaleInterfaceSnapshot().logDescription)
        }
        return []
    }

    @MainActor
    private static func isTailscaleAppInstalled() -> Bool {
        guard let url = URL(string: "tailscale://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    nonisolated private static func discoverLocalSubnetCodexCandidates(
        localIPv4: String?,
        timeout: TimeInterval,
        attempts: Int
    ) async -> [DiscoveryCandidate] {
        guard let localIPv4 else { return [] }
        let parts = localIPv4.split(separator: ".")
        guard parts.count == 4 else { return [] }
        guard let lastOctet = Int(parts[3]) else { return [] }

        let subnetPrefix = "\(parts[0]).\(parts[1]).\(parts[2])."
        let hosts: [Int] = (1...254).filter { $0 != lastOctet }
        var found: [DiscoveryCandidate] = []

        let batchSize = 28
        for start in stride(from: 0, to: hosts.count, by: batchSize) {
            let batch = hosts[start..<min(start + batchSize, hosts.count)]
            let batchResults: [DiscoveryCandidate] = await withTaskGroup(of: DiscoveryCandidate?.self) { group in
                for host in batch {
                    group.addTask {
                        let ip = "\(subnetPrefix)\(host)"
                        for port in codexDiscoveryPorts {
                            if await isPortOpen(
                                host: ip,
                                port: port,
                                timeout: timeout,
                                attempts: attempts
                            ) {
                                return DiscoveryCandidate(
                                    ip: ip,
                                    name: nil,
                                    source: .bonjour,
                                    codexPortHint: port
                                )
                            }
                        }
                        return nil
                    }
                }

                var results: [DiscoveryCandidate] = []
                for await candidate in group {
                    if let candidate {
                        results.append(candidate)
                    }
                }
                return results
            }
            found.append(contentsOf: batchResults)
        }
        return found
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

    nonisolated private static func isTailscaleIPv4Address(_ value: String) -> Bool {
        let octets = value.split(separator: ".")
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]) else {
            return false
        }
        return first == 100 && (64...127).contains(second)
    }

    nonisolated private static func isTailscaleIPv6Address(_ value: String) -> Bool {
        value.lowercased().hasPrefix("fd7a:115c:a1e0:")
    }

    nonisolated private static func interfaceFlagDescriptions(_ flags: Int32) -> [String] {
        var out: [String] = []
        if flags & IFF_UP != 0 { out.append("up") }
        if flags & IFF_RUNNING != 0 { out.append("running") }
        if flags & IFF_LOOPBACK != 0 { out.append("loopback") }
        if flags & IFF_POINTOPOINT != 0 { out.append("ptp") }
        if flags & IFF_MULTICAST != 0 { out.append("multicast") }
        return out
    }

    nonisolated private static func ipAddress(fromSockaddr pointer: UnsafePointer<sockaddr>) -> (family: String, address: String)? {
        let family = pointer.pointee.sa_family
        switch family {
        case sa_family_t(AF_INET):
            let sinPtr = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in.self)
            var addr = sinPtr.pointee.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return ("ipv4", String(cString: buffer))
        case sa_family_t(AF_INET6):
            let sin6Ptr = UnsafeRawPointer(pointer).assumingMemoryBound(to: sockaddr_in6.self)
            var addr = sin6Ptr.pointee.sin6_addr
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &addr, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            return ("ipv6", String(cString: buffer))
        default:
            return nil
        }
    }

    nonisolated private static func tailscaleInterfaceSnapshot() -> TailscaleInterfaceSnapshot {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            return TailscaleInterfaceSnapshot(
                localWiFiAddress: nil,
                localWiFiInterface: nil,
                activeTunnelInterfaces: [],
                tailscaleInterfaces: [],
                records: []
            )
        }
        defer { freeifaddrs(ifaddr) }

        var localWiFiAddress: String?
        var localWiFiInterface: String?
        var activeTunnelInterfaces = Set<String>()
        var tailscaleInterfaces = Set<String>()
        var records: [TailscaleInterfaceSnapshot.InterfaceRecord] = []

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sockaddr = ptr.pointee.ifa_addr else { continue }
            guard let entry = ipAddress(fromSockaddr: sockaddr) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            let flagDescriptions = interfaceFlagDescriptions(flags)
            let isUp = flags & IFF_UP != 0
            let isLoopback = flags & IFF_LOOPBACK != 0
            let isTunnel = name.hasPrefix("utun")
            let hasTailscaleAddress = isTailscaleIPv4Address(entry.address) || isTailscaleIPv6Address(entry.address)
            let isLikelyTailscaleInterface = isTunnel && hasTailscaleAddress

            if isUp && isTunnel {
                activeTunnelInterfaces.insert(name)
            }
            if isLikelyTailscaleInterface {
                tailscaleInterfaces.insert(name)
            }
            if isUp && !isLoopback && localWiFiAddress == nil && entry.family == "ipv4" && name.hasPrefix("en") {
                localWiFiInterface = name
                localWiFiAddress = entry.address
            }

            if isTunnel || isLikelyTailscaleInterface || (isUp && !isLoopback) {
                records.append(
                    TailscaleInterfaceSnapshot.InterfaceRecord(
                        name: name,
                        family: entry.family,
                        address: entry.address,
                        flags: flagDescriptions,
                        isTailscaleAddress: isLikelyTailscaleInterface
                    )
                )
            }
        }

        records.sort { lhs, rhs in
            if lhs.name != rhs.name {
                return lhs.name < rhs.name
            }
            if lhs.family != rhs.family {
                return lhs.family < rhs.family
            }
            return lhs.address < rhs.address
        }

        return TailscaleInterfaceSnapshot(
            localWiFiAddress: localWiFiAddress,
            localWiFiInterface: localWiFiInterface,
            activeTunnelInterfaces: activeTunnelInterfaces.sorted(),
            tailscaleInterfaces: tailscaleInterfaces.sorted(),
            records: records
        )
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
