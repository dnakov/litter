package com.litter.android.core.network

import org.json.JSONObject
import java.io.BufferedReader
import java.io.File
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.Socket
import java.net.URL
import java.util.Locale

/**
 * Android discovery implementation aligned with iOS behavior where possible.
 *
 * Current coverage:
 * - Local host candidate
 * - Tailscale LocalAPI peers (best-effort)
 * - ARP neighbor probing on local network
 * - Codex (port 8390) + SSH (port 22) reachability checks
 *
 * TODO:
 * - Full Bonjour mDNS browsing for `_ssh._tcp.` and Codex-specific service types.
 * - Better subnet scanning and host naming for non-ARP neighbors.
 */
enum class DiscoverySource {
    LOCAL,
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

class ServerDiscoveryService {
    fun discover(): List<DiscoveredServer> {
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

        for (candidate in discoverTailscaleCandidates()) {
            val server = probeCandidate(candidate)
            if (server != null) {
                results[server.id] = server
            }
        }

        for (candidate in discoverArpCandidates()) {
            val server = probeCandidate(candidate)
            if (server != null) {
                results.putIfAbsent(server.id, server)
            }
        }

        // Keep deterministic ordering for UI.
        return results
            .values
            .sortedWith(compareBy<DiscoveredServer> { sourceRank(it.source) }.thenBy { it.name.lowercase(Locale.US) })
    }

    private fun sourceRank(source: DiscoverySource): Int =
        when (source) {
            DiscoverySource.LOCAL -> 0
            DiscoverySource.BONJOUR -> 1
            DiscoverySource.TAILSCALE -> 2
            DiscoverySource.SSH -> 3
            DiscoverySource.LAN -> 4
            DiscoverySource.MANUAL -> 5
        }

    private fun probeCandidate(candidate: DiscoveryCandidate): DiscoveredServer? {
        if (candidate.host.isBlank() || candidate.host == "127.0.0.1") {
            return null
        }

        val codexOpen = hasOpenPort(candidate.host, 8390, timeoutMs = 140)
        val sshOpen = hasOpenPort(candidate.host, 22, timeoutMs = 120)

        if (!codexOpen && !sshOpen) {
            return null
        }

        val source =
            when {
                candidate.source == DiscoverySource.TAILSCALE -> DiscoverySource.TAILSCALE
                codexOpen -> candidate.source
                else -> DiscoverySource.SSH
            }
        val port = if (codexOpen) 8390 else 22
        val hasCodexServer = codexOpen

        val name = candidate.name.ifBlank { candidate.host }
        val idPrefix = when (source) {
            DiscoverySource.TAILSCALE -> "tailscale"
            DiscoverySource.BONJOUR -> "bonjour"
            DiscoverySource.SSH -> "ssh"
            else -> "lan"
        }

        return DiscoveredServer(
            id = "$idPrefix-${candidate.host}",
            name = name,
            host = candidate.host,
            port = port,
            source = source,
            hasCodexServer = hasCodexServer,
        )
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

        // Keep probe budget bounded.
        return candidates.values.take(24)
    }

    private fun discoverTailscaleCandidates(): List<DiscoveryCandidate> {
        val out = mutableListOf<DiscoveryCandidate>()
        val endpoint = "http://100.100.100.100/localapi/v0/status"
        runCatching {
            val conn = (URL(endpoint).openConnection() as HttpURLConnection).apply {
                connectTimeout = 500
                readTimeout = 700
                requestMethod = "GET"
                useCaches = false
            }
            conn.inputStream.use { stream ->
                val body = BufferedReader(InputStreamReader(stream)).readText()
                val json = JSONObject(body)
                val peerObject = json.optJSONObject("Peer") ?: return@use
                val peerKeys = peerObject.keys()
                while (peerKeys.hasNext()) {
                    val key = peerKeys.next()
                    val peer = peerObject.optJSONObject(key) ?: continue
                    val hostName =
                        peer.optString("HostName").trim().ifBlank {
                            peer.optString("DNSName").trim().removeSuffix(".")
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
                                name = if (hostName.isBlank()) ipv4 else hostName,
                                source = DiscoverySource.TAILSCALE,
                            )
                    }
                }
            }
            conn.disconnect()
        }
        return out.take(20)
    }

    private fun hasOpenPort(
        host: String,
        port: Int,
        timeoutMs: Int,
    ): Boolean {
        return runCatching {
            Socket().use { socket ->
                socket.connect(InetSocketAddress(host, port), timeoutMs)
                true
            }
        }.getOrDefault(false)
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

    @Suppress("unused")
    private fun discoverLocalInterfaceAddresses(): List<String> {
        val out = mutableListOf<String>()
        runCatching {
            val interfaces = NetworkInterface.getNetworkInterfaces() ?: return out
            while (interfaces.hasMoreElements()) {
                val iface = interfaces.nextElement()
                if (!iface.isUp || iface.isLoopback) {
                    continue
                }
                val addresses = iface.inetAddresses
                while (addresses.hasMoreElements()) {
                    val address = addresses.nextElement().hostAddress ?: continue
                    if (isLikelyIpv4(address)) {
                        out += address
                    }
                }
            }
        }
        return out
    }
}

private data class DiscoveryCandidate(
    val host: String,
    val name: String,
    val source: DiscoverySource,
)
