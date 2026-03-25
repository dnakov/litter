package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.FfiDiscoveredServer
import uniffi.codex_mobile_client.FfiDiscoverySource

/**
 * Persistent server list stored in SharedPreferences.
 * Platform-specific — cannot live in Rust.
 */
data class SavedServer(
    val id: String,
    val name: String,
    val hostname: String,
    val port: Int,
    val sshPort: Int? = null,
    val source: String = "manual", // local, bonjour, tailscale, lanProbe, arpScan, ssh, manual
    val hasCodexServer: Boolean = false,
    val wakeMAC: String? = null,
    val sshPortForwardingEnabled: Boolean = false,
    val websocketURL: String? = null,
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
        sshPort?.let { put("sshPort", it) }
        put("source", source)
        put("hasCodexServer", hasCodexServer)
        wakeMAC?.let { put("wakeMAC", it) }
        put("sshPortForwardingEnabled", sshPortForwardingEnabled)
        websocketURL?.let { put("websocketURL", it) }
    }

    val prefersSshConnection: Boolean
        get() = websocketURL == null && (
            sshPortForwardingEnabled ||
                (hasCodexServer && port == 22) ||
                (!hasCodexServer && (
                    sshPort != null ||
                        source == "ssh" ||
                        port == 22
                ))
        )

    val canConnectViaSsh: Boolean
        get() = websocketURL == null && (
            sshPort != null ||
                sshPortForwardingEnabled ||
                source == "ssh" ||
                port == 22 ||
                !hasCodexServer
        )

    val resolvedSshPort: Int
        get() = sshPort ?: port.takeIf { it > 0 } ?: 22

    val directCodexPort: Int?
        get() = when {
            websocketURL != null -> null
            hasCodexServer && !prefersSshConnection && port > 0 -> port
            else -> null
        }

    companion object {
        fun fromJson(obj: JSONObject): SavedServer = SavedServer(
            id = obj.getString("id"),
            name = obj.optString("name", ""),
            hostname = obj.optString("hostname", ""),
            port = obj.optInt("port", 0),
            sshPort = if (obj.has("sshPort")) obj.getInt("sshPort") else null,
            source = obj.optString("source", "manual"),
            hasCodexServer = obj.optBoolean("hasCodexServer", false),
            wakeMAC = if (obj.has("wakeMAC")) obj.getString("wakeMAC") else null,
            sshPortForwardingEnabled = obj.optBoolean("sshPortForwardingEnabled", false),
            websocketURL = if (obj.has("websocketURL")) obj.getString("websocketURL") else null,
        )

        fun from(server: FfiDiscoveredServer): SavedServer = SavedServer(
            id = server.id,
            name = server.displayName,
            hostname = server.host,
            port = server.codexPort?.toInt() ?: server.port.toInt(),
            sshPort = server.sshPort?.toInt(),
            source = when (server.source) {
                FfiDiscoverySource.BONJOUR -> "bonjour"
                FfiDiscoverySource.TAILSCALE -> "tailscale"
                FfiDiscoverySource.LAN_PROBE -> "lanProbe"
                FfiDiscoverySource.ARP_SCAN -> "arpScan"
                FfiDiscoverySource.MANUAL -> "manual"
                FfiDiscoverySource.LOCAL -> "local"
            },
            hasCodexServer = server.codexPort != null,
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
            (0 until array.length()).map { SavedServer.fromJson(array.getJSONObject(it)) }
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
}
