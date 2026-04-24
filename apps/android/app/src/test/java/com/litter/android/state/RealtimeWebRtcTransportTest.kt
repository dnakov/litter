package com.litter.android.state

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.codex_mobile_client.AppDynamicToolSpec
import uniffi.codex_mobile_client.AppRealtimeSdpNotification
import uniffi.codex_mobile_client.AppRealtimeStartTransport
import uniffi.codex_mobile_client.AppStartRealtimeSessionRequest

class RealtimeWebRtcTransportTest {

    @Test
    fun startRequestCarriesWebrtcTransport() {
        val offerSdp = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
        val request = AppStartRealtimeSessionRequest(
            threadId = "thread-1",
            prompt = "hi",
            sessionId = "session-1",
            transport = AppRealtimeStartTransport.Webrtc(sdp = offerSdp),
            clientControlledHandoff = true,
            dynamicTools = emptyList<AppDynamicToolSpec>(),
        )

        val transport = request.transport
        assertTrue(
            "expected Webrtc transport variant, got $transport",
            transport is AppRealtimeStartTransport.Webrtc,
        )
        assertEquals(offerSdp, (transport as AppRealtimeStartTransport.Webrtc).sdp)
    }

    @Test
    fun websocketTransportRoundTrips() {
        val request = AppStartRealtimeSessionRequest(
            threadId = "thread-2",
            prompt = "hi",
            sessionId = null,
            transport = AppRealtimeStartTransport.Websocket,
            clientControlledHandoff = false,
            dynamicTools = null,
        )

        assertEquals(AppRealtimeStartTransport.Websocket, request.transport)
    }

    @Test
    fun sdpNotificationExposesThreadAndSdp() {
        val sdp = "v=0\r\na=answer\r\n"
        val notification = AppRealtimeSdpNotification(threadId = "t1", sdp = sdp)

        assertEquals("t1", notification.threadId)
        assertEquals(sdp, notification.sdp)
    }
}
