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
            await MainActor.run { events.log.append("pre") }
            return .proceed
        }
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPost, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { payload in
            await MainActor.run { events.log.append("post") }
            return .proceed
        }
        let adapter = AyuBridgeMessageAdapter(transport: FixtureTransport(), hooks: hooks)
        let sent = try await adapter.send(self.message())
        await MainActor.run { XCTAssertEqual(events.log, ["pre", "post"]) }
        XCTAssertEqual(sent.messageID, 1)
    }

    private final class HookRecorder: @unchecked Sendable {
        var log: [String] = []
    }

    func testPreHookCancellationBlocksSend() async throws {
        let hooks = AyuBridgeHookRegistry()
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { _ in .cancel("nope") }
        let adapter = AyuBridgeMessageAdapter(transport: FixtureTransport(), hooks: hooks)
        XCTAssertThrowsError(try await adapter.send(self.message()))
    }

    func testPreHookReplacementReachesTransport() async throws {
        let hooks = AyuBridgeHookRegistry()
        let seen = ReplacementRecorder()
        let transport = FixtureTransport(onSend: { request in
            await MainActor.run { seen.text = request.text }
            return AyuBridgeIncomingMessage(accountID: 1, chatID: 2, messageID: 9, senderID: 1, text: request.text, entities: [], date: Date(), isOutgoing: true)
        })
        _ = try hooks.subscribe(pluginID: "p", point: .messageSendPre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.send")])) { payload in
            var updated = payload
            if case let .object(request) = payload["request"], var text = request["text"]?.string {
                text = "hooked"
                updated["request"] = .object([AyuBridgeValue]([]).isEmpty ? .null : request.merging(["text": .string(text)]) { a, _ in a })
            }
            return .replace(updated)
        }
        let adapter = AyuBridgeMessageAdapter(transport: transport, hooks: hooks)
        let sent = try await adapter.send(self.message(text: "original"))
        await MainActor.run { XCTAssertEqual(seen.text, "hooked") }
        XCTAssertEqual(sent.messageID, 9)
    }

    private final class ReplacementRecorder: @unchecked Sendable {
        var text: String?
    }

    func testEditKeepsEntitiesWhenNilAndValidatesWhenGiven() async throws {
        var editedEntities: [AyuBridgeMessageEntity]?
        let transport = FixtureTransport(onEdit: { request in
            editedEntities = request.entities
            return AyuBridgeIncomingMessage(accountID: 1, chatID: 2, messageID: 3, senderID: 1, text: request.text ?? "edited", entities: request.entities ?? [], date: Date(), isOutgoing: true)
        })
        let adapter = self.adapter(transport)
        _ = try await adapter.edit(AyuBridgeEditMessageRequest(accountID: 1, chatID: 2, messageID: 3, text: "new text", entities: nil))
        XCTAssertNil(editedEntities, "nil entities must reach the transport as keep-current")
        XCTAssertThrowsError(try await adapter.edit(AyuBridgeEditMessageRequest(accountID: 1, chatID: 2, messageID: 3, text: "ab", entities: [AyuBridgeMessageEntity(kind: .bold, offset: 0, length: 99)])))
        _ = try await adapter.edit(AyuBridgeEditMessageRequest(accountID: 1, chatID: 2, messageID: 3, text: "ab", entities: []))
        XCTAssertEqual(editedEntities?.count, 0, "empty array clears entities")
    }

    func testDeleteGoesThroughPreHookAndTransport() async throws {
        let deleted = DeletionRecorder()
        let transport = FixtureTransport(onDelete: { account, chat, message in
            await MainActor.run { deleted.values.append((account, chat, message)) }
        })
        let hooks = AyuBridgeHookRegistry()
        _ = try hooks.subscribe(pluginID: "p", point: .messageDeletePre, capabilities: AyuBridgeCapabilitySet([AyuBridgeCapability("messages.mutate")])) { payload in
            if payload["message_id"] == .integer(666) { return .cancel("protected") }
            return .proceed
        }
        let adapter = AyuBridgeMessageAdapter(transport: transport, hooks: hooks)
        try await adapter.delete(accountID: 1, chatID: 2, messageID: 7)
        await MainActor.run { XCTAssertEqual(deleted.values, [(1, 2, 7)]) }
        do { _ = try await adapter.delete(accountID: 1, chatID: 2, messageID: 666); XCTFail("must throw") }
        catch let error as AyuBridgeMessageError { XCTAssertEqual(error, .missingCapability(name: "delete.cancelled", "protected")) }
        await MainActor.run { XCTAssertEqual(deleted.values.count, 1) }
    }

    private final class DeletionRecorder: @unchecked Sendable {
        var values: [(Int64, Int64, Int64)] = []
    }
}
