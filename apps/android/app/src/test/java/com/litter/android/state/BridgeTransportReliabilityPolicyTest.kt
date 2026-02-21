package com.litter.android.state

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BridgeTransportReliabilityPolicyTest {
    @Test
    fun healthyConnectionDoesNotReconnect() {
        assertFalse(
            BridgeTransportReliabilityPolicy.shouldReconnect(
                connected = true,
                socketConnected = true,
                socketClosed = false,
                hasInput = true,
                hasOutput = true,
                readerAlive = true,
            ),
        )
    }

    @Test
    fun deadReaderTriggersReconnect() {
        assertTrue(
            BridgeTransportReliabilityPolicy.shouldReconnect(
                connected = true,
                socketConnected = true,
                socketClosed = false,
                hasInput = true,
                hasOutput = true,
                readerAlive = false,
            ),
        )
    }

    @Test
    fun closedSocketTriggersReconnect() {
        assertTrue(
            BridgeTransportReliabilityPolicy.shouldReconnect(
                connected = true,
                socketConnected = true,
                socketClosed = true,
                hasInput = true,
                hasOutput = true,
                readerAlive = true,
            ),
        )
    }
}
