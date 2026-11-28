import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// The decisions the app's Telegram adapter delegates to this module: dialog
/// ids, what an outgoing message or an edit asks for, and what is refused.
final class AyuPluginTelegramBackendSupportTests: XCTestCase {
    private func message(_ peer: Int64 = 5, _ configure: (inout AyuPluginTelegramOutgoingMessage) -> Void) -> AyuPluginTelegramOutgoingMessage {
        var message = AyuPluginTelegramOutgoingMessage(peer: peer)
        configure(&message)
        return message
    }

    private func failure(_ message: AyuPluginTelegramOutgoingMessage) -> AyuPluginTelegramBackendError? {
        do { _ = try AyuPluginTelegramSendPlan(message); return nil } catch { return error as? AyuPluginTelegramBackendError }
    }

    private func isInvalid(_ error: AyuPluginTelegramBackendError?) -> Bool {
        if case .invalidArguments = error { return true }
        return false
    }

    private let tl = Data([1, 2, 3, 4])

    func testDialogIdsNameUsersAndChatsAndRefuseEverythingElse() {
        XCTAssertEqual(AyuPluginTelegramDialog(dialogID: 5), .user(5))
        XCTAssertEqual(AyuPluginTelegramDialog(dialogID: -5), .chat(5))
        XCTAssertEqual(AyuPluginTelegramDialog(dialogID: AyuPluginTelegramDialog.maximumPeerID), .user((1 << 52) - 1))
        XCTAssertEqual(AyuPluginTelegramDialog(dialogID: -AyuPluginTelegramDialog.maximumPeerID), .chat((1 << 52) - 1))
        // Zero, the next id past the range, Int64 extremes, and Android's
        // encrypted-chat (bit 62) and folder (bit 61) dialog ids.
        for refused: Int64 in [0, 1 << 52, -(1 << 52), .max, .min, 0x4000_0000_0000_0001, 0x2000_0000_0000_0001] {
            XCTAssertNil(AyuPluginTelegramDialog(dialogID: refused), "\(refused)")
        }
        for id: Int64 in [1, 777, -1, -1_234_567_890_123] {
            XCTAssertEqual(AyuPluginTelegramDialog(dialogID: id)?.dialogID, id)
        }
        XCTAssertTrue(AyuPluginTelegramDialog.isPeerID(1))
        XCTAssertFalse(AyuPluginTelegramDialog.isPeerID(0))
        XCTAssertFalse(AyuPluginTelegramDialog.isPeerID(1 << 52))
    }

    func testTextMessagePlanCarriesEveryHonouredOption() throws {
        let reply = AyuPluginTelegramMessageReference(dialogID: -9, messageID: 44, message: self.tl)
        let top = AyuPluginTelegramMessageReference(dialogID: -7, messageID: 3, message: self.tl)
        let plan = try AyuPluginTelegramSendPlan(self.message(-7) {
            $0.keys = ["effect_id", "entities", "invert_media", "message", "notify", "peer", "replyToMsg", "replyToTopMsg", "scheduleDate", "scheduleRepeatPeriod", "searchLinks"]
            $0.message = "hello"
            $0.entities = [self.tl]
            $0.replyTo = reply
            $0.replyToTop = top
            $0.booleans = ["notify": false, "searchLinks": false, "invert_media": true]
            $0.integers = ["scheduleDate": 2_000_000_000, "scheduleRepeatPeriod": 86_400, "effect_id": -3]
        })
        XCTAssertEqual(plan.dialog, .chat(7))
        XCTAssertEqual(plan.text, "hello")
        XCTAssertEqual(plan.entities, [self.tl])
        XCTAssertEqual(plan.media, .none)
        XCTAssertEqual(plan.reply?.dialog, .chat(9))
        XCTAssertEqual(plan.reply?.messageID, 44)
        XCTAssertEqual(plan.threadMessageID, 3)
        XCTAssertTrue(plan.silent)
        XCTAssertTrue(plan.disablesLinkPreview)
        XCTAssertTrue(plan.invertsMedia)
        XCTAssertEqual(plan.scheduleDate, 2_000_000_000)
        XCTAssertEqual(plan.scheduleRepeatPeriod, 86_400)
        XCTAssertEqual(plan.effectID, -3)
        XCTAssertFalse(plan.hasSpoiler)
        XCTAssertFalse(plan.highQuality)
    }

    func testDefaultsLeaveEveryOptionOff() throws {
        let plan = try AyuPluginTelegramSendPlan(self.message { $0.message = "x"; $0.booleans = ["notify": true, "searchLinks": true]; $0.integers = ["scheduleDate": 0, "effect_id": 0] })
        XCTAssertFalse(plan.silent)
        XCTAssertFalse(plan.disablesLinkPreview)
        XCTAssertNil(plan.scheduleDate)
        XCTAssertNil(plan.scheduleRepeatPeriod)
        XCTAssertNil(plan.effectID)
        XCTAssertNil(plan.reply)
        XCTAssertNil(plan.threadMessageID)
    }

    func testAttachmentsResolveToOneMedia() throws {
        let photo = try AyuPluginTelegramSendPlan(self.message { $0.path = "/c/a.jpg"; $0.attachment = .photo; $0.caption = "cap"; $0.booleans = ["sendingHighQuality": true, "hasMediaSpoilers": true] })
        XCTAssertEqual(photo.media, .file(path: "/c/a.jpg", kind: .photo, description: nil))
        XCTAssertEqual(photo.text, "cap")
        XCTAssertTrue(photo.highQuality)
        XCTAssertTrue(photo.hasSpoiler)

        let captionless = try AyuPluginTelegramSendPlan(self.message { $0.path = "/c/a.bin"; $0.attachment = .document })
        XCTAssertEqual(captionless.text, "")
        XCTAssertEqual(captionless.media, .file(path: "/c/a.bin", kind: .document, description: nil))

        let described = try AyuPluginTelegramSendPlan(self.message { $0.path = "/c/a.ogg"; $0.objects = ["document": self.tl] })
        XCTAssertEqual(described.media, .file(path: "/c/a.ogg", kind: .document, description: self.tl))
        let describedAudio = try AyuPluginTelegramSendPlan(self.message { $0.path = "/c/a.ogg"; $0.attachment = .audio; $0.objects = ["document": self.tl] })
        XCTAssertEqual(describedAudio.media, .file(path: "/c/a.ogg", kind: .audio, description: self.tl))
        let describedPhoto = try AyuPluginTelegramSendPlan(self.message { $0.path = "/c/a.jpg"; $0.objects = ["photo": self.tl] })
        XCTAssertEqual(describedPhoto.media, .file(path: "/c/a.jpg", kind: .photo, description: self.tl))

        let existingDocument = try AyuPluginTelegramSendPlan(self.message { $0.objects = ["document": self.tl]; $0.caption = "c"; $0.entities = [self.tl] })
        XCTAssertEqual(existingDocument.media, .document(self.tl))
        XCTAssertEqual(existingDocument.entities, [self.tl])
        let existingPhoto = try AyuPluginTelegramSendPlan(self.message { $0.objects = ["photo": self.tl]; $0.booleans = ["hasMediaSpoilers": true] })
        XCTAssertEqual(existingPhoto.media, .photo(self.tl))
        XCTAssertTrue(existingPhoto.hasSpoiler)
    }

    func testContradictoryOrIncompleteRequestsAreInvalidNotGuessed() {
        let cases: [(String, AyuPluginTelegramOutgoingMessage)] = [
            ("no text", self.message { _ in }),
            ("empty text", self.message { $0.message = "" }),
            ("caption without attachment", self.message { $0.message = "x"; $0.caption = "y" }),
            ("caption alone", self.message { $0.caption = "y" }),
            ("message with attachment", self.message { $0.message = "x"; $0.path = "/c/a"; $0.attachment = .document }),
            ("attach without path", self.message { $0.message = "x"; $0.attachment = .photo }),
            ("path alone", self.message { $0.path = "/c/a" }),
            ("document and photo", self.message { $0.objects = ["document": self.tl, "photo": self.tl] }),
            ("photo description of a video", self.message { $0.path = "/c/a"; $0.attachment = .video; $0.objects = ["photo": self.tl] }),
            ("document description of a photo", self.message { $0.path = "/c/a"; $0.attachment = .photo; $0.objects = ["document": self.tl] }),
            ("entities without text", self.message { $0.path = "/c/a"; $0.attachment = .document; $0.entities = [self.tl] }),
            ("peer out of range", self.message(1 << 60) { $0.message = "x" }),
            ("reply to an unsent message", self.message { $0.message = "x"; $0.replyTo = .init(dialogID: 5, messageID: 0, message: self.tl) }),
            ("reply in an unknown dialog", self.message { $0.message = "x"; $0.replyTo = .init(dialogID: .min, messageID: 4, message: self.tl) }),
            ("thread of another dialog", self.message { $0.message = "x"; $0.replyToTop = .init(dialogID: 6, messageID: 4, message: self.tl) }),
            ("spoiler on text", self.message { $0.message = "x"; $0.booleans = ["hasMediaSpoilers": true] }),
            ("spoiler on a document file", self.message { $0.path = "/c/a"; $0.attachment = .document; $0.booleans = ["hasMediaSpoilers": true] }),
            ("high quality without a photo file", self.message { $0.objects = ["photo": self.tl]; $0.booleans = ["sendingHighQuality": true] }),
            ("repeat without a date", self.message { $0.message = "x"; $0.integers = ["scheduleRepeatPeriod": 60] }),
            ("date past int32", self.message { $0.message = "x"; $0.integers = ["scheduleDate": Int64(Int32.max) + 1] }),
        ]
        for (name, message) in cases {
            XCTAssertTrue(self.isInvalid(self.failure(message)), name)
        }
    }

    func testEveryParameterOutsideThePlanIsRefusedByName() {
        let all = AyuPluginTelegramBridge.sendMessageParameters
        XCTAssertTrue(AyuPluginTelegramSendPlan.supportedParameters.isSubset(of: all))
        let refused = all.subtracting(AyuPluginTelegramSendPlan.supportedParameters)
        XCTAssertEqual(refused, ["ttl", "quick_reply_shortcut_id", "monoForumPeer", "payStars", "stars", "dice_stake", "updateStickersOrder", "params",
                                 "location", "poll", "game", "invoice", "mediaWebPage", "webPage", "replyMarkup", "user", "todo", "cover", "richMessage"])
        for key in refused {
            var message = self.message { $0.message = "x" }
            // The bridge files a key under the collection of its type.
            switch key {
            case "params": message.parameters = ["a": "b"]
            case "updateStickersOrder": message.booleans[key] = true
            case "ttl", "quick_reply_shortcut_id", "monoForumPeer", "payStars", "stars", "dice_stake": message.integers[key] = 1
            default: message.objects[key] = self.tl
            }
            XCTAssertEqual(self.failure(message), .unsupported("telegram.send_message parameter " + key), key)
            // Also when it is only named in `keys`.
            XCTAssertEqual(self.failure(self.message { $0.message = "x"; $0.keys = [key, "message", "peer"] }), .unsupported("telegram.send_message parameter " + key), key)
        }
    }

    func testEditPlan() throws {
        var edit = AyuPluginTelegramMessageEdit(dialogID: -8, messageID: 12)
        edit.text = "new"
        edit.entities = [self.tl]
        edit.attachment = .init(kind: .video, path: "/c/v.mp4", spoiler: true)
        let plan = try AyuPluginTelegramEditPlan(edit)
        XCTAssertEqual(plan.dialog, .chat(8))
        XCTAssertEqual(plan.messageID, 12)
        XCTAssertEqual(plan.text, "new")
        XCTAssertEqual(plan.entities, [self.tl])
        XCTAssertEqual(plan.attachment, edit.attachment)

        func failure(_ configure: (inout AyuPluginTelegramMessageEdit) -> Void, dialog: Int64 = 5, id: Int32 = 1) -> AyuPluginTelegramBackendError? {
            var edit = AyuPluginTelegramMessageEdit(dialogID: dialog, messageID: id)
            configure(&edit)
            do { _ = try AyuPluginTelegramEditPlan(edit); return nil } catch { return error as? AyuPluginTelegramBackendError }
        }
        XCTAssertNil(failure { $0.text = "" })
        XCTAssertEqual(failure { $0.text = "x"; $0.parameters = ["a": "b"] }, .unsupported("telegram.edit_message parameter params"))
        XCTAssertTrue(self.isInvalid(failure { _ in }))
        XCTAssertTrue(self.isInvalid(failure { $0.attachment = .init(kind: .photo, path: "/c/a", spoiler: false); $0.entities = [self.tl] }))
        XCTAssertTrue(self.isInvalid(failure({ $0.text = "x" }, dialog: 0)))
        XCTAssertTrue(self.isInvalid(failure({ $0.text = "x" }, id: 0)))
        XCTAssertTrue(self.isInvalid(failure({ $0.text = "x" }, id: -4)))
    }

    func testConnectionStatusFollowsAndroid() {
        typealias Status = AyuPluginTelegramConnectionState.Status
        XCTAssertEqual(Status(networkAvailable: false, connected: false, updating: false, usesProxy: true), .waitingForNetwork)
        XCTAssertEqual(Status(networkAvailable: true, connected: false, updating: false, usesProxy: false), .connecting)
        XCTAssertEqual(Status(networkAvailable: true, connected: false, updating: false, usesProxy: true), .connectingToProxy)
        XCTAssertEqual(Status(networkAvailable: true, connected: true, updating: true, usesProxy: true), .updating)
        XCTAssertEqual(Status(networkAvailable: true, connected: true, updating: false, usesProxy: false), .connected)
        XCTAssertEqual([Status.connecting, .waitingForNetwork, .connected, .connectingToProxy, .updating].map(\.rawValue), [1, 2, 3, 4, 5])
    }
}
