import XCTest
@testable import Litter

final class RealtimeConversationProtocolTests: XCTestCase {
    func testAppStartRealtimeSessionRequestStoresCurrentFields() {
        let params = AppStartRealtimeSessionRequest(
            threadId: "thread-123",
            prompt: "hello",
            sessionId: "session-456",
            clientControlledHandoff: true,
            dynamicTools: nil
        )

        XCTAssertEqual(params.threadId, "thread-123")
        XCTAssertEqual(params.prompt, "hello")
        XCTAssertEqual(params.sessionId, "session-456")
        XCTAssertTrue(params.clientControlledHandoff)
        XCTAssertNil(params.dynamicTools)
    }

    func testRealtimeOutputAudioNotificationStoresAudioChunk() {
        let chunk = AppRealtimeAudioChunk(
            data: "AQID",
            sampleRate: 24_000,
            numChannels: 1,
            samplesPerChannel: 512,
            itemId: "item-1"
        )
        let notification = AppRealtimeOutputAudioDeltaNotification(
            threadId: "thread-123",
            audio: chunk
        )

        XCTAssertEqual(notification.threadId, "thread-123")
        XCTAssertEqual(notification.audio.data, "AQID")
        XCTAssertEqual(notification.audio.sampleRate, 24_000)
        XCTAssertEqual(notification.audio.numChannels, 1)
        XCTAssertEqual(notification.audio.samplesPerChannel, 512)
        XCTAssertEqual(notification.audio.itemId, "item-1")
    }

    func testRealtimeErrorNotificationStoresMessage() {
        let notification = AppRealtimeErrorNotification(
            threadId: "thread-123",
            message: "mic disconnected"
        )

        XCTAssertEqual(notification.threadId, "thread-123")
        XCTAssertEqual(notification.message, "mic disconnected")
    }

    func testAppStartRealtimeSessionRequestWebrtcTransportRoundTrip() {
        let sdp = "v=0\r\no=- 12345 2 IN IP4 127.0.0.1\r\ns=-\r\n"
        let params = AppStartRealtimeSessionRequest(
            threadId: "thread-123",
            prompt: "hello",
            sessionId: "session-456",
            transport: .webrtc(sdp: sdp),
            clientControlledHandoff: true,
            dynamicTools: nil
        )

        guard case let .webrtc(roundTrippedSdp) = params.transport else {
            XCTFail("expected transport to be .webrtc, got \(String(describing: params.transport))")
            return
        }
        XCTAssertEqual(roundTrippedSdp, sdp)
    }

    func testAppRealtimeSdpNotificationDecodes() {
        let sdp = "v=0\r\no=- 999 2 IN IP4 127.0.0.1\r\ns=-\r\n"
        let notification = AppRealtimeSdpNotification(threadId: "t1", sdp: sdp)

        XCTAssertEqual(notification.threadId, "t1")
        XCTAssertEqual(notification.sdp, sdp)
    }
}
