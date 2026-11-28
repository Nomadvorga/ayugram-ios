import Foundation
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// DTO and send-adapter regressions with a fixture transport. No interpreter,
/// account or network. Source-only until the iOS test runner; a build is not a
/// test run.
final class AyuBridgeMessageAdapterTests: XCTestCase {
    private struct FixtureTransport: AyuBridgeMessageTransport {
        var onSend: @Sendable (AyuBridgeOutgoingMessage) async throws -> AyuBridgeIncomingMessage = { request in
            AyuBridgeIncomingMessage(accountID: request.accountID, chatID: request.chatID, messageID: 1, senderID: 42, text: request.text, entities: request.entities, date: Date(timeIntervalSince1970: 100), isOutgoing: true)
        }
        var onEdit: @Sendable (AyuBridgeEditMessageRequest) async throws -> AyuBridgeIncomingMessage = { _ in
            AyuBridgeIncomingMessage(accountID: 1, chatID: 2, messageID: 3, senderID: 42, text: "edited", entities: [], date: Date(timeIntervalSince1970: 200), isOutgoing: true)
        }
        var onDelete: @Sendable (Int64, Int64, Int64) async throws -> Void = { _, _, _ in }
        func send(_ request: AyuBridgeOutgoingMessage) async throws -> AyuBridgeIncomingMessage { try await self.onSend(request) }
        func edit(_ request: AyuBridgeEditMessageRequest) async throws -> AyuBridgeIncomingMessage { try await self.onEdit(request) }
        func delete(accountID: Int64, chatID: Int64, messageID: Int64) async throws { try await self.onDelete(accountID, chatID, messageID) }
    }

    private func adapter(_ transport: FixtureTransport = FixtureTransport()) -> AyuBridgeMessageAdapter {
        AyuBridgeMessageAdapter(transport: transport, hooks: AyuBridgeHookRegistry())
    }

    private func message(text: String = "hi", silent: Bool = false, schedule: Date? = nil) -> AyuBridgeOutgoingMessage {
        AyuBridgeOutgoingMessage(accountID: 1, chatID: 2, text: text, silent: silent, scheduleDate: schedule)
    }

    func testUTF16OffsetsAcrossAstralEmoji() {
        let text = "😀ab"
        let offsets = AyuBridgeEntityOffsets.utf16Offset(characterOffset: 1, characterLength: 2, in: text)
        XCTAssertEqual(offsets.offset, 2)
        XCTAssertEqual(offsets.length, 2)
        let back = AyuBridgeEntityOffsets.characterOffset(utf16Offset: offsets.offset, utf16Length: offsets.length, in: text)
        XCTAssertEqual(back.offset, 1)
        XCTAssertEqual(back.length, 2)
    }

    func testEntityValidationUsesUTF16Lengths() {
        let text = "😀x"
        let length = (text as NSString).length
        var request = self.message(text: text)
        request.entities = [AyuBridgeMessageEntity(kind: .bold, offset: 0, length: Int32(length))]
        XCTAssertNoThrow(try request.validate())
        request.entities = [AyuBridgeMessageEntity(kind: .bold, offset: 0, length: Int32(length + 1))]
        XCTAssertThrowsError(try request.validate()) { error in
            XCTAssertEqual(error as? AyuBridgeMessageError, .entityOutOfRange(index: 0))
        }
    }

    func testSilentAndScheduleAreMutuallyExclusive() {
        let future = Date(timeIntervalSinceNow: 60)
        XCTAssertThrowsError(try self.message(silent: true, schedule: future).validate()) { error in
            XCTAssertEqual(error as? AyuBridgeMessageError, .silentAndScheduleConflict)
        }
        XCTAssertNoThrow(try self.message(schedule: future).validate())
        XCTAssertThrowsError(try self.message(schedule: Date(timeIntervalSinceNow: -60)).validate()) { error in
            guard case let AyuBridgeMessageError.scheduleInPast(date) = error as! AyuBridgeMessageError else { return XCTFail("wrong error") }
            XCTAssertLessThan(date, Date())
        }
    }

    func testEmptyContentIsRejected() {
        XCTAssertThrowsError(try self.message(text: "").validate()) { error in
            XCTAssertEqual(error as? AyuBridgeMessageError, .emptyText)
        }
        var mediaOnly = AyuBridgeOutgoingMessage(accountID: 1, chatID: 2)
        mediaOnly.media = [.object(["file": .string("photo.jpg")])]
        XCTAssertNoThrow(try mediaOnly.validate())
    }

    func testSendRunsPreAndPostHooksAroundTransport() async throws {
        let events = HookRecorder()
        let hooks = AyuBridgeHookRegistry()
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { payload in
            events.append("pre")
            return .proceed
        }
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPost, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { payload in
            events.append("post")
            return .proceed
        }
        let adapter = AyuBridgeMessageAdapter(transport: FixtureTransport(), hooks: hooks)
        let sent = try await adapter.send(self.message())
        XCTAssertEqual(events.log, ["pre", "post"])
        XCTAssertEqual(sent.messageID, 1)
    }

    private final class HookRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        var log: [String] {
            self.lock.lock(); defer { self.lock.unlock() }
            return self.values
        }
        func append(_ value: String) {
            self.lock.lock(); defer { self.lock.unlock() }
            self.values.append(value)
        }
    }

    func testPreHookCancellationBlocksSend() async throws {
        let hooks = AyuBridgeHookRegistry()
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { _ in .cancel("nope") }
        let adapter = AyuBridgeMessageAdapter(transport: FixtureTransport(), hooks: hooks)
        do {
            _ = try await adapter.send(self.message())
            XCTFail("cancelled send must throw")
        } catch let error as AyuBridgeMessageError {
            XCTAssertEqual(error, .missingCapability(name: "send.cancelled", reason: "nope"))
        }
    }

    func testPreHookReplacementReachesTransport() async throws {
        let hooks = AyuBridgeHookRegistry()
        let seen = HookRecorder()
        let transport = FixtureTransport(onSend: { request in
            seen.append(request.text ?? "")
            return AyuBridgeIncomingMessage(accountID: 1, chatID: 2, messageID: 9, senderID: 1, text: request.text, entities: [], date: Date(), isOutgoing: true)
        })
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { payload in
            var updated = payload
            if case var .object(request) = payload["request"] {
                request["text"] = .string("hooked")
                updated["request"] = .object(request)
            }
            return .replace(updated)
        }
        let adapter = AyuBridgeMessageAdapter(transport: transport, hooks: hooks)
        let sent = try await adapter.send(self.message(text: "original"))
        XCTAssertEqual(seen.log, ["hooked"])
        XCTAssertEqual(sent.messageID, 9)
    }

    func testEditKeepsEntitiesWhenNilAndValidatesWhenGiven() async throws {
        let seen = HookRecorder()
        let transport = FixtureTransport(onEdit: { request in
            seen.append(request.entities.map { String($0.count) } ?? "nil")
            return AyuBridgeIncomingMessage(accountID: 1, chatID: 2, messageID: 3, senderID: 1, text: request.text ?? "edited", entities: request.entities ?? [], date: Date(), isOutgoing: true)
        })
        let adapter = self.adapter(transport)
        _ = try await adapter.edit(AyuBridgeEditMessageRequest(accountID: 1, chatID: 2, messageID: 3, text: "new text", entities: nil))
        XCTAssertEqual(seen.log, ["nil"], "nil entities must reach the transport as keep-current")
        do {
            _ = try await adapter.edit(AyuBridgeEditMessageRequest(accountID: 1, chatID: 2, messageID: 3, text: "ab", entities: [AyuBridgeMessageEntity(kind: .bold, offset: 0, length: 99)]))
            XCTFail("out-of-range entities must throw")
        } catch let error as AyuBridgeMessageError {
            XCTAssertEqual(error, .entityOutOfRange(index: 0))
        }
        _ = try await adapter.edit(AyuBridgeEditMessageRequest(accountID: 1, chatID: 2, messageID: 3, text: "ab", entities: []))
        XCTAssertEqual(seen.log, ["nil", "0"], "empty array clears entities")
    }

    func testDeleteGoesThroughPreHookAndTransport() async throws {
        let deleted = HookRecorder()
        let transport = FixtureTransport(onDelete: { account, chat, message in
            deleted.append("\(account):\(chat):\(message)")
        })
        let hooks = AyuBridgeHookRegistry()
        _ = try hooks.subscribe(pluginID: "p", point: .messageDeletePre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.mutate")])) { payload in
            if payload["message_id"] == .integer(666) { return .cancel("protected") }
            return .proceed
        }
        let adapter = AyuBridgeMessageAdapter(transport: transport, hooks: hooks)
        try await adapter.delete(accountID: 1, chatID: 2, messageID: 7)
        XCTAssertEqual(deleted.log, ["1:2:7"])
        do { try await adapter.delete(accountID: 1, chatID: 2, messageID: 666); XCTFail("must throw") }
        catch let error as AyuBridgeMessageError { XCTAssertEqual(error, .missingCapability(name: "delete.cancelled", reason: "protected")) }
        XCTAssertEqual(deleted.log.count, 1)
    }

    private func hookResult(_ strategy: Int64, params: AyuBridgeValue = .null) -> AyuBridgeValue {
        .object(["strategy": .integer(strategy), "params": params])
    }

    private func chain(message: String? = "original", caption: String? = nil) -> AyuBridgeSendHookChain {
        AyuBridgeSendHookChain(message: message, caption: caption, peerID: -9_007_199_254_740_993, accountIndex: 9_007_199_254_740_995)
    }

    func testSendHookStrategyTagsMatchSDK() {
        XCTAssertEqual(AyuBridgeSendHookStrategy.default.rawValue, 0)
        XCTAssertEqual(AyuBridgeSendHookStrategy.cancel.rawValue, 1)
        XCTAssertEqual(AyuBridgeSendHookStrategy.modify.rawValue, 2)
        XCTAssertEqual(AyuBridgeSendHookStrategy.modifyFinal.rawValue, 3)
    }

    func testSendHookSnapshotPreservesExactContextAndLatestText() {
        var chain = self.chain()
        XCTAssertEqual(chain.arguments, [.integer(chain.accountIndex), .object(["peer": .integer(chain.peerID), "message": .string("original")])])
        chain.apply(self.hookResult(2, params: .object(["message": .string("first")])) )
        XCTAssertEqual(chain.arguments[1]["message"], .string("first"))
        chain.apply(self.hookResult(2, params: .object(["peer": .integer(chain.peerID), "message": .string("second")])) )
        XCTAssertEqual(chain.message, "second")
        XCTAssertFalse(chain.isFinished)
    }

    func testDefaultAndMalformedResultsPreserveLastValidContent() {
        let results: [AyuBridgeValue?] = [nil, .null, .array([]), .object([:]),
            .object(["strategy": .bool(true)]), .object(["strategy": .string("MODIFY")]),
            .object(["strategy": .number(2.5)]), self.hookResult(99),
            self.hookResult(0, params: .object(["message": .string("ignored")]))]
        for result in results {
            var chain = self.chain()
            chain.apply(self.hookResult(2, params: .object(["message": .string("accepted")])) )
            let before = chain
            chain.apply(result)
            XCTAssertEqual(chain, before)
        }
    }

    func testCancelStopsWithoutApplyingParamsOrLaterResults() {
        var chain = self.chain()
        chain.apply(self.hookResult(1, params: .object(["message": .string("ignored")])) )
        XCTAssertTrue(chain.isCancelled)
        XCTAssertTrue(chain.isFinished)
        XCTAssertEqual(chain.message, "original")
        chain.apply(self.hookResult(2, params: .object(["message": .string("late")])) )
        XCTAssertEqual(chain.message, "original")
    }

    func testModifyFinalStopsWithoutCancellingSend() {
        var chain = self.chain()
        chain.apply(self.hookResult(3, params: .object(["message": .string("final")])) )
        XCTAssertTrue(chain.isFinal)
        XCTAssertTrue(chain.isFinished)
        XCTAssertFalse(chain.isCancelled)
        chain.apply(self.hookResult(1))
        chain.apply(self.hookResult(2, params: .object(["message": .string("late")])) )
        XCTAssertEqual(chain.message, "final")
        XCTAssertFalse(chain.isCancelled)
    }

    func testMalformedFinalStillStopsWithLastValidContent() {
        for params in [AyuBridgeValue.null, .array([]), .object(["message": .integer(12)]), .object(["peer": .integer(0), "message": .string("injected")])] {
            var chain = self.chain()
            chain.apply(self.hookResult(2, params: .object(["message": .string("accepted")])) )
            chain.apply(self.hookResult(3, params: params))
            XCTAssertEqual(chain.message, "accepted")
            XCTAssertTrue(chain.isFinal)
            XCTAssertFalse(chain.isCancelled)
        }
    }

    func testReplacementCannotInjectContextOrUnsupportedNativeOptions() {
        for (key, value) in ["peer": AyuBridgeValue.integer(0), "account": .integer(0), "accountIndex": .integer(0),
                             "replyToMessageID": .integer(10), "silent": .bool(true), "$handle": .string("fake")] {
            var chain = self.chain()
            let before = chain
            chain.apply(self.hookResult(2, params: .object([key: value, "message": .string("injected")])) )
            XCTAssertEqual(chain, before, key)
        }
        var chain = self.chain()
        chain.apply(self.hookResult(2, params: .object(["peer": .string(String(chain.peerID)), "message": .string("injected")])) )
        XCTAssertEqual(chain.message, "original", "peer must remain an exact integer")
    }

    func testMalformedFieldsRejectTheWholeReplacement() {
        for value in [AyuBridgeValue.null, .integer(7), .bool(false), .object([:]), .array([])] {
            var chain = self.chain(message: "text", caption: "caption")
            let before = chain
            chain.apply(self.hookResult(2, params: .object(["message": .string("partly applied"), "caption": value])) )
            XCTAssertEqual(chain, before)
        }
    }

    func testMissingFieldsPreserveContentAndMediaCaptionCanBeCleared() {
        var chain = self.chain(message: nil, caption: "photo caption")
        chain.apply(self.hookResult(2, params: .object(["peer": .integer(chain.peerID)])))
        XCTAssertEqual(chain.caption, "photo caption")
        chain.apply(self.hookResult(2, params: .object(["caption": .string(""), "message": .null])))
        XCTAssertEqual(chain.caption, "")
        XCTAssertNil(chain.message)
        chain.apply(self.hookResult(2, params: .object(["message": .string("wrong slot"), "caption": .string("changed")])) )
        XCTAssertEqual(chain.caption, "")
        XCTAssertNil(chain.message)
        var text = self.chain()
        text.apply(self.hookResult(2, params: .object(["message": .string("")])))
        XCTAssertEqual(text.message, "original")
        text.apply(self.hookResult(2, params: .object(["caption": .string("wrong slot")])) )
        XCTAssertNil(text.caption)
    }

    func testStringQuotaCountsUTF8BytesAndPreservesOriginalOnOverflow() {
        let limit = AyuBridgeSendHookChain.maximumTextBytes
        var chain = self.chain()
        let boundary = String(repeating: "😀", count: limit / 4)
        chain.apply(self.hookResult(2, params: .object(["message": .string(boundary)])))
        XCTAssertEqual(chain.message, boundary)
        chain.apply(self.hookResult(2, params: .object(["message": .string(boundary + "x")])))
        XCTAssertEqual(chain.message, boundary)
        var caption = self.chain(message: nil, caption: "photo")
        caption.apply(self.hookResult(2, params: .object(["caption": .string(String(repeating: "a", count: limit + 1))])))
        XCTAssertEqual(caption.caption, "photo")
    }

    func testMalformedOrInvalidTypedSendReplacementKeepsOriginalRequest() async throws {
        let original = self.message(text: "original")
        var wrongAccount = original
        wrongAccount.accountID = 0
        var wrongChat = original
        wrongChat.chatID = 0
        var empty = original
        empty.text = ""
        var badEntities = original
        badEntities.entities = [AyuBridgeMessageEntity(kind: .bold, offset: -1, length: 1)]
        var oversized = original
        oversized.text = String(repeating: "a", count: AyuBridgeSendHookChain.maximumTextBytes + 1)
        for replacement in [AyuBridgeValue.null, .object([:]), .encodable(wrongAccount), .encodable(wrongChat), .encodable(empty), .encodable(badEntities), .encodable(oversized)] {
            let hooks = AyuBridgeHookRegistry()
            _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { _ in
                .replace(["request": replacement])
            }
            let transport = FixtureTransport(onSend: { request in
                XCTAssertEqual(request, original)
                return AyuBridgeIncomingMessage(accountID: request.accountID, chatID: request.chatID, messageID: 1, senderID: 42, text: request.text, entities: request.entities, date: Date(), isOutgoing: true)
            })
            _ = try await AyuBridgeMessageAdapter(transport: transport, hooks: hooks).send(original)
        }
    }

    func testMalformedTypedEditReplacementKeepsOriginalIdentityAndEntities() async throws {
        let original = AyuBridgeEditMessageRequest(accountID: 5, chatID: -8, messageID: 19, text: "original")
        var wrongAccount = original
        wrongAccount.accountID = 0
        var wrongChat = original
        wrongChat.chatID = 0
        var wrongMessage = original
        wrongMessage.messageID = 0
        var badEntities = original
        badEntities.entities = [AyuBridgeMessageEntity(kind: .bold, offset: -1, length: 1)]
        for replacement in [AyuBridgeValue.null, .encodable(wrongAccount), .encodable(wrongChat), .encodable(wrongMessage), .encodable(badEntities)] {
            let hooks = AyuBridgeHookRegistry()
            _ = try hooks.subscribe(pluginID: "p", point: .messageEditPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.mutate")])) { _ in
                .replace(["request": replacement])
            }
            let transport = FixtureTransport(onEdit: { request in
                XCTAssertEqual(request, original)
                return AyuBridgeIncomingMessage(accountID: request.accountID, chatID: request.chatID, messageID: request.messageID, senderID: 42, text: request.text, entities: [], date: Date(), isOutgoing: true)
            })
            _ = try await AyuBridgeMessageAdapter(transport: transport, hooks: hooks).edit(original)
        }
    }

    func testSendReplacementScheduleValidationUsesTheSuppliedClock() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let original = self.message(text: "original")
        var replacement = original
        replacement.text = "scheduled by hook"
        replacement.scheduleDate = Date(timeIntervalSince1970: 1_001)
        // Freeze the value before entering @Sendable closures; capturing a
        // mutable local would introduce a Swift concurrency diagnostic.
        let replacementValue = AyuBridgeValue.encodable(replacement)
        let hooks = AyuBridgeHookRegistry()
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { _ in
            .replace(["request": replacementValue])
        }
        let transport = FixtureTransport(onSend: { request in
            AyuBridgeIncomingMessage(accountID: request.accountID, chatID: request.chatID, messageID: 1, senderID: 42, text: request.text, entities: [], date: now, isOutgoing: true)
        })
        let adapter = AyuBridgeMessageAdapter(transport: transport, hooks: hooks)
        let futureAtSuppliedClock = try await adapter.send(original, now: now)
        XCTAssertEqual(futureAtSuppliedClock.text, "scheduled by hook")
        let pastAtSuppliedClock = try await adapter.send(original, now: Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(pastAtSuppliedClock.text, "original")
    }
}
