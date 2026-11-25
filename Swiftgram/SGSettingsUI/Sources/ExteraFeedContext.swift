import AccountContext
import Foundation
import SGSimpleSettings
import SwiftSignalKit
import TelegramCore
import UIKit

struct ExteraFeedChannel: Equatable {
    let peer: EnginePeer
    let archived: Bool

    var id: Int64 { return self.peer.id.toInt64() }
}

struct ExteraFeedSnapshot: Equatable {
    var channels: [ExteraFeedChannel] = []
    var messages: [EngineMessage] = []
    var loading = false
    var hasOlder = false
    var channelsHaveMore = false
    var channelsLoaded = false
    var historyUncertain = false
    var historyLimitReached = false
    var channelLimitReached = false
    var selectedChannelsLimited = false
    var hasEligibleChannels = false
}

/// Uses the normal TelegramEngine channel-history path. No News context, parked TL API,
/// Postbox access, or per-channel polling subscription is installed by this screen.
/// Behavior follows exteraGram Android's FeedChannelRegistry / FeedTimelineLoader;
/// TelegramEngine owns message decoding, caching, and normal API requests on iOS.
final class ExteraFeedContext {
    static let maximumChannels = 40
    static let maximumPostsPerChannel = 100
    private static let maximumChatListCount = 2000
    private static let maximumVisiblePosts = 1000
    let settings: ExteraFeedSettings
    private let context: AccountContext
    private let promise = ValuePromise(ExteraFeedSnapshot(), ignoreRepeated: false)
    private var snapshot = ExteraFeedSnapshot()
    private let channelsDisposable = MetaDisposable()
    private var requests: [Int64: MetaDisposable] = [:]
    private var states: [Int64: SearchMessagesState] = [:]
    private var messages: [Int64: [EngineMessage]] = [:]
    private var exhausted: Set<Int64> = []
    private var uncertain: Set<Int64> = []
    private var refreshing: Set<Int64> = []
    private var requestedIds: Set<Int64> = []
    private var pending: [Int64] = []
    private var generation = 0
    private var channelLimit = 500
    private var windowSize = 100
    private var merged: [EngineMessage] = []
    private var visiblePages: Set<UUID> = []
    private var applicationActive = UIApplication.shared.applicationState == .active
    private var running = false
    private var observers: [NSObjectProtocol] = []

    var signal: Signal<ExteraFeedSnapshot, NoError> { return self.promise.get() }
    var current: ExteraFeedSnapshot { return self.snapshot }

    init(context: AccountContext) {
        self.context = context
        self.settings = ExteraFeedSettings(accountId: context.account.id.int64)
        self.observers.append(NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.settingsChanged()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.applicationActive = false
            self?.updateRunning()
        }))
        self.observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.applicationActive = true
            self?.updateRunning()
        }))
    }

    deinit {
        self.channelsDisposable.dispose()
        for request in self.requests.values { request.dispose() }
        for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setPageVisible(_ id: UUID, visible: Bool) {
        if visible { self.visiblePages.insert(id) } else { self.visiblePages.remove(id) }
        // Let a push/pop's paired appearance callbacks settle before deciding that the
        // entire shared feed has left the screen. Child settings pages retain this context.
        DispatchQueue.main.async { [weak self] in self?.updateRunning() }
    }

    private func updateRunning() {
        let running = self.applicationActive && !self.visiblePages.isEmpty
        guard running != self.running else { return }
        self.running = running
        if running {
            self.subscribeChannels()
            self.pump()
        } else {
            self.generation += 1
            self.channelsDisposable.set(nil)
            self.pending = Array(Set(self.pending).union(self.requests.keys)).sorted()
            for request in self.requests.values { request.dispose() }
            self.requests.removeAll()
            self.snapshot.loading = false
            self.publish()
        }
    }

    func loadMoreChannels() {
        guard self.channelLimit < Self.maximumChatListCount else { return }
        self.channelLimit = min(Self.maximumChatListCount, self.channelLimit + 500)
        if self.running { self.subscribeChannels() }
    }

    private func subscribeChannels() {
        self.channelsDisposable.set((combineLatest(
            self.context.engine.messages.chatList(group: .root, count: self.channelLimit),
            self.context.engine.messages.chatList(group: .archive, count: self.channelLimit)
        ) |> deliverOnMainQueue).start(next: { [weak self] main, archive in
            guard let self else { return }
            var channels: [ExteraFeedChannel] = []
            var seen = Set<Int64>()
            for (list, archived) in [(main, false), (archive, true)] {
                for item in list.items {
                    guard let peer = item.renderedPeer.peer, case let .channel(channel) = peer,
                          case .broadcast = channel.info, channel.participationStatus == .member,
                          seen.insert(peer.id.toInt64()).inserted else { continue }
                    channels.append(ExteraFeedChannel(peer: peer, archived: archived))
                }
            }
            channels.sort { $0.peer.debugDisplayTitle.localizedCaseInsensitiveCompare($1.peer.debugDisplayTitle) == .orderedAscending }
            self.snapshot.channels = channels
            self.snapshot.channelsHaveMore = (main.hasEarlier || archive.hasEarlier) && self.channelLimit < Self.maximumChatListCount
            self.snapshot.channelLimitReached = (main.hasEarlier || archive.hasEarlier) && self.channelLimit >= Self.maximumChatListCount
            self.snapshot.channelsLoaded = true
            self.settingsChanged()
        }))
    }

    private func settingsChanged() {
        let settings = self.settings.state
        let eligible = Set(self.snapshot.channels.filter { settings.includeArchived || !$0.archived }.map(\.id)).intersection(settings.effectiveChannelIds)
        self.snapshot.selectedChannelsLimited = eligible.count > Self.maximumChannels
        let ids = Set(eligible.sorted().prefix(Self.maximumChannels))
        self.snapshot.hasEligibleChannels = !ids.isEmpty
        if ids != self.requestedIds {
            self.reset(ids: ids)
        } else {
            self.publish()
        }
    }

    func refresh() {
        guard self.running else { return }
        // Retain a usable window and its cursors until replacement history actually arrives.
        self.reset(ids: self.requestedIds, preserveHistory: true)
    }

    private func reset(ids: Set<Int64>, preserveHistory: Bool = false) {
        self.generation += 1
        for request in self.requests.values { request.dispose() }
        self.requests.removeAll()
        if !preserveHistory {
            self.states.removeAll()
            self.messages.removeAll()
            self.snapshot.messages = []
            self.merged = []
            self.windowSize = 100
        }
        self.exhausted.removeAll()
        self.uncertain.removeAll()
        self.refreshing = preserveHistory ? ids : []
        self.requestedIds = ids
        self.pending = ids.sorted()
        self.snapshot.historyUncertain = false
        self.snapshot.historyLimitReached = false
        self.snapshot.hasOlder = !ids.isEmpty
        self.pump()
    }

    func loadOlder() {
        guard self.running, !self.snapshot.loading else { return }
        self.windowSize = min(Self.maximumVisiblePosts, self.windowSize + 100)
        if self.snapshot.messages.count < min(self.windowSize, self.merged.count) {
            self.merge()
            self.publish()
            return
        }
        self.pending = self.loadableIds.subtracting(self.uncertain).sorted()
        self.pump()
    }

    func retryUncertain() {
        guard self.running, !self.snapshot.loading else { return }
        self.pending = self.uncertain.intersection(self.loadableIds).sorted()
        self.pump()
    }

    private var loadableIds: Set<Int64> {
        return Set(self.requestedIds.filter { self.refreshing.contains($0) || (!self.exhausted.contains($0) && (self.messages[$0]?.count ?? 0) < Self.maximumPostsPerChannel) })
    }

    /// At most four ordinary getHistory requests in flight, independent of selected channel count.
    private func pump() {
        guard self.running else { return }
        while self.requests.count < 4, !self.pending.isEmpty {
            let id = self.pending.removeFirst()
            let generation = self.generation
            let disposable = MetaDisposable()
            self.requests[id] = disposable
            let previousCount = self.messages[id]?.count ?? 0
            let isRefresh = self.refreshing.contains(id)
            let location = SearchMessagesLocation.peer(peerId: EnginePeer.Id(id), fromId: nil, tags: nil, reactions: nil, threadId: nil, minDate: nil, maxDate: nil)
            disposable.set((self.context.engine.messages.searchMessages(location: location, query: "", state: isRefresh ? nil : self.states[id], limit: 20)
            |> take(1) |> deliverOnMainQueue).start(next: { [weak self] result, state in
                guard let self, self.generation == generation else { return }
                let all = result.messages.map { EngineMessage($0) }
                // This facade converts RPC failures into nil/cached results. Empty and
                // unchanged older pages cannot prove an empty channel or an exhausted history.
                // Keep the previous usable page/state and leave an explicit manual retry.
                if all.isEmpty || (!isRefresh && all.count <= previousCount) {
                    self.uncertain.insert(id)
                } else {
                    self.uncertain.remove(id)
                    self.refreshing.remove(id)
                    self.states[id] = state
                    self.messages[id] = Array(all.prefix(Self.maximumPostsPerChannel))
                    if result.completed { self.exhausted.insert(id) }
                }
                self.requests.removeValue(forKey: id)?.dispose()
                // Dispatch avoids recursive pumping if a cached engine result arrives synchronously.
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == generation else { return }
                    self.pump()
                }
            }))
        }
        self.snapshot.loading = !self.pending.isEmpty || !self.requests.isEmpty
        // Publish a complete round together: otherwise a quick channel can be shown out of order
        // while the other channels' initial pages are still arriving.
        if !self.snapshot.loading { self.merge() }
        self.publish()
    }

    private func merge() {
        let lists = self.messages
        // Hold back posts below the newest channel frontier. A channel still awaiting its older
        // history can contain posts above those, so publishing them would break pagination order.
        let frontier = lists.compactMap { id, messages -> EngineMessage.Index? in
            guard !self.exhausted.contains(id) else { return nil }
            return messages.map(\.index).min()
        }.max()
        var unique: [EngineMessage.Id: EngineMessage] = [:]
        for messages in lists.values {
            for message in messages {
                guard !message.engineMedia.contains(where: { if case .action = $0 { return true }; return false }),
                      !message.text.isEmpty || !message.engineMedia.isEmpty,
                      frontier.map({ message.index >= $0 }) ?? true else { continue }
                unique[message.id] = message
            }
        }
        self.merged = unique.values.sorted { $0.index > $1.index }
        self.snapshot.messages = Array(self.merged.prefix(self.windowSize))
        self.snapshot.historyUncertain = !self.uncertain.isEmpty
        let canLoadOlder = !self.loadableIds.subtracting(self.uncertain).isEmpty
        let displayedAtLimit = self.snapshot.messages.count >= Self.maximumVisiblePosts
        self.snapshot.historyLimitReached = self.messages.values.contains(where: { $0.count >= Self.maximumPostsPerChannel }) || (displayedAtLimit && (self.merged.count > self.windowSize || canLoadOlder))
        self.snapshot.hasOlder = !displayedAtLimit && (self.merged.count > self.windowSize || canLoadOlder)
    }

    private func publish() {
        self.promise.set(self.snapshot)
    }
}
