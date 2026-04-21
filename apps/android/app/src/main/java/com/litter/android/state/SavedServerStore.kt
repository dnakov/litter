package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONArray
import org.json.JSONObject
import uniffi.codex_mobile_client.AppDiscoveredBackendKind
import uniffi.codex_mobile_client.AppDiscoveredServer
import uniffi.codex_mobile_client.AppDiscoverySource
import uniffi.codex_mobile_client.SavedOpenCodeDirectoryScopeRecord
import uniffi.codex_mobile_client.SavedServerBackendKindRecord
import uniffi.codex_mobile_client.SavedServerRecord

/**
 * Persistent server list stored in SharedPreferences.
 * Platform-specific — cannot live in Rust.
 */
enum class SavedServerBackendKind(val rawValue: String) {
    CODEX("codex"),
    OPEN_CODE("openCode");

    companion object {
        fun fromRawValue(value: String?): SavedServerBackendKind =
            values().firstOrNull { it.rawValue == value } ?: CODEX
    }
}

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
    val rememberedByUser: Boolean = false,
    val backendKind: SavedServerBackendKind = SavedServerBackendKind.CODEX,
    val openCodeBaseUrl: String? = null,
    val openCodeBasicAuthUsername: String? = null,
    val openCodeBasicAuthPassword: String? = null,
    val openCodeKnownDirectories: List<String> = emptyList(),
) {
    /** Stable key for deduplication across discovery cycles. */
    val deduplicationKey: String
        get() = when (backendKind) {
            SavedServerBackendKind.CODEX -> {
                val key = websocketURL ?: normalizedHostKey(hostname)
                if (key.isBlank()) id else "codex:$key"
            }
            SavedServerBackendKind.OPEN_CODE -> {
                val key = normalizedBaseUrlKey(openCodeBaseUrl ?: hostname)
                if (key.isBlank()) "opencode:$id" else "opencode:$key"
            }
        }

    private fun normalizedHostKey(host: String): String {
        val trimmed = host.trim().trimStart('[').trimEnd(']')
        val withoutScope = if (!trimmed.contains(":")) {
            trimmed.substringBefore('%')
        } else {
            trimmed
        }
        return withoutScope.lowercase()
    }

    private fun normalizedBaseUrlKey(raw: String): String =
        runCatching { java.net.URI(raw.trim()) }
            .getOrNull()
            ?.takeIf { !it.scheme.isNullOrBlank() }
            ?.let { uri ->
                val host = uri.host?.lowercase().orEmpty()
                val port = when {
                    uri.port > 0 -> uri.port
                    uri.scheme.equals("https", ignoreCase = true) -> 443
                    uri.scheme.equals("http", ignoreCase = true) -> 80
                    else -> -1
                }
                val path = uri.path?.trim()?.trimEnd('/').orEmpty()
                when {
                    host.isBlank() -> ""
                    port > 0 && path.isNotEmpty() -> "$host:$port$path"
                    port > 0 -> "$host:$port"
                    path.isNotEmpty() -> "$host$path"
                    else -> host
                }
            }
            ?: normalizedHostKey(raw)

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
        put("rememberedByUser", rememberedByUser)
        put("backendKind", backendKind.rawValue)
        openCodeBaseUrl?.let { put("openCodeBaseUrl", it) }
        openCodeBasicAuthUsername?.let { put("openCodeBasicAuthUsername", it) }
        openCodeBasicAuthPassword?.let { put("openCodeBasicAuthPassword", it) }
        put("openCodeKnownDirectories", JSONArray(openCodeKnownDirectories))
    }

    val availableDirectCodexPorts: List<Int>
        get() {
            if (backendKind == SavedServerBackendKind.OPEN_CODE) {
                return emptyList()
            }
            val ordered = buildList {
                if (hasCodexServer && port > 0) add(port)
                addAll(codexPorts.filter { it > 0 })
            }
            return ordered.distinct()
        }

    val resolvedPreferredConnectionMode: String?
        get() = when (backendKind) {
            SavedServerBackendKind.OPEN_CODE -> null
            SavedServerBackendKind.CODEX -> when (preferredConnectionMode) {
                "directCodex" -> if (availableDirectCodexPorts.isNotEmpty() || websocketURL != null) "directCodex" else null
                "ssh" -> if (canConnectViaSsh) "ssh" else null
                else -> if (sshPortForwardingEnabled == true) "ssh" else null
            }
        }

    val prefersSshConnection: Boolean
        get() = resolvedPreferredConnectionMode == "ssh"

    val canConnectViaSsh: Boolean
        get() = backendKind == SavedServerBackendKind.CODEX && websocketURL == null && (
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
        get() = backendKind == SavedServerBackendKind.CODEX &&
            websocketURL == null &&
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
        if (backendKind == SavedServerBackendKind.OPEN_CODE) {
            normalizedForPersistence()
        } else {
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
        }

    fun normalizedForPersistence(): SavedServer = when (backendKind) {
        SavedServerBackendKind.OPEN_CODE -> copy(
            codexPorts = emptyList(),
            preferredConnectionMode = null,
            preferredCodexPort = null,
            sshPortForwardingEnabled = null,
            websocketURL = null,
            openCodeBaseUrl = openCodeBaseUrl?.trim()?.takeIf { it.isNotEmpty() },
            openCodeBasicAuthUsername = openCodeBasicAuthUsername?.trim()?.takeIf { it.isNotEmpty() },
            openCodeBasicAuthPassword = openCodeBasicAuthPassword?.takeIf { it.isNotBlank() },
            openCodeKnownDirectories = openCodeKnownDirectories
                .map { it.trim() }
                .filter { it.isNotEmpty() }
                .distinct(),
        )
        SavedServerBackendKind.CODEX -> withPreferredConnection(
            mode = resolvedPreferredConnectionMode,
            codexPort = resolvedPreferredCodexPort ?: availableDirectCodexPorts.firstOrNull(),
        )
    }

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
            rememberedByUser = if (obj.has("rememberedByUser")) {
                obj.optBoolean("rememberedByUser")
            } else {
                true
            },
            backendKind = SavedServerBackendKind.fromRawValue(obj.optString("backendKind").ifBlank { null }),
            openCodeBaseUrl = obj.optString("openCodeBaseUrl").ifBlank { null },
            openCodeBasicAuthUsername = obj.optString("openCodeBasicAuthUsername").ifBlank { null },
            openCodeBasicAuthPassword = obj.optString("openCodeBasicAuthPassword").ifBlank { null },
            openCodeKnownDirectories = buildList {
                val directories = obj.optJSONArray("openCodeKnownDirectories")
                if (directories != null) {
                    for (index in 0 until directories.length()) {
                        add(directories.optString(index))
                    }
                }
            },
        )

        fun from(server: AppDiscoveredServer): SavedServer = SavedServer(
            id = server.id,
            name = server.displayName,
            hostname = server.host,
            port = server.port.toInt(),
            codexPorts = if (server.backendKind == AppDiscoveredBackendKind.OPEN_CODE) {
                emptyList()
            } else {
                server.codexPorts.map { it.toInt() }
            },
            sshPort = if (server.backendKind == AppDiscoveredBackendKind.OPEN_CODE) {
                null
            } else {
                server.sshPort?.toInt()
            },
            source = when (server.source) {
                AppDiscoverySource.BONJOUR -> "bonjour"
                AppDiscoverySource.TAILSCALE -> "tailscale"
                AppDiscoverySource.LAN_PROBE -> "lanProbe"
                AppDiscoverySource.ARP_SCAN -> "arpScan"
                AppDiscoverySource.MANUAL -> "manual"
                AppDiscoverySource.LOCAL -> "local"
            },
            hasCodexServer = server.backendKind != AppDiscoveredBackendKind.OPEN_CODE &&
                (server.codexPort != null || server.codexPorts.isNotEmpty()),
            os = if (server.sshBanner != null) server.os else server.os,
            sshBanner = server.sshBanner,
            backendKind = when (server.backendKind) {
                AppDiscoveredBackendKind.OPEN_CODE -> SavedServerBackendKind.OPEN_CODE
                AppDiscoveredBackendKind.CODEX -> SavedServerBackendKind.CODEX
            },
            openCodeBaseUrl = server.opencodeBaseUrl,
        )
    }
}

fun SavedServer.toRecord() = SavedServerRecord(
    id = id,
    name = name,
    hostname = hostname,
    port = port.toUShort(),
    codexPorts = codexPorts.map { it.toUShort() },
    sshPort = sshPort?.toUShort(),
    source = source,
    hasCodexServer = hasCodexServer,
    wakeMac = wakeMAC,
    preferredConnectionMode = preferredConnectionMode,
    preferredCodexPort = preferredCodexPort?.toUShort(),
    sshPortForwardingEnabled = sshPortForwardingEnabled,
    websocketUrl = websocketURL,
    rememberedByUser = rememberedByUser,
    backendKind = when (backendKind) {
        SavedServerBackendKind.OPEN_CODE -> SavedServerBackendKindRecord.OPEN_CODE
        SavedServerBackendKind.CODEX -> SavedServerBackendKindRecord.CODEX
    },
    opencodeBaseUrl = openCodeBaseUrl,
    opencodeBasicAuthUsername = openCodeBasicAuthUsername,
    opencodeBasicAuthPassword = openCodeBasicAuthPassword,
    opencodeKnownDirectories = openCodeKnownDirectories.map(::SavedOpenCodeDirectoryScopeRecord),
)

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
        val prior = existing.firstOrNull { it.id == server.id || it.deduplicationKey == server.deduplicationKey }
        existing.removeAll { it.id == server.id || it.deduplicationKey == server.deduplicationKey }
        existing.add(server.copy(rememberedByUser = prior?.rememberedByUser ?: server.rememberedByUser))
        save(context, existing)
    }

    fun remember(context: Context, server: SavedServer) {
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == server.id || it.deduplicationKey == server.deduplicationKey }
        existing.add(server.copy(rememberedByUser = true))
        save(context, existing)
    }

    fun remembered(context: Context): List<SavedServer> =
        load(context).filter { it.rememberedByUser }

    fun remove(context: Context, serverId: String) {
        val existing = load(context).toMutableList()
        existing.removeAll { it.id == serverId }
        save(context, existing)
    }

    fun server(context: Context, serverId: String): SavedServer? =
        load(context).firstOrNull { it.id == serverId }

    fun appendOpenCodeDirectory(context: Context, serverId: String, directory: String) {
        val normalizedDirectory = directory.trim()
        if (normalizedDirectory.isEmpty()) return

        val existing = load(context)
        val updated = existing.map { server ->
            if (server.id == serverId && server.backendKind == SavedServerBackendKind.OPEN_CODE) {
                val nextDirectories = (server.openCodeKnownDirectories + normalizedDirectory)
                    .map(String::trim)
                    .filter(String::isNotEmpty)
                    .distinct()
                if (nextDirectories != server.openCodeKnownDirectories) {
                    server.copy(openCodeKnownDirectories = nextDirectories)
                } else {
                    server
                }
            } else {
                server
            }
        }
        if (updated != existing) {
            save(context, updated)
        }
    }

    fun replaceOpenCodeDirectory(
        context: Context,
        serverId: String,
        previousDirectory: String,
        nextDirectory: String,
    ) {
        val normalizedPrevious = previousDirectory.trim()
        val normalizedNext = nextDirectory.trim()
        if (normalizedPrevious.isEmpty() || normalizedNext.isEmpty()) return

        val existing = load(context)
        val updated = existing.map { server ->
            if (server.id == serverId && server.backendKind == SavedServerBackendKind.OPEN_CODE) {
                val nextDirectories = server.openCodeKnownDirectories
                    .map { directory ->
                        if (directory.trim() == normalizedPrevious) normalizedNext else directory.trim()
                    }
                    .filter(String::isNotEmpty)
                    .distinct()
                server.copy(openCodeKnownDirectories = nextDirectories)
            } else {
                server
            }
        }
        if (updated != existing) {
            save(context, updated)
        }
    }

    fun removeOpenCodeDirectory(context: Context, serverId: String, directory: String) {
        val normalizedDirectory = directory.trim()
        if (normalizedDirectory.isEmpty()) return

        val existing = load(context)
        val updated = existing.map { server ->
            if (server.id == serverId && server.backendKind == SavedServerBackendKind.OPEN_CODE) {
                server.copy(
                    openCodeKnownDirectories = server.openCodeKnownDirectories
                        .map(String::trim)
                        .filter { it.isNotEmpty() && it != normalizedDirectory },
                )
            } else {
                server
            }
        }
        if (updated != existing) {
            save(context, updated)
        }
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

    fun updateWakeMac(context: Context, serverId: String, host: String, wakeMac: String?) {
        val normalizedWakeMac = SavedServer.normalizeWakeMac(wakeMac) ?: return
        val existing = load(context)
        val updated = existing.map { server ->
            if (server.id == serverId || normalizedHostKey(server.hostname) == normalizedHostKey(host)) {
                if (server.wakeMAC != normalizedWakeMac) server.copy(wakeMAC = normalizedWakeMac) else server
            } else {
                server
            }
        }
        if (updated != existing) {
            save(context, updated)
        }
    }

    private fun normalizedHostKey(host: String): String {
        val trimmed = host.trim().trimStart('[').trimEnd(']').replace("%25", "%")
        val withoutScope = if (!trimmed.contains(":")) {
            trimmed.substringBefore('%')
        } else {
            trimmed
        }
        return withoutScope.lowercase()
    }
}
