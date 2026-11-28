import Foundation
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// The sequence an update takes part in. A plugin may change what an update says, never where
/// it stands in its sequence: the state machine would see a hole or a duplicate.
private enum AyuPluginUpdateSequence: Equatable {
    case none
    case common(pts: Int32, count: Int32)
    case channel(id: Int64, pts: Int32, count: Int32)
    case qts
}

private func ayuPluginChannelId(_ message: Api.Message) -> Int64? {
    guard let peerId = apiMessagePeerId(message), peerId.namespace == Namespaces.Peer.CloudChannel else {
        return nil
    }
    return peerId.id._internalGetInt64Value()
}

private func ayuPluginUpdateSequence(_ update: Api.Update) -> AyuPluginUpdateSequence {
    if let range = apiUpdatePtsRange(update) {
        return .common(pts: range.end, count: range.count)
    }
    if apiUpdateQtsRange(update) != nil {
        return .qts
    }
    switch update {
    case let .updateNewChannelMessage(data):
        if let id = ayuPluginChannelId(data.message) {
            return .channel(id: id, pts: data.pts, count: data.ptsCount)
        }
    case let .updateEditChannelMessage(data):
        if let id = ayuPluginChannelId(data.message) {
            return .channel(id: id, pts: data.pts, count: data.ptsCount)
        }
    case let .updateDeleteChannelMessages(data):
        return .channel(id: data.channelId, pts: data.pts, count: data.ptsCount)
    case let .updatePinnedChannelMessages(data):
        return .channel(id: data.channelId, pts: data.pts, count: data.ptsCount)
    case let .updateChannelWebPage(data):
        return .channel(id: data.channelId, pts: data.pts, count: data.ptsCount)
    default:
        break
    }
    return .none
}

private func ayuPluginSerialized(_ update: Api.Update) -> Data {
    let buffer = Buffer()
    update.serialize(buffer, true)
    return buffer.makeData()
}

/// What stands in for `original` after the plugins answered `replacement` (nil: cancel).
///
/// - A replacement must be an `Update` with the sequence of the original; any other is ignored.
/// - A cancelled update of a pushed container keeps its place in the sequence as a deletion of
///   no messages, so that the state machine neither sees a hole nor fetches the update again.
///   One that carries qts has no such stand-in and is processed unchanged.
/// - `sequenced` is false for the updates of a difference, whose state the difference itself
///   carries: a cancelled one is just left out.
private func ayuPluginResolvedUpdate(original: Api.Update, serialized: Data, replacement: Data?, sequenced: Bool) -> Api.Update? {
    let sequence = ayuPluginUpdateSequence(original)
    guard let replacement else {
        if !sequenced {
            return nil
        }
        switch sequence {
        case .none:
            return nil
        case let .common(pts, count):
            return .updateDeleteMessages(.init(messages: [], pts: pts, ptsCount: count))
        case let .channel(id, pts, count):
            return .updateDeleteChannelMessages(.init(channelId: id, messages: [], pts: pts, ptsCount: count))
        case .qts:
            return original
        }
    }
    if replacement == serialized {
        return original
    }
    guard let replaced = Api.parse(Buffer(data: replacement)) as? Api.Update, ayuPluginUpdateSequence(replaced) == sequence else {
        return original
    }
    return replaced
}

private final class AyuPluginUpdateResults {
    private let lock = NSLock()
    private var updates: [Api.Update?]
    private var remaining: Int

    init(_ updates: [Api.Update], waiting: Int) {
        self.updates = updates
        self.remaining = waiting
    }

    /// The final list, once the last answer is in.
    func resolve(_ index: Int, _ update: Api.Update?) -> [Api.Update]? {
        self.lock.lock(); defer { self.lock.unlock() }
        self.updates[index] = update
        self.remaining -= 1
        return self.remaining == 0 ? self.updates.compactMap { $0 } : nil
    }
}

/// Shows the plugins every update of `updates` they hook and completes with what is left, in
/// the original order. The updates are asked about at once, not one after another, so the wait
/// is one hook chain long however many updates are listed. Synchronous when none is hooked.
private func ayuPluginHookUpdateList(interceptor: AyuPluginHookInterceptor, peerId: PeerId, updates: [Api.Update], sequenced: Bool, completion: @escaping ([Api.Update]) -> Void) {
    var hooked: [Int] = []
    for (index, update) in updates.enumerated() where interceptor.updates.contains(update.tlConstructorId) {
        hooked.append(index)
    }
    if hooked.isEmpty {
        completion(updates)
        return
    }
    let results = AyuPluginUpdateResults(updates, waiting: hooked.count)
    for index in hooked {
        let original = updates[index]
        let serialized = ayuPluginSerialized(original)
        interceptor.interceptUpdate(peerId, serialized, { replacement in
            if let final = results.resolve(index, ayuPluginResolvedUpdate(original: original, serialized: serialized, replacement: replacement, sequenced: sequenced)) {
                completion(final)
            }
        })
    }
}

/// The interceptor when it hooks updates or containers of the account `peerId`.
private func ayuPluginUpdateInterceptor(_ interceptor: AyuPluginHookInterceptor?, peerId: PeerId) -> AyuPluginHookInterceptor? {
    guard let interceptor, !(interceptor.updates.isEmpty && interceptor.containers.isEmpty), interceptor.servesAccount(peerId) else {
        return nil
    }
    return interceptor
}

/// The update hook point of pushed containers and of `Updates` responses, called by
/// `UpdateMessageService.addUpdates` before it reads the container. Returns false when the
/// service should process `updates` itself, now; true when the hook point took the container
/// and will hand what the plugins leave of it to `process` later (never, when they drop it).
///
/// Containers of one account are processed in the order they arrived: while one waits for a
/// plugin the later ones wait in `gate`, hooked or not. Android calls `on_updates_hook` for a
/// listed container and `on_update_hook` for each listed update of `updates`, `updatesCombined`
/// and `updateShort`; the short message containers are containers only.
func ayuPluginDefersUpdates(_ updates: Api.Updates, peerId: PeerId, gate: AyuPluginOrderedGate, process: @escaping (Api.Updates) -> Void) -> Bool {
    let state = ayuPluginHookState()
    if state.interceptor == nil && !state.holdsTraffic {
        return false
    }
    let interceptor = ayuPluginUpdateInterceptor(state.interceptor, peerId: peerId)
    if interceptor == nil && !gate.isBusy {
        return false
    }
    gate.add { done in
        guard let interceptor else {
            process(updates)
            done()
            return
        }
        ayuPluginHookContainer(interceptor: interceptor, peerId: peerId, updates: updates, completion: { result in
            if let result {
                process(result)
            }
            done()
        })
    }
    return true
}

private func ayuPluginHookContainer(interceptor: AyuPluginHookInterceptor, peerId: PeerId, updates: Api.Updates, completion: @escaping (Api.Updates?) -> Void) {
    let hookSingleUpdates: (Api.Updates) -> Void = { container in
        switch container {
        case let .updates(data):
            ayuPluginHookUpdateList(interceptor: interceptor, peerId: peerId, updates: data.updates, sequenced: true, completion: { list in
                completion(.updates(.init(updates: list, users: data.users, chats: data.chats, date: data.date, seq: data.seq)))
            })
        case let .updatesCombined(data):
            ayuPluginHookUpdateList(interceptor: interceptor, peerId: peerId, updates: data.updates, sequenced: true, completion: { list in
                completion(.updatesCombined(.init(updates: list, users: data.users, chats: data.chats, date: data.date, seqStart: data.seqStart, seq: data.seq)))
            })
        case let .updateShort(data):
            ayuPluginHookUpdateList(interceptor: interceptor, peerId: peerId, updates: [data.update], sequenced: true, completion: { list in
                completion(list.first.flatMap { .updateShort(.init(update: $0, date: data.date)) })
            })
        default:
            completion(container)
        }
    }
    guard interceptor.containers.contains(updates.tlConstructorId) else {
        hookSingleUpdates(updates)
        return
    }
    let buffer = Buffer()
    updates.serialize(buffer, true)
    let serialized = buffer.makeData()
    interceptor.interceptContainer(peerId, serialized, { replacement in
        guard let replacement else {
            completion(nil)
            return
        }
        if replacement != serialized, let replaced = Api.parse(Buffer(data: replacement)) as? Api.Updates {
            hookSingleUpdates(replaced)
        } else {
            hookSingleUpdates(updates)
        }
    })
}

/// The update hook point of `updates.getDifference` and `updates.getChannelDifference`: shows
/// the plugins the `other_updates` they hook. The messages of a difference are not updates and
/// are not shown, as on Android.
func ayuPluginHookedDifferenceUpdates(accountPeerId: PeerId, updates: [Api.Update]) -> Signal<[Api.Update], NoError> {
    guard !updates.isEmpty, let interceptor = ayuPluginUpdateInterceptor(ayuPluginHookState().interceptor, peerId: accountPeerId), !interceptor.updates.isEmpty else {
        return .single(updates)
    }
    return Signal { subscriber in
        ayuPluginHookUpdateList(interceptor: interceptor, peerId: accountPeerId, updates: updates, sequenced: false, completion: { list in
            subscriber.putNext(list)
            subscriber.putCompletion()
        })
        return EmptyDisposable
    }
}
