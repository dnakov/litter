import UIKit
import XCTest
@testable import Litter

final class ConversationAttachmentSupportTests: XCTestCase {
    func testBuildTurnInputsOmitsWhitespaceOnlyTextAndKeepsAttachmentInput() {
        let attachment = AppUserInput(type: "image", imageURL: "data:image/png;base64,abc")

        let inputs = ConversationAttachmentSupport.buildTurnInputs(
            text: "   \n",
            additionalInput: [attachment]
        )

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.type, "image")
        XCTAssertEqual(inputs.first?.imageURL, "data:image/png;base64,abc")
    }

    func testImageUserInputEncodesURLForTurnStartProtocol() throws {
        let attachment = AppUserInput(type: "image", imageURL: "data:image/png;base64,abc")

        let data = try JSONEncoder().encode(attachment)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(json["type"], "image")
        XCTAssertEqual(json["url"], "data:image/png;base64,abc")
        XCTAssertNil(json["image_url"])
    }

    func testPrepareImageUsesPNGWhenImageHasTransparency() {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            UIColor.clear.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 1, y: 1, width: 2, height: 2))
        }

        let attachment = ConversationAttachmentSupport.prepareImage(image)

        XCTAssertEqual(attachment?.mimeType, "image/png")
        XCTAssertNotNil(attachment?.data)
    }

    func testPrepareImageUsesJPEGWhenImageIsOpaque() {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }

        let attachment = ConversationAttachmentSupport.prepareImage(image)

        XCTAssertEqual(attachment?.mimeType, "image/jpeg")
        XCTAssertNotNil(attachment?.data)
    }
}
