package com.litter.android.feature.discovery

import com.litter.android.core.network.DiscoveredServer
import com.litter.android.core.network.ServerDiscoveryService

class DiscoveryFeature(
    private val discoveryService: ServerDiscoveryService,
) {
    fun discoverServers(): List<DiscoveredServer> = discoveryService.discover()
}
