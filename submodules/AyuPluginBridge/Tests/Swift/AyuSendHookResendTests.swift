import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// `complete` in the send-message hook's parameters: what lets a plugin send the delivered object again.
final class AyuSendHookResendTests: XCTestCase {
    func testOnlyAWholeDescriptionIsMarkedComplete() {
        var message = AyuPluginTelegramHookedMessage(peer: -77)
        message.message = ".wiki cats"
        XCTAssertNil(AyuPluginTelegramBridge.hookParameters(message)["complete"], "A backend that does not say so describes a part")

        message.isComplete = true
        XCTAssertEqual(AyuPluginTelegramBridge.hookParameters(message)["complete"], .bool(true))

        // A reply the plugin sees as its message is part of the description...
        message.replyTo = AyuPluginTelegramMessageReference(dialogID: -77, messageID: 31, message: Data([1, 2, 3, 4]))
        message.replyToMessageID = 31
        let described = AyuPluginTelegramBridge.hookParameters(message)
        XCTAssertEqual(described["complete"], .bool(true))
        XCTAssertNotNil(described["replyToMsg"])

        // ...and one an earlier plugin of the chain moved is only an id, which the object cannot carry.
        message.replyToMessageID = 40
        let moved = AyuPluginTelegramBridge.hookParameters(message)
        XCTAssertNil(moved["complete"])
        XCTAssertNil(moved["replyToMsg"])

        message.replyToMessageID = 31
        message.replyToTopMessageID = 5
        XCTAssertNil(AyuPluginTelegramBridge.hookParameters(message)["complete"])
    }
}
