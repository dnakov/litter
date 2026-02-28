package com.litter.android.core.network

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.URL
import java.util.Locale
import java.util.concurrent.Callable
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

private val CODEX_DISCOVERY_PORTS = intArrayOf(8390, 4222)

enum class DiscoverySource {
    LOCAL,
    BUNDLED,
    BONJOUR,
    SSH,
    TAILSCALE,
    MANUAL,
    LAN,
}

data class DiscoveredServer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val source: DiscoverySource = DiscoverySource.LAN,
    val hasCodexServer: Boolean = false,
)

private data class DiscoveryCandidate(
    val host: String,
    val name: String?,
    val source: DiscoverySource,
    val codexPortHint: Int? = null,
)

private data class CandidateReachability(
    val candidate: DiscoveryCandidate,
    val codexPort: Int?,
)

class ServerDiscoveryService(
    private val context: Context? = null,
) {
    fun discover(): List<DiscoveredServer> = discoverProgressive {}

    fun discoverProgressive(onUpdate: (List<DiscoveredServer>) -> Unit): List<DiscoveredServer> {
        val results = LinkedHashMap<String, DiscoveredServer>()

        results["local"] =
            DiscoveredServer(
                id = "local",
                name = "On Device",
                host = "127.0.0.1",
                port = 8390,
                source = DiscoverySource.LOCAL,
                hasCodexServer = true,
            )

        results["bundled"] =
            DiscoveredServer(
                id = "bundled",
                name = "Bundled Server",
                host = "127.0.0.1",
                port = 4500,
                source = DiscoverySource.BUNDLED,
                hasCodexServer = true,
            )

        onUpdate(sortedServers(results.values))

        val localIpv4 = discoverLocalIpv4Address()
        var cumulativeCandidates: List<DiscoveryCandidate> = emptyList()

        for (pass in 0..1) {
            if (Thread.currentThread().isInterrupted) {
                break
            }

            val bonjourTimeoutMs = if (pass == 0) 5_000L else 3_000L
            val tailscaleTimeoutMs = if (pass == 0) 2_500L else 1_500L
            val probeTimeoutMs = if (pass == 0) 1_000 else 1_400
            val probeAttempts = if (pass == 0) 2 else 3
            val subnetProbeTimeoutMs = if (pass == 0) 240 else 340
            val subnetProbeAttempts = if (pass == 0) 1 else 2

            var passCandidates = cumulativeCandidates
            val probedHosts = HashSet<String>()

            fun probePendingCandidates() {
                val pending =
                    passCandidates.filter { candidate ->
                        probedHosts.add(candidate.host)
                    }
                if (pending.isEmpty()) {
                    return
                }

                filterCandidatesWithOpenServices(
                    candidates = pending,
                    timeoutMs = probeTimeoutMs,
                    attempts = probeAttempts,
                    onReachable = { state ->
                        upsertReachable(results, state)
                        onUpdate(sortedServers(results.values))
                    },
                )
            }

            val passExecutor = Executors.newFixedThreadPool(4)
            try {
                val completion = ExecutorCompletionService<List<DiscoveryCandidate>>(passExecutor)
                val tasks =
                    listOf(
                        Callable {
                            discoverBonjourCandidates(timeoutMs = bonjourTimeoutMs)
                        },
                        Callable {
                            discoverTailscaleCandidates(timeoutMs = tailscaleTimeoutMs)
                        },
                        Callable {
                            discoverLocalSubnetCodexCandidates(
                                localIpv4 = localIpv4,
                                timeoutMs = subnetProbeTimeoutMs,
                                attempts = subnetProbeAttempts,
                            )
                        },
                        Callable {
                            discoverArpCandidates()
                        },
                    )

                tasks.forEach { task -> completion.submit(task) }
                repeat(tasks.size) {
                    val sourceCandidates = runCatching { completion.take().get() }.getOrDefault(emptyList())
                    val merged = mergeCandidates(sourceCandidates, localIpv4)
                    cumulativeCandidates = mergeCandidates(cumulativeCandidates + merged, localIpv4)
                    passCandidates = mergeCandidates(passCandidates + merged, localIpv4)
                    probePendingCandidates()
                }
            } finally {
                passExecutor.shutdownNow()
            }

            probePendingCandidates()

            if (pass == 0) {
                sleepQuietly(700)
            }
        }

        return sortedServers(results.values)
    }

    private fun sortedServers(servers: Collection<DiscoveredServer>): List<DiscoveredServer> =
        servers.sortedWith(compareBy<DiscoveredServer> { sourceRank(it.source) }.thenBy { it.name.lowercase(Locale.US) })

    private fun upsertReachable(
        results: MutableMap<String, DiscoveredServer>,
        state: CandidateReachability,
    ) {
        val candidate = state.candidate
        val discovered =
            toDiscoveredServer(
                candidate = candidate,
                codexPort = state.codexPort,
            ) ?: return

        val existing = results[discovered.id]
        if (existing == null) {
            results[discovered.id] = discovered
            return
        }

        val betterSource = sourceRank(discovered.source) < sourceRank(existing.source)
        val hasCodexUpgrade = discovered.hasCodexServer && !existing.hasCodexServer
        val betterCodexPort =
            discovered.hasCodexServer &&
                existing.hasCodexServer &&
                discovered.port != existing.port
        val betterName = existing.name == existing.host && discovered.name != discovered.host

        if (betterSource || hasCodexUpgrade || betterCodexPort || betterName) {
            results[discovered.id] = discovered
        }
    }

    private fun toDiscoveredServer(
        candidate: DiscoveryCandidate,
        codexPort: Int?,
    ): DiscoveredServer? {
        if (candidate.host.isBlank() || candidate.host == "127.0.0.1") {
            return null
        }

        val hasCodexServer = codexPort != null
        val source =
            when {
                candidate.source == DiscoverySource.TAILSCALE -> DiscoverySource.TAILSCALE
                candidate.source == DiscoverySource.BONJOUR -> DiscoverySource.BONJOUR
                hasCodexServer -> candidate.source
                else -> DiscoverySource.SSH
            }
        val port = codexPort ?: 22

        return DiscoveredServer(
            id = "network-${candidate.host}",
            name = candidate.name ?: candidate.host,
            host = candidate.host,
            port = port,
            source = source,
            hasCodexServer = hasCodexServer,
        )
    }

    private fun mergeCandidates(
        candidates: List<DiscoveryCandidate>,
        localIpv4: String?,
    ): List<DiscoveryCandidate> {
        val merged = LinkedHashMap<String, DiscoveryCandidate>()
        for (candidate in candidates) {
            if (!isLikelyIpv4(candidate.host) || candidate.host == localIpv4 || candidate.host == "127.0.0.1") {
                continue
            }

            val existing = merged[candidate.host]
            if (existing == null) {
                merged[candidate.host] = candidate
                continue
            }

            val useCandidateSource = sourceRank(candidate.source) < sourceRank(existing.source)
            val resolvedSource = if (useCandidateSource) candidate.source else existing.source
            val resolvedName = existing.name ?: candidate.name
            val resolvedCodexHint = existing.codexPortHint ?: candidate.codexPortHint

            merged[candidate.host] =
                DiscoveryCandidate(
                    host = candidate.host,
                    name = resolvedName,
                    source = resolvedSource,
                    codexPortHint = resolvedCodexHint,
                )
        }
        return merged.values.toList()
    }

    private fun filterCandidatesWithOpenServices(
        candidates: List<DiscoveryCandidate>,
        timeoutMs: Int,
        attempts: Int,
        onReachable: ((CandidateReachability) -> Unit)? = null,
    ): List<CandidateReachability> {
        if (candidates.isEmpty()) {
            return emptyList()
        }

        val executor = Executors.newFixedThreadPool(minOf(candidates.size, 24))
        return try {
            val completion = ExecutorCompletionService<CandidateReachability?>(executor)
            candidates.forEach { candidate ->
                completion.submit(
                    Callable {
                        val hasSsh = hasOpenPort(candidate.host, 22, timeoutMs = timeoutMs, attempts = attempts)

                        var codexPort: Int? = null
                        val hint = candidate.codexPortHint
                        if (hint != null && hasOpenPort(candidate.host, hint, timeoutMs = timeoutMs, attempts = attempts)) {
                            codexPort = hint
                        }

                        if (codexPort == null) {
                            for (port in CODEX_DISCOVERY_PORTS) {
                                if (hasOpenPort(candidate.host, port, timeoutMs = timeoutMs, attempts = attempts)) {
                                    codexPort = port
                                    break
                                }
                            }
                        }

                        if (codexPort == null && candidate.source == DiscoverySource.BONJOUR) {
                            val bonjourTimeout = maxOf(800, (timeoutMs * 1.9).toInt())
                            for (port in CODEX_DISCOVERY_PORTS) {
                                if (hasOpenPort(candidate.host, port, timeoutMs = bonjourTimeout, attempts = attempts + 1)) {
                                    codexPort = port
                                    break
                                }
                            }
                        }

                        val includeOnBonjourSignal = candidate.source == DiscoverySource.BONJOUR
                        if (!hasSsh && codexPort == null && !includeOnBonjourSignal) {
                            null
                        } else {
                            CandidateReachability(candidate = candidate, codexPort = codexPort)
                        }
                    },
                )
            }

            val reachable = mutableListOf<CandidateReachability>()
            repeat(candidates.size) {
                val state = runCatching { completion.take().get() }.getOrNull()
                if (state != null) {
                    reachable += state
                    onReachable?.invoke(state)
                }
            }
            reachable
        } finally {
            executor.shutdownNow()
        }
    }

    private fun discoverBonjourCandidates(timeoutMs: Long): List<DiscoveryCandidate> {
        val ssh = discoverBonjourCandidates(timeoutMs = timeoutMs, serviceType = "_ssh._tcp.", codexService = false)
        val codex = discoverBonjourCandidates(timeoutMs = timeoutMs, serviceType = "_codex._tcp.", codexService = true)
        return mergeCandidates(ssh + codex, localIpv4 = null)
    }

    private fun discoverBonjourCandidates(
        timeoutMs: Long,
        serviceType: String,
        codexService: Boolean,
    ): List<DiscoveryCandidate> {
        val appContext = context ?: return emptyList()
        val nsdManager = appContext.getSystemService(Context.NSD_SERVICE) as? NsdManager ?: return emptyList()

        val candidatesByIp = ConcurrentHashMap<String, DiscoveryCandidate>()
        val done = CountDownLatch(1)

        val listener =
            object : NsdManager.DiscoveryListener {
                override fun onStartDiscoveryFailed(
                    serviceType: String?,
                    errorCode: Int,
                ) {
                    done.countDown()
                }

                override fun onStopDiscoveryFailed(
                    serviceType: String?,
                    errorCode: Int,
                ) {
                    done.countDown()
                }

                override fun onDiscoveryStarted(serviceType: String?) = Unit

                override fun onDiscoveryStopped(serviceType: String?) {
                    done.countDown()
                }

                override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                    resolveService(nsdManager, serviceInfo) { resolved ->
                        val host = resolved.host?.hostAddress?.trim().orEmpty()
                        if (!isLikelyIpv4(host) || host == "127.0.0.1") {
                            return@resolveService
                        }

                        val name = cleanHostName(resolved.serviceName).ifBlank { null }
                        val codexHint =
                            if (codexService && resolved.port > 0) {
                                resolved.port
                            } else {
                                null
                            }
                        candidatesByIp[host] =
                            DiscoveryCandidate(
                                host = host,
                                name = name,
                                source = DiscoverySource.BONJOUR,
                                codexPortHint = codexHint,
                            )
                    }
                }

                override fun onServiceLost(serviceInfo: NsdServiceInfo) = Unit
            }

        runCatching {
            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
            done.await(timeoutMs, TimeUnit.MILLISECONDS)
            nsdManager.stopServiceDiscovery(listener)
        }

        return candidatesByIp.values.toList()
    }

    @Suppress("DEPRECATION")
    private fun resolveService(
        nsdManager: NsdManager,
        serviceInfo: NsdServiceInfo,
        onResolved: (NsdServiceInfo) -> Unit,
    ) {
        runCatching {
            nsdManager.resolveService(
                serviceInfo,
                object : NsdManager.ResolveListener {
                    override fun onResolveFailed(
                        serviceInfo: NsdServiceInfo,
                        errorCode: Int,
                    ) = Unit

                    override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                        onResolved(serviceInfo)
                    }
                },
            )
        }
    }

    private fun discoverTailscaleCandidates(timeoutMs: Long): List<DiscoveryCandidate> {
        repeat(2) { attempt ->
            val result = runCatching {
                val endpoint = "http://100.100.100.100/localapi/v0/status"
                val conn =
                    (URL(endpoint).openConnection() as HttpURLConnection).apply {
                        connectTimeout = timeoutMs.toInt()
                        readTimeout = timeoutMs.toInt()
                        requestMethod = "GET"
                        useCaches = false
                    }

                conn.inputStream.use { stream ->
                    val body = BufferedReader(InputStreamReader(stream)).readText()
                    val json = JSONObject(body)
                    val peerObject = json.optJSONObject("Peer") ?: return@use emptyList<DiscoveryCandidate>()

                    val out = mutableListOf<DiscoveryCandidate>()
                    val peerKeys = peerObject.keys()
                    while (peerKeys.hasNext()) {
                        val key = peerKeys.next()
                        val peer = peerObject.optJSONObject(key) ?: continue
                        if (peer.has("Online") && !peer.optBoolean("Online", true)) {
                            continue
                        }

                        val hostName =
                            peer.optString("HostName").trim().ifBlank {
                                peer.optString("DNSName").trim().removeSuffix(".")
                            }.ifBlank {
                                null
                            }

                        val ips = peer.optJSONArray("TailscaleIPs") ?: continue
                        var ipv4: String? = null
                        for (idx in 0 until ips.length()) {
                            val candidate = ips.optString(idx).trim()
                            if (isLikelyIpv4(candidate)) {
                                ipv4 = candidate
                                break
                            }
                        }
                        if (ipv4 != null) {
                            out +=
                                DiscoveryCandidate(
                                    host = ipv4,
                                    name = hostName,
                                    source = DiscoverySource.TAILSCALE,
                                )
                        }
                    }
                    out
                }
            }

            val candidates = result.getOrNull()
            if (candidates != null) {
                return candidates
            }
            if (attempt == 0) {
                sleepQuietly(180)
            }
        }

        return emptyList()
    }

    private fun discoverLocalSubnetCodexCandidates(
        localIpv4: String?,
        timeoutMs: Int,
        attempts: Int,
    ): List<DiscoveryCandidate> {
        val localAddress = localIpv4 ?: return emptyList()
        val parts = localAddress.split('.')
        if (parts.size != 4) {
            return emptyList()
        }

        val lastOctet = parts[3].toIntOrNull() ?: return emptyList()
        val prefix = "${parts[0]}.${parts[1]}.${parts[2]}."
        val hosts = (1..254).filter { host -> host != lastOctet }

        val executor = Executors.newFixedThreadPool(28)
        return try {
            val completion = ExecutorCompletionService<DiscoveryCandidate?>(executor)
            hosts.forEach { host ->
                completion.submit(
                    Callable<DiscoveryCandidate?> {
                        val ip = "$prefix$host"
                        var foundPort: Int? = null
                        for (port in CODEX_DISCOVERY_PORTS) {
                            if (hasOpenPort(ip, port, timeoutMs = timeoutMs, attempts = attempts)) {
                                foundPort = port
                                break
                            }
                        }
                        if (foundPort != null) {
                            DiscoveryCandidate(
                                host = ip,
                                name = null,
                                source = DiscoverySource.BONJOUR,
                                codexPortHint = foundPort,
                            )
                        } else {
                            null
                        }
                    },
                )
            }

            val found = mutableListOf<DiscoveryCandidate>()
            repeat(hosts.size) {
                val candidate = runCatching { completion.take().get() }.getOrNull()
                if (candidate != null) {
                    found += candidate
                }
            }
            found
        } finally {
            executor.shutdownNow()
        }
    }

    private fun discoverArpCandidates(): List<DiscoveryCandidate> {
        val candidates = LinkedHashMap<String, DiscoveryCandidate>()
        val arp = File("/proc/net/arp")
        if (!arp.exists()) {
            return emptyList()
        }

        runCatching {
            arp.useLines { lines ->
                lines.drop(1).forEach { line ->
                    val parts = line.trim().split(Regex("\\s+"))
                    if (parts.size < 6) {
                        return@forEach
                    }
                    val ip = parts[0].trim()
                    val flags = parts[2].trim()
                    val device = parts[5].trim()
                    if (ip == "127.0.0.1" || ip == "0.0.0.0") {
                        return@forEach
                    }
                    if (flags != "0x2") {
                        return@forEach
                    }
                    if (!device.startsWith("wlan") && !device.startsWith("eth") && !device.startsWith("rmnet")) {
                        return@forEach
                    }
                    if (isLikelyIpv4(ip)) {
                        candidates[ip] =
                            DiscoveryCandidate(
                                host = ip,
                                name = ip,
                                source = DiscoverySource.LAN,
                            )
                    }
                }
            }
        }

        return candidates.values.toList()
    }

    private fun discoverLocalIpv4Address(): String? {
        val interfaces = runCatching { NetworkInterface.getNetworkInterfaces() }.getOrNull() ?: return null
        while (interfaces.hasMoreElements()) {
            val network = interfaces.nextElement()
            val name = network.name?.lowercase(Locale.US).orEmpty()
            if (!network.isUp || network.isLoopback) {
                continue
            }
            if (!name.startsWith("wlan") && !name.startsWith("eth") && !name.startsWith("en")) {
                continue
            }
            val addresses = network.inetAddresses
            while (addresses.hasMoreElements()) {
                val address = addresses.nextElement()
                if (address is Inet4Address && !address.isLoopbackAddress) {
                    return address.hostAddress
                }
            }
        }
        return null
    }

    private fun hasOpenPort(
        host: String,
        port: Int,
        timeoutMs: Int,
        attempts: Int,
    ): Boolean {
        val retries = attempts.coerceAtLeast(1)
        repeat(retries) { attempt ->
            val success =
                runCatching {
                    Socket().use { socket ->
                        socket.connect(InetSocketAddress(host, port), timeoutMs)
                        true
                    }
                }.getOrDefault(false)
            if (success) {
                return true
            }
            if (attempt < retries - 1) {
                sleepQuietly(180)
            }
        }
        return false
    }

    private fun isLikelyIpv4(value: String): Boolean {
        val chunks = value.split('.')
        if (chunks.size != 4) {
            return false
        }
        return chunks.all { chunk ->
            val n = chunk.toIntOrNull() ?: return@all false
            n in 0..255
        }
    }

    private fun sourceRank(source: DiscoverySource): Int =
        when (source) {
            DiscoverySource.LOCAL -> 0
            DiscoverySource.BUNDLED -> 1
            DiscoverySource.BONJOUR -> 2
            DiscoverySource.TAILSCALE -> 3
            DiscoverySource.SSH -> 4
            DiscoverySource.LAN -> 5
            DiscoverySource.MANUAL -> 6
        }

    private fun cleanHostName(raw: String?): String {
        var value = raw?.trim().orEmpty()
        if (value.endsWith(".local", ignoreCase = true)) {
            value = value.substring(0, value.length - ".local".length)
        }
        if (value.endsWith('.')) {
            value = value.dropLast(1)
        }
        return value
    }

    private fun sleepQuietly(millis: Long) {
        runCatching { Thread.sleep(millis) }
    }
}
