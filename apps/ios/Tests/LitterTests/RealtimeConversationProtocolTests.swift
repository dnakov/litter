import XCTest
@testable import Litter

final class RealtimeConversationProtocolTests: XCTestCase {
    func testConfigBatchWriteParamsEncodeReloadUserConfig() throws {
        let params = ConfigBatchWriteParams(
            edits: [
                ConfigEdit(
                    keyPath: "features.realtime_conversation",
                    value: AnyEncodable(true),
                    mergeStrategy: "upsert"
                )
            ],
            filePath: nil,
            expectedVersion: nil,
            reloadUserConfig: true
        )

        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let edits = try XCTUnwrap(json["edits"] as? [[String: Any]])
        let edit = try XCTUnwrap(edits.first)

        XCTAssertEqual(edit["keyPath"] as? String, "features.realtime_conversation")
        XCTAssertEqual(edit["mergeStrategy"] as? String, "upsert")
        XCTAssertEqual(edit["value"] as? Bool, true)
        XCTAssertEqual(json["reloadUserConfig"] as? Bool, true)
    }

    func testAppStartRealtimeSessionRequestEncodeCamelCaseKeys() throws {
        let params = AppStartRealtimeSessionRequest(
            threadId: "thread-123",
            prompt: "hello",
            sessionId: "session-456"
        )

        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["threadId"] as? String, "thread-123")
        XCTAssertEqual(json["prompt"] as? String, "hello")
        XCTAssertEqual(json["sessionId"] as? String, "session-456")
    }

    func testThreadRealtimeOutputAudioNotificationDecodesAudioChunk() throws {
        let data = try XCTUnwrap(
            """
            {
              "threadId": "thread-123",
              "audio": {
                "data": "AQID",
                "sampleRate": 24000,
                "numChannels": 1,
                "samplesPerChannel": 512
              }
            }
            """.data(using: .utf8)
        )

        let notification = try JSONDecoder().decode(AppRealtimeOutputAudioDeltaNotification.self, from: data)

        XCTAssertEqual(notification.threadId, "thread-123")
        XCTAssertEqual(notification.audio.data, "AQID")
        XCTAssertEqual(notification.audio.sampleRate, 24_000)
        XCTAssertEqual(notification.audio.numChannels, 1)
        XCTAssertEqual(notification.audio.samplesPerChannel, 512)
    }

    func testThreadRealtimeItemAddedNotificationPreservesMessagePayload() throws {
        let data = try XCTUnwrap(
            """
            {
              "threadId": "thread-123",
              "item": {
                "type": "message",
                "role": "assistant",
                "content": [
                  { "type": "text", "text": "hi there" }
                ]
              }
            }
            """.data(using: .utf8)
        )

        let notification = try JSONDecoder().decode(ThreadRealtimeItemAddedNotification.self, from: data)
        let item = try XCTUnwrap(notification.item.value as? [String: Any])
        let content = try XCTUnwrap(item["content"] as? [[String: Any]])

        XCTAssertEqual(notification.threadId, "thread-123")
        XCTAssertEqual(item["type"] as? String, "message")
        XCTAssertEqual(item["role"] as? String, "assistant")
        XCTAssertEqual(content.first?["text"] as? String, "hi there")
    }
}
