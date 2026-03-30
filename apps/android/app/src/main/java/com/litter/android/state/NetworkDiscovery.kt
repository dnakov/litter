package com.litter.android.state

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import uniffi.codex_mobile_client.DiscoveryBridge
import uniffi.codex_mobile_client.AppDiscoveredServer
import uniffi.codex_mobile_client.AppMdnsSeed
import uniffi.codex_mobile_client.ProgressiveDiscoveryUpdateKind
import java.net.Inet4Address
import java.net.NetworkInterface
import kotlin.coroutines.resume

/**
 * Orchestrates server discovery using Android NSD + Rust discovery bridge.
 * NSD provides mDNS seeds, Rust handles Tailscale, LAN probing, merging, and dedup.
 */
class NetworkDiscovery(private val discovery: DiscoveryBridge) {

    private val _servers = MutableStateFlow<List<AppDiscoveredServer>>(emptyList())
    val servers: StateFlow<List<AppDiscoveredServer>> = _servers.asStateFlow()

    private val _isScanning = MutableStateFlow(false)
    val isScanning: StateFlow<Boolean> = _isScanning.asStateFlow()

    private val _scanProgress = MutableStateFlow(0f)
    val scanProgress: StateFlow<Float> = _scanProgress.asStateFlow()

    private val _scanProgressLabel = MutableStateFlow<String?>(null)
    val scanProgressLabel: StateFlow<String?> = _scanProgressLabel.asStateFlow()

    private val scope = CoroutineScope(Dispatchers.IO)
    private var scanJob: Job? = null

    fun startScanning(context: Context) {
        if (scanJob?.isActive == true) return
        scanJob = scope.launch {
            _isScanning.value = true
            _scanProgress.value = 0f
            _scanProgressLabel.value = "Discovering services…"
            try {
                // 1. Discover mDNS seeds via Android NSD
                val seeds = discoverMdnsSeeds(context)

                // 2. Get local IPv4
                val localIp = localIpv4Address()

                _scanProgress.value = 0.02f
                _scanProgressLabel.value = "Scanning network…"

                // 3. Consume progressive Rust discovery batches as each source completes.
                val subscription = discovery.scanServersWithMdnsContextProgressive(seeds, localIp)
                while (true) {
                    val update = subscription.nextEvent()
                    _servers.value = update.servers
                    _scanProgress.value = update.progress
                    update.progressLabel?.let { _scanProgressLabel.value = it }
                    if (update.kind == ProgressiveDiscoveryUpdateKind.SCAN_COMPLETE) {
                        break
                    }
                }
            } catch (_: Exception) {
                // Best-effort discovery
            } finally {
                _isScanning.value = false
            }
        }
    }

    fun stopScanning() {
        scanJob?.cancel()
        scanJob = null
        _isScanning.value = false
    }

    /**
     * Browse for _ssh._tcp. and _codex._tcp. services via Android NSD.
     * Returns resolved seeds for Rust to process.
     */
    private suspend fun discoverMdnsSeeds(context: Context): List<AppMdnsSeed> {
        val nsdManager = context.getSystemService(Context.NSD_SERVICE) as? NsdManager
            ?: return emptyList()

        val serviceTypes = listOf("_ssh._tcp.", "_codex._tcp.")
        return coroutineScope {
            serviceTypes.map { serviceType ->
                async {
                    val discovered = withTimeoutOrNull(4500L) {
                        discoverServices(nsdManager, serviceType)
                    } ?: emptyList()

                    discovered.map { service ->
                        async {
                            withTimeoutOrNull(2000L) {
                                resolveService(nsdManager, service)
                            }?.let { resolved ->
                                val host = resolved.host?.hostAddress ?: return@let null
                                AppMdnsSeed(
                                    name = resolved.serviceName,
                                    host = host,
                                    port = resolved.port.toUShort(),
                                    serviceType = serviceType,
                                )
                            }
                        }
                    }.awaitAll().filterNotNull()
                }
            }.awaitAll().flatten()
        }
    }

    private suspend fun discoverServices(
        nsdManager: NsdManager,
        serviceType: String,
    ): List<NsdServiceInfo> = suspendCancellableCoroutine { cont ->
        val found = mutableListOf<NsdServiceInfo>()
        val listener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(regType: String) {}
            override fun onServiceFound(service: NsdServiceInfo) {
                found.add(service)
            }
            override fun onServiceLost(service: NsdServiceInfo) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                if (cont.isActive) cont.resume(emptyList())
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }

        try {
            nsdManager.discoverServices(serviceType, NsdManager.PROTOCOL_DNS_SD, listener)
        } catch (_: Exception) {
            cont.resume(emptyList())
            return@suspendCancellableCoroutine
        }

        // Wait for discoveries then stop
        scope.launch {
            delay(4000)
            try { nsdManager.stopServiceDiscovery(listener) } catch (_: Exception) {}
            if (cont.isActive) cont.resume(found.toList())
        }

        cont.invokeOnCancellation {
            try { nsdManager.stopServiceDiscovery(listener) } catch (_: Exception) {}
        }
    }

    private suspend fun resolveService(
        nsdManager: NsdManager,
        service: NsdServiceInfo,
    ): NsdServiceInfo? = suspendCancellableCoroutine { cont ->
        nsdManager.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(service: NsdServiceInfo, errorCode: Int) {
                if (cont.isActive) cont.resume(null)
            }
            override fun onServiceResolved(resolved: NsdServiceInfo) {
                if (cont.isActive) cont.resume(resolved)
            }
        })
    }

    companion object {
        fun localIpv4Address(): String? {
            try {
                for (iface in NetworkInterface.getNetworkInterfaces()) {
                    if (!iface.isUp || iface.isLoopback) continue
                    val name = iface.name
                    if (!name.startsWith("wlan") && !name.startsWith("en")) continue
                    for (addr in iface.inetAddresses) {
                        if (addr is Inet4Address && !addr.isLoopbackAddress) {
                            return addr.hostAddress
                        }
                    }
                }
            } catch (_: Exception) {}
            return null
        }
    }
}
