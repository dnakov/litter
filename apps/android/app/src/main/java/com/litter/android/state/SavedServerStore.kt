package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.AppDiscoveredServer
import uniffi.codex_mobile_client.AppDiscoverySource

/**
 * Persistent server list stored in SharedPreferences.
 * Platform-specific — cannot live in Rust.
 */
data class SavedServer(
    val id: String,
    val name: String,
    val hostname: String,
    val port: Int,
    val codexPorts: List<Int> = emptyList(),
    val sshPort: Int? = null,
    val source: String = "manual", // local, bonjour, tailscale, lanProbe, arpScan, ssh, manual
    val hasCodexServer: Boolean = false,
    val wakeMAC: String? = null,
    val preferredConnectionMode: String? = null, // directCodex or ssh
    val preferredCodexPort: Int? = null,
    val sshPortForwardingEnabled: Boolean? = null, // legacy migration only
    val websocketURL: String? = null,
    val os: String? = null,
    val sshBanner: String? = null,
) {
    /** Stable key for deduplication across discovery cycles. */
    val deduplicationKey: String
        get() = websocketURL ?: normalizedHostKey(hostname)

    private fun normalizedHostKey(host: String): String {
        val trimmed = host.trim().trimStart('[').trimEnd(']')
        val withoutScope = if (!trimmed.contains(":")) {
            trimmed.substringBefore('%')
        } else {
            trimmed
        }
        return withoutScope.lowercase()
    }

    fun toJson(): JSONObject = JSONObject().apply {
        put("id", id)
        put("name", name)
        put("hostname", hostname)
        put("port", port)
        put("codexPorts", JSONArray(availableDirectCodexPorts))
        sshPort?.let { put("sshPort", it) }
        put("source", source)
        put("hasCodexServer", hasCodexServer)
        wakeMAC?.let { put("wakeMAC", it) }
        preferredConnectionMode?.let { put("preferredConnectionMode", it) }
        preferredCodexPort?.let { put("preferredCodexPort", it) }
        sshPortForwardingEnabled?.let { put("sshPortForwardingEnabled", it) }
        websocketURL?.let { put("websocketURL", it) }
        os?.let { put("os", it) }
        sshBanner?.let { put("sshBanner", it) }
    }

    val availableDirectCodexPorts: List<Int>
        get() {
            val ordered = buildList {
                if (hasCodexServer && port > 0) add(port)
                addAll(codexPorts.filter { it > 0 })
            }
            return ordered.distinct()
        }

    val resolvedPreferredConnectionMode: String?
        get() = when (preferredConnectionMode) {
            "directCodex" -> if (availableDirectCodexPorts.isNotEmpty() || websocketURL != null) "directCodex" else null
            "ssh" -> if (canConnectViaSsh) "ssh" else null
            else -> if (sshPortForwardingEnabled == true) "ssh" else null
        }

    val prefersSshConnection: Boolean
        get() = resolvedPreferredConnectionMode == "ssh"

    val canConnectViaSsh: Boolean
        get() = websocketURL == null && (
            sshPort != null ||
                source == "ssh" ||
                (!hasCodexServer && resolvedSshPort > 0) ||
                preferredConnectionMode == "ssh" ||
                sshPortForwardingEnabled == true
        )

    val resolvedSshPort: Int
        get() = sshPort ?: port.takeIf { !hasCodexServer && it > 0 } ?: 22

    val resolvedPreferredCodexPort: Int?
        get() = when {
            resolvedPreferredConnectionMode != "directCodex" -> null
            preferredCodexPort != null && availableDirectCodexPorts.contains(preferredCodexPort) -> preferredCodexPort
            else -> null
        }

    val requiresConnectionChoice: Boolean
        get() = websocketURL == null &&
            resolvedPreferredConnectionMode == null &&
            (
                availableDirectCodexPorts.size > 1 ||
                    (availableDirectCodexPorts.isNotEmpty() && canConnectViaSsh)
            )

    val directCodexPort: Int?
        get() = when {
            websocketURL != null -> null
            prefersSshConnection -> null
            resolvedPreferredCodexPort != null -> resolvedPreferredCodexPort
            requiresConnectionChoice -> null
            availableDirectCodexPorts.isNotEmpty() -> availableDirectCodexPorts.first()
            else -> null
        }

    fun withPreferredConnection(mode: String?, codexPort: Int? = null): SavedServer =
        copy(
            port = when (mode) {
                "directCodex" -> codexPort ?: directCodexPort ?: availableDirectCodexPorts.firstOrNull() ?: port
                "ssh" -> resolvedSshPort
                else -> port
            },
            codexPorts = availableDirectCodexPorts,
            sshPort = sshPort ?: if (canConnectViaSsh) resolvedSshPort else null,
            preferredConnectionMode = mode,
            preferredCodexPort = if (mode == "directCodex") {
                codexPort ?: directCodexPort ?: availableDirectCodexPorts.firstOrNull()
            } else {
                null
            },
            sshPortForwardingEnabled = null,
        )

    fun normalizedForPersistence(): SavedServer = withPreferredConnection(
        mode = resolvedPreferredConnectionMode,
        codexPort = resolvedPreferredCodexPort ?: availableDirectCodexPorts.firstOrNull(),
    )

    companion object {
        fun normalizeWakeMac(raw: String?): String? {
            val compact = raw
                ?.trim()
                ?.replace(":", "")
                ?.replace("-", "")
                ?.lowercase()
                ?: return null
            if (compact.length != 12 || compact.any { !it.isDigit() && it !in 'a'..'f' }) {
                return null
            }
            return buildString {
                compact.chunked(2).forEachIndexed { index, chunk ->
                    if (index > 0) append(':')
                    append(chunk)
                }
            }
        }

        fun fromJson(obj: JSONObject): SavedServer = SavedServer(
            id = obj.getString("id"),
            name = obj.optString("name", ""),
            hostname = obj.optString("hostname", ""),
            port = obj.optInt("port", 0),
            codexPorts = buildList {
                val ports = obj.optJSONArray("codexPorts")
                if (ports != null) {
                    for (index in 0 until ports.length()) {
                        add(ports.optInt(index))
                    }
                }
            },
            sshPort = if (obj.has("sshPort")) obj.getInt("sshPort") else null,
            source = obj.optString("source", "manual"),
            hasCodexServer = obj.optBoolean("hasCodexServer", false),
            wakeMAC = if (obj.has("wakeMAC")) obj.getString("wakeMAC") else null,
            preferredConnectionMode = obj.optString("preferredConnectionMode").ifBlank { null },
            preferredCodexPort = if (obj.has("preferredCodexPort")) obj.getInt("preferredCodexPort") else null,
            sshPortForwardingEnabled = if (obj.has("sshPortForwardingEnabled")) {
                obj.optBoolean("sshPortForwardingEnabled")
            } else {
                null
            },
            websocketURL = if (obj.has("websocketURL")) obj.getString("websocketURL") else null,
            os = if (obj.has("os")) obj.getString("os") else null,
            sshBanner = if (obj.has("sshBanner")) obj.getString("sshBanner") else null,
        )

        fun from(server: AppDiscoveredServer): SavedServer = SavedServer(
            id = server.id,
            name = server.displayName,
            hostname = server.host,
            port = server.codexPort?.toInt() ?: server.port.toInt(),
            codexPorts = server.codexPorts.map { it.toInt() },
            sshPort = server.sshPort?.toInt(),
            source = when (server.source) {
                AppDiscoverySource.BONJOUR -> "bonjour"
                AppDiscoverySource.TAILSCALE -> "tailscale"
                AppDiscoverySource.LAN_PROBE -> "lanProbe"
                AppDiscoverySource.ARP_SCAN -> "arpScan"
                AppDiscoverySource.MANUAL -> "manual"
                AppDiscoverySource.LOCAL -> "local"
            },
            hasCodexServer = server.codexPort != null || server.codexPorts.isNotEmpty(),
            os = if (server.sshBanner != null) server.os else server.os,
            sshBanner = server.sshBanner,
        )
    }
}

object SavedServerStore {
    private const val PREFS_NAME = "codex_saved_servers_prefs"
    private const val KEY = "codex_saved_servers"

    private fun prefs(context: Context): SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun load(context: Context): List<SavedServer> {
        val json = prefs(context).getString(KEY, null) ?: return emptyList()
        return try {
            val array = JSONArray(json)
            val decoded = (0 until array.length()).map { SavedServer.fromJson(array.getJSONObject(it)) }
            val migrated = decoded.map { it.normalizedForPersistence() }
            if (decoded != migrated) {
                save(context, migrated)
            }
            migrated
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun save(context: Context, servers: List<SavedServer>) {
        val array = JSONArray()
        servers.forEach { array.put(it.toJson()) }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }

    fun upsert(context: Context, server: SavedServer) {
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == server.id || it.deduplicationKey == server.deduplicationKey }
        existing.add(server)
        save(context, existing)
    }

    fun remove(context: Context, serverId: String) {
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == serverId }
        save(context, existing)
    }

    fun rename(context: Context, serverId: String, newName: String) {
        val trimmed = newName.trim()
        if (trimmed.isEmpty()) return

        val existing = load(context)
        val renamed = existing.map { server ->
            if (server.id == serverId) server.copy(name = trimmed) else server
        }
        if (renamed != existing) {
            save(context, renamed)
        }
    }
}
