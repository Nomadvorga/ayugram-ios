import AccountContext
import Display
import Foundation
import ItemListUI
import SGItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import UIKit

private enum ExteraFeedAction: Equatable {
    case refresh
    case older
    case retryHistory
    case channels(String?)
    case categories
    case selectCategory(String?)
    case switchCategory(String?)
    case editCategory(String)
    case newCategory
    case renameCategory(String)
    case deleteCategory(String)
    case moveCategory(String, Int)
    case moreChannels
    case selectionMenu(String?)
    case markAllRead
    case readStatus
    case open(EngineMessage.Id)
}

private enum ExteraFeedToggle: Equatable {
    case archived
    case unread
    case widePosts
    case unreadCounter
    case channel(Int64, String?)
    case categoryHidden(String)
}

private struct ExteraFeedEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case notice(String)
        case header(String)
        case action(String, ExteraFeedAction, Bool)
        case toggle(String, Bool, ExteraFeedToggle)
        case search(String, String)
        case channel(EnginePeer, String, Bool, String?)
        case tabs([ExteraFeedSettings.Category], String?)
        case category(ExteraFeedSettings.Category)
        case post([EngineMessage], String, String, Bool, Bool, AvailableReactions?, Bool, MediaAutoDownloadSettings)
    }

    let stableId: String
    let index: Int
    let section: ItemListSectionId
    let content: Content

    static func <(lhs: ExteraFeedEntry, rhs: ExteraFeedEntry) -> Bool { return lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let actions = arguments as! ExteraFeedActions
        switch self.content {
        case let .notice(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .action(title, action, destructive):
            return ItemListActionItem(presentationData: presentationData, systemStyle: .glass, title: title, kind: destructive ? .destructive : .generic, alignment: .natural, sectionId: self.section, style: .blocks, action: { actions.perform(action) })
        case let .toggle(title, value, toggle):
            return sgExteraToggleItem(presentationData: presentationData, sectionId: self.section, appearance: exteraSettingsAppearance(), title: title, value: value, animationIdentity: AnyHashable(self.stableId), updated: { actions.toggle(toggle, value: $0) })
        case let .search(query, placeholder):
            return ItemListSingleLineInputItem(presentationData: presentationData, systemStyle: .glass, title: NSAttributedString(string: ""), text: query, placeholder: placeholder, type: .regular(capitalization: false, autocorrection: false), returnKeyType: .search, clearType: .always, sectionId: self.section, textUpdated: { actions.query.set($0) }, action: {}, dismissKeyboardOnEnter: true)
        case let .channel(peer, title, selected, categoryId):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, context: actions.context, iconPeer: peer, title: title, label: selected ? "✓" : "", sectionId: self.section, style: .blocks, disclosureStyle: .none, action: { actions.toggle(.channel(peer.id.toInt64(), categoryId), value: !selected) })
        case let .tabs(categories, selected):
            return ExteraFeedControlsItem(theme: presentationData.theme, sectionId: self.section, content: .tabs(categories, selected, actions.text("Extera.FeedAllChannels", "Main Feed")), selected: { actions.perform(.switchCategory($0)) })
        case let .category(category):
            return ExteraFeedControlsItem(theme: presentationData.theme, sectionId: self.section, content: .category(category, actions.text("Extera.FeedCategoryHidden", "Hidden"), actions.text("Extera.FeedCategoryVisible", "Visible")), selected: { _ in actions.perform(.editCategory(category.id)) }, hidden: { actions.toggle(.categoryHidden(category.id), value: !category.isHidden) })
        case let .post(messages, channel, metadata, unread, wide, reactions, wifi, _):
            guard let message = messages.first else { preconditionFailure() }
            return ExteraFeedPostItem(context: actions.context, messages: messages, presentationData: actions.context.sharedContext.currentPresentationData.with { $0 }, channel: channel, metadata: metadata + (unread ? " · " + actions.text("Extera.FeedUnread", "Unread") : ""), wide: wide, sectionId: self.section, actions: actions.bubbleActions(availableReactions: reactions, wifi: wifi), pageVisibility: actions.pageVisibility.get(), openPost: { actions.perform(.open(message.id)) }, openReactionPicker: { actions.reactionMenu(message, sourceView: $0) })
        }
    }
}

private enum ExteraFeedPage {
    case feed
    case channels(String?)
    case categories
    case category(String)
}

/// Entry point for Settings or the chat list. Uses ordinary channel history and local read cursors;
/// it deliberately does not enable the parked News tab or send News feed requests.
public func exteraFeedController(context: AccountContext) -> ViewController {
    return exteraFeedPageController(context: context, feed: ExteraFeedContext(context: context), page: .feed)
}

/// The same account-scoped channel/category settings are also reachable directly from Settings.
public func exteraFeedSettingsController(context: AccountContext) -> ViewController {
    return exteraFeedPageController(context: context, feed: ExteraFeedContext(context: context), page: .channels(nil))
}

private func exteraFeedPageController(context: AccountContext, feed: ExteraFeedContext, page: ExteraFeedPage) -> ViewController {
    let actions = ExteraFeedActions(context: context, feed: feed)
    // Real channel read state suppresses local unread marks after an explicit mark-all,
    // including posts loaded later and reads made on another device.
    let snapshots = feed.signal |> mapToSignal { snapshot -> Signal<(ExteraFeedSnapshot, [EnginePeer.Id: EnginePeerReadCounters]), NoError> in
        guard case .feed = page, !snapshot.messages.isEmpty else { return .single((snapshot, [:])) }
        let ids = Set(snapshot.messages.map { $0.id.peerId })
        return context.engine.data.subscribe(
            EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Messages.PeerReadCounters(id: $0) }),
            TelegramEngine.EngineData.Item.Messages.Messages(ids: Set(snapshot.messages.map(\.id)))
        ) |> map { counters, stored in
            var updated = snapshot
            updated.messages = snapshot.messages.map { stored[$0.id] ?? $0 }
            return (updated, counters)
        }
    }
    let networkIsWifi = context.account.networkType |> map { type -> Bool in
        switch type {
        case .none, .wifi: return true
        case .cellular: return false
        }
    } |> distinctUntilChanged
    let signal = combineLatest(context.sharedContext.presentationData, snapshots, actions.query.get(), context.engine.stickers.availableReactions(), networkIsWifi, context.sharedContext.automaticMediaDownloadSettings, ayuReadHistoryState(account: context.account))
    |> deliverOnMainQueue
    |> map { presentationData, snapshotAndCounters, query, availableReactions, wifi, downloadSettings, readStatus -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (snapshot, counters) = snapshotAndCounters
        let settings = feed.settings.state
        let appearance = ExteraFeedSettings.shared
        let lang = presentationData.strings.baseLanguageCode
        func text(_ key: String, _ fallback: String) -> String {
            let value = i18n(key, lang)
            return value == key ? fallback : value
        }
        func unread(_ message: EngineMessage) -> Bool {
            return settings.isUnread(channelId: message.id.peerId.toInt64(), messageId: message.id.id) && !(counters[message.id.peerId]?.isIncomingMessageIndexRead(message.index) ?? false)
        }
        var entries: [ExteraFeedEntry] = []
        func add(_ id: String, _ section: Int32, _ content: ExteraFeedEntry.Content) {
            entries.append(ExteraFeedEntry(stableId: id, index: entries.count, section: section, content: content))
        }
        let title: String
        var rightButton: ItemListNavigationButton?
        switch page {
        case .feed:
            title = settings.selectedCategory?.title ?? text("Extera.ChannelFeed", "Channel Feed")
            rightButton = ItemListNavigationButton(content: .text(text("Extera.FeedRefresh", "Refresh")), style: snapshot.loading ? .activity : .regular, enabled: !snapshot.loading, action: { actions.perform(.refresh) })
            add("tabs", 0, .tabs(settings.visibleCategories, settings.selectedCategoryId))
            add("channels", 0, .action(text("Extera.FeedChannels", "Choose Channels"), .channels(nil), false))
            add("categories", 0, .action(text("Extera.FeedCategories", "Categories"), .categories, false))
            add("unread", 0, .toggle(text("Extera.FeedUnreadOnly", "Unread Only"), settings.unreadOnly, .unread))
            let unreadCount = snapshot.messages.filter(unread).count
            let countTitle = snapshot.historyUncertain && snapshot.messages.isEmpty ? text("Extera.FeedHistoryUnconfirmed", "Channel history is not confirmed") : "\(text("Extera.FeedLoadedUnread", "Loaded unread posts")): \(unreadCount)"
            if appearance.showUnreadCounter {
                add("count", 1, .header(countTitle))
            }
            if snapshot.hasEligibleChannels {
                add("markRead", 1, .action(text("Extera.FeedMarkAllRead", "Read All"), .markAllRead, false))
            }
            // Account-wide status stays reachable even when categories/channels
            // were removed while reads were pending or after app relaunch.
            let readStatusTitle = text("Ayu.ReadStatus.FeedCounts", "Read Receipts: {pending} pending, {errors} errors")
                .replacingOccurrences(of: "{pending}", with: String(readStatus.pending.count))
                .replacingOccurrences(of: "{errors}", with: String(readStatus.failures.count))
            add("readStatus", 1, .action(readStatusTitle, .readStatus, false))
            if settings.effectiveChannelIds.isEmpty {
                add("empty", 1, .notice(text("Extera.FeedChooseChannelsInfo", "Choose the subscribed channels to include in your feed, or create a category with its own channels.")))
            } else if snapshot.channelsLoaded && !snapshot.hasEligibleChannels {
                add("unavailable", 1, .notice(text("Extera.FeedSelectedUnavailable", "No selected channels are currently available in the feed. Check your subscribed channels and archive selection.")))
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: lang)
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let channels = Dictionary(uniqueKeysWithValues: snapshot.channels.map { ($0.id, $0.peer.debugDisplayTitle) })
                let messages = snapshot.messages
                var displayedPostCount = 0
                var displayedAlbums = Set<String>()
                for message in messages {
                    let id: String
                    let post: [EngineMessage]
                    if let groupingKey = message.groupingKey {
                        let albumId = "\(message.id.peerId.toInt64()).\(groupingKey)"
                        guard displayedAlbums.insert(albumId).inserted else { continue }
                        id = "album.\(albumId)"
                        post = messages.filter { $0.id.peerId == message.id.peerId && $0.groupingKey == groupingKey }.sorted { $0.index < $1.index }
                    } else {
                        id = "post.\(message.id.peerId.toInt64()).\(message.id.namespace).\(message.id.id)"
                        post = [message]
                    }
                    guard !settings.unreadOnly || post.contains(where: unread) else { continue }
                    displayedPostCount += 1
                    let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
                    add(id, 2, .post(post, channels[message.id.peerId.toInt64()] ?? message.author?.debugDisplayTitle ?? "", date, post.contains(where: unread), appearance.widePosts, availableReactions, wifi, downloadSettings))
                }
                if displayedPostCount == 0 && !snapshot.loading && !snapshot.historyUncertain && snapshot.channelsLoaded {
                    add("empty", 2, .notice(settings.unreadOnly ? text("Extera.FeedNoUnread", "No unread posts in the loaded history. Load older posts or refresh for new posts.") : text("Extera.FeedNoPosts", "No posts are available in the selected channels. Refresh to retry, or check your channel and archive selection.")))
                }
                if snapshot.loading {
                    add("loading", 3, .notice(text("Extera.FeedLoading", "Loading channel history…")))
                } else if snapshot.hasOlder {
                    add("older", 3, .action(text("Extera.FeedLoadOlder", "Load Older Posts"), .older, false))
                }
                if snapshot.historyUncertain {
                    add("uncertain", 3, .notice(text("Extera.FeedHistoryIncomplete", "Some channel history could not be confirmed. Loaded posts are kept; the unread count covers only those posts. Retry to check the remaining history.")))
                    if !snapshot.loading {
                        add("retry", 3, .action(text("Extera.FeedRetryHistory", "Retry Channel History"), .retryHistory, false))
                    }
                }
                if snapshot.historyLimitReached {
                    add("limit", 3, .notice(text("Extera.FeedHistoryLimit", "This feed keeps up to 100 posts per channel and displays up to 1,000 posts. Open the original channel for its remaining history.")))
                }
            }
            add("info", 4, .notice(text("Ayu.ReadStatus.FeedInfo", "Opening a post marks it read locally in this feed. Read All asks before queuing Telegram read receipts. A local read or an accepted request does not confirm delivery; check Read Receipts for pending requests and results.")))
        case let .channels(categoryId):
            let category = settings.categories.first(where: { $0.id == categoryId })
            title = category?.title ?? text("Extera.FeedSettings", "Feed Settings")
            rightButton = ItemListNavigationButton(content: .text(text("Extera.FeedSelectionMenu", "Selection")), style: .regular, enabled: snapshot.channelsLoaded, action: { actions.perform(.selectionMenu(categoryId)) })
            add("search", 0, .search(query, text("Extera.FeedSearchChannels", "Search Channels")))
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if search.isEmpty {
                if categoryId == nil {
                    add("general", 1, .header(text("Extera.FeedGeneral", "General")))
                    add("wide", 1, .toggle(text("Extera.FeedWidePosts", "Wide Posts in Feed"), appearance.widePosts, .widePosts))
                    add("counter", 1, .toggle(text("Extera.FeedUnreadCounter", "Unread Post Counter"), appearance.showUnreadCounter, .unreadCounter))
                    add("archived", 1, .toggle(text("Extera.FeedIncludeArchived", "Include Archived Channels"), settings.includeArchived, .archived))
                    add("openFeed", 1, .action(text("Extera.ChannelFeed", "Channel Feed"), .selectCategory(nil), false))
                    add("categoriesHeader", 2, .header(text("Extera.FeedCategories", "Categories")))
                    for category in settings.categories {
                        add("category.\(category.id)", 2, .category(category))
                    }
                    add("create", 2, .action(text("Extera.FeedNewCategory", "New Category"), .newCategory, false))
                }
                add("info", 2, .notice(text("Extera.FeedChannelSelectionInfo", "Select subscribed broadcast channels. Archived channels appear in the feed only when Include Archived Channels is enabled. Category selections are independent of the main feed.")))
            }
            let selected = category?.channelIds ?? settings.channelIds
            let matching = snapshot.channels.filter { search.isEmpty || $0.peer.debugDisplayTitle.localizedCaseInsensitiveContains(search) }
            for included in [true, false] {
                let channels = matching.filter { selected.contains($0.id) == included }
                if !channels.isEmpty {
                    let section: Int32 = included ? 3 : 4
                    add(included ? "shown" : "hidden", section, .header(text(included ? "Extera.FeedShownChannels" : "Extera.FeedHiddenChannels", included ? "Shown in Feed" : "Hidden from Feed")))
                    for channel in channels {
                        let name = channel.peer.debugDisplayTitle + (channel.archived ? " · " + text("Extera.FeedArchived", "Archived") : "")
                        add("channel.\(channel.id)", section, .channel(channel.peer, name, included, categoryId))
                    }
                }
            }
            if snapshot.channelsLoaded && !snapshot.channels.isEmpty && matching.isEmpty {
                add("noMatches", 3, .notice(text("Extera.FeedNoMatchingChannels", "No matching channels.")))
            }
            if !snapshot.channelsLoaded {
                add("loading", 5, .notice(text("Extera.FeedLoadingChannels", "Loading subscribed channels…")))
            } else if snapshot.channels.isEmpty {
                add("empty", 5, .notice(text("Extera.FeedNoChannels", "No subscribed broadcast channels are available in the local chat list.")))
            }
            if snapshot.channelsHaveMore {
                add("moreChannels", 6, .action(text("Extera.FeedMoreChannels", "Load More Channels"), .moreChannels, false))
            }
        case .categories:
            title = text("Extera.FeedCategories", "Categories")
            add("all", 0, .action((settings.selectedCategoryId == nil ? "✓ " : "") + text("Extera.FeedAllChannels", "Main Feed"), .selectCategory(nil), false))
            add("create", 0, .action(text("Extera.FeedNewCategory", "New Category"), .newCategory, false))
            for category in settings.categories {
                add("category.\(category.id)", 1, .category(category))
            }
            add("info", 2, .notice(text("Extera.FeedCategoriesInfo", "Each category has its own channel selection. Open a category to select it, choose channels, rename, hide, reorder, or delete it.")))
        case let .category(id):
            let category = settings.categories.first(where: { $0.id == id })
            title = category?.title ?? text("Extera.FeedCategories", "Categories")
            if let category {
                if !category.isHidden {
                    add("select", 0, .action(text("Extera.FeedOpenCategory", "Open Category Feed"), .selectCategory(id), false))
                }
                add("channels", 0, .action(text("Extera.FeedChannels", "Choose Channels"), .channels(id), false))
                add("rename", 0, .action(text("Extera.FeedRenameCategory", "Rename Category"), .renameCategory(id), false))
                add("hidden", 0, .toggle(text("Extera.FeedHideCategory", "Hide Category"), category.isHidden, .categoryHidden(id)))
                if let index = settings.categories.firstIndex(where: { $0.id == id }) {
                    if index > 0 { add("up", 1, .action(text("Extera.FeedMoveUp", "Move Up"), .moveCategory(id, -1), false)) }
                    if index + 1 < settings.categories.count { add("down", 1, .action(text("Extera.FeedMoveDown", "Move Down"), .moveCategory(id, 1), false)) }
                }
                add("delete", 2, .action(text("Extera.FeedDeleteCategory", "Delete Category"), .deleteCategory(id), true))
            }
        }
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(title), leftNavigationButton: nil, rightNavigationButton: rightButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        let wide: Bool
        if case .feed = page { wide = appearance.widePosts } else { wide = false }
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: wide ? .plain : .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    controller.setReorderEntry { (from: Int, to: Int, entries: [ExteraFeedEntry]) -> Signal<Bool, NoError> in
        guard entries.indices.contains(from), entries.indices.contains(to),
              case let .category(source) = entries[from].content,
              case let .category(destination) = entries[to].content else { return .single(false) }
        feed.settings.update { state in
            if from < to, let index = state.categories.firstIndex(where: { $0.id == destination.id }) {
                let next = index + 1 < state.categories.count ? state.categories[index + 1].id : nil
                state.moveCategory(id: source.id, before: next)
            } else {
                state.moveCategory(id: source.id, before: destination.id)
            }
        }
        return .single(true)
    }
    actions.controller = controller
    let pageId = actions.pageId
    controller.didAppear = { [weak feed, weak actions] _ in
        actions?.pageVisibility.set(true)
        feed?.setPageVisible(pageId, visible: true)
    }
    controller.didDisappear = { [weak feed, weak actions] _ in
        actions?.pageVisibility.set(false)
        feed?.setPageVisible(pageId, visible: false)
    }
    return controller
}

private final class ExteraFeedActions {
    let pageId = UUID()
    let context: AccountContext
    private let feed: ExteraFeedContext
    let query = ValuePromise<String>("", ignoreRepeated: true)
    let pageVisibility = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let interactionDisposable = MetaDisposable()
    weak var controller: ViewController?

    init(context: AccountContext, feed: ExteraFeedContext) {
        self.context = context
        self.feed = feed
    }

    deinit {
        self.interactionDisposable.dispose()
        // Also release a visibility token if a controller is removed without paired
        // UIKit appearance callbacks (for example, replacement of a navigation stack).
        let feed = self.feed
        let id = self.pageId
        DispatchQueue.main.async { feed.setPageVisible(id, visible: false) }
    }

    func text(_ key: String, _ fallback: String) -> String {
        let value = i18n(key, self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
        return value == key ? fallback : value
    }

    private func push(_ page: ExteraFeedPage) {
        self.controller?.push(exteraFeedPageController(context: self.context, feed: self.feed, page: page))
    }

    func bubbleActions(availableReactions: AvailableReactions?, wifi: Bool) -> ChatMessageFeedItemActions {
        return ChatMessageFeedItemActions(openUrl: { [weak self] in self?.openUrl($0) }, openMessage: { [weak self] in self?.openMedia($0) ?? false }, openPeer: { [weak self] in self?.openPeer($0) }, openInstantPage: { [weak self] message in
            guard let self, let navigation = self.controller?.navigationController as? NavigationController,
                  let page = self.context.sharedContext.makeInstantPageController(context: self.context, message: message, sourcePeerType: nil) else { return }
            navigation.pushViewController(page)
        }, navigateToMessage: { [weak self] in self?.perform(.open($0)) }, availableReactions: availableReactions, mediaAutoDownloadNetworkType: wifi ? .wifi : .cellular, updateReaction: { [weak self] message, reaction in
            guard let self else { return }
            if reaction == .stars {
                self.perform(.open(message.id))
                return
            }
            let update: UpdateMessageReaction
            switch reaction {
            case let .builtin(value): update = .builtin(value)
            case let .custom(fileId): update = .custom(fileId: fileId, file: nil)
            case .stars: return
            }
            let _ = self.context.sharedContext.updateExteraFeedReaction(context: self.context, messageId: message.id, reaction: update)
        }, openReactionMenu: { [weak self] message, source in self?.reactionMenu(message, sourceView: source) }, openReplies: { [weak self] id in
            guard let self, let controller = self.controller else { return }
            self.interactionDisposable.set(self.context.sharedContext.openExteraFeedReplies(context: self.context, messageId: id, controller: controller))
        })
    }

    func reactionMenu(_ message: EngineMessage, sourceView: UIView? = nil) {
        guard let controller = self.controller else { return }
        self.interactionDisposable.set(self.context.sharedContext.presentExteraFeedReactionMenu(context: self.context, messageId: message.id, sourceView: sourceView ?? controller.view, controller: controller))
    }

    private func openPeer(_ peer: EnginePeer) {
        guard let navigation = self.controller?.navigationController as? NavigationController else { return }
        self.context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigation, context: self.context, chatLocation: .peer(peer)))
    }

    private func openUrl(_ url: String) {
        guard let controller = self.controller else { return }
        let context = self.context
        self.interactionDisposable.set((context.sharedContext.resolveUrl(context: context, peerId: nil, url: url, skipUrlAuth: false)
        |> deliverOnMainQueue).start(next: { [weak self, weak controller] resolved in
            guard let controller else { return }
            context.sharedContext.openResolvedUrl(resolved, context: context, urlContext: .generic, navigationController: controller.navigationController as? NavigationController, forceExternal: false, forceUpdate: false, openPeer: { [weak self] peer, _ in
                self?.openPeer(peer)
            }, sendFile: nil, sendSticker: nil, sendEmoji: nil, requestMessageActionUrlAuth: nil, joinVoiceChat: nil, present: { [weak controller] c, a in
                controller?.present(c, in: .window(.root), with: a)
            }, dismissInput: {}, contentContext: nil, progress: nil, completion: nil)
        }))
    }

    private func openMedia(_ message: EngineMessage) -> Bool {
        guard let controller = self.controller, let navigation = controller.navigationController as? NavigationController else { return false }
        return self.context.sharedContext.openChatMessage(OpenChatMessageParams(context: self.context, chatLocation: .peer(id: message.id.peerId), chatFilterTag: nil, chatLocationContextHolder: nil, message: message._asMessage(), standalone: false, reverseMessageGalleryOrder: false, navigationController: navigation, dismissInput: {}, present: { [weak controller] c, a, _ in
            controller?.present(c, in: .window(.root), with: a)
        }, transitionNode: { _, _, _ in nil }, addToTransitionSurface: { [weak controller] view in controller?.view.addSubview(view) }, openUrl: { [weak self] in self?.openUrl($0) }, openPeer: { [weak self] peer, _ in self?.openPeer(EnginePeer(peer)) }, callPeer: { _, _ in }, openConferenceCall: { _ in }, enqueueMessage: { _ in }, sendSticker: nil, sendEmoji: nil, setupTemporaryHiddenMedia: { _, _, _ in }, chatAvatarHiddenMedia: { _, _ in }))
    }

    func toggle(_ toggle: ExteraFeedToggle, value: Bool) {
        switch toggle {
        case .widePosts:
            ExteraFeedSettings.shared.widePosts = value
            return
        case .unreadCounter:
            ExteraFeedSettings.shared.showUnreadCounter = value
            return
        default:
            break
        }
        self.feed.settings.update { state in
            switch toggle {
            case .archived: state.includeArchived = value
            case .unread: state.unreadOnly = value
            case .widePosts, .unreadCounter: break
            case let .channel(id, categoryId):
                if let categoryId {
                    guard let index = state.categories.firstIndex(where: { $0.id == categoryId }) else { return }
                    if value { state.categories[index].channelIds.insert(id) } else { state.categories[index].channelIds.remove(id) }
                } else {
                    if value { state.channelIds.insert(id) } else { state.channelIds.remove(id) }
                }
            case let .categoryHidden(id):
                if let index = state.categories.firstIndex(where: { $0.id == id }) { state.categories[index].isHidden = value }
            }
        }
    }

    func perform(_ action: ExteraFeedAction) {
        switch action {
        case .refresh: self.feed.refresh()
        case .older: self.feed.loadOlder()
        case .retryHistory: self.feed.retryUncertain()
        case let .channels(id): self.push(.channels(id))
        case .categories: self.push(.categories)
        case let .editCategory(id): self.push(.category(id))
        case let .selectCategory(id):
            self.feed.settings.update { $0.selectedCategoryId = id }
            self.push(.feed)
        case let .switchCategory(id):
            self.feed.settings.update { $0.selectedCategoryId = id }
        case .newCategory: self.editCategoryTitle(id: nil)
        case let .renameCategory(id): self.editCategoryTitle(id: id)
        case let .deleteCategory(id):
            let alert = UIAlertController(title: self.text("Extera.FeedDeleteCategory", "Delete Category"), message: self.text("Extera.FeedDeleteCategoryInfo", "Delete this local category? Your channels and messages are kept."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
            alert.addAction(UIAlertAction(title: self.text("Extera.FeedDelete", "Delete"), style: .destructive, handler: { [weak self] _ in
                guard let self else { return }
                self.feed.settings.update { $0.categories.removeAll(where: { $0.id == id }) }
                let _ = (self.controller?.navigationController as? NavigationController)?.popViewController(animated: true)
            }))
            self.controller?.present(alert, animated: true)
        case let .moveCategory(id, offset):
            self.feed.settings.update { state in
                guard let index = state.categories.firstIndex(where: { $0.id == id }), state.categories.indices.contains(index + offset) else { return }
                state.categories.swapAt(index, index + offset)
            }
        case .moreChannels: self.feed.loadMoreChannels()
        case let .selectionMenu(categoryId):
            let strings = self.context.sharedContext.currentPresentationData.with { $0 }.strings
            let alert = UIAlertController(title: self.text("Extera.FeedSelectionMenu", "Selection"), message: self.text("Extera.FeedFullSelectionInfo", "Select All includes every subscribed channel in the local registry, including channels outside the search."), preferredStyle: .actionSheet)
            alert.addAction(UIAlertAction(title: self.text("Extera.FeedSelectAll", "Select All"), style: .default, handler: { [weak self] _ in
                guard let self else { return }
                let ids = Set(self.feed.current.channels.map(\.id))
                self.feed.settings.update { $0.setChannelSelection(ids, categoryId: categoryId) }
            }))
            alert.addAction(UIAlertAction(title: self.text("Extera.FeedDeselectAll", "Deselect All"), style: .default, handler: { [weak self] _ in
                self?.feed.settings.update { $0.setChannelSelection([], categoryId: categoryId) }
            }))
            alert.addAction(UIAlertAction(title: strings.Common_Cancel, style: .cancel))
            if let view = self.controller?.view, let popover = alert.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top, width: 1.0, height: 1.0)
            }
            self.controller?.present(alert, animated: true)
        case .markAllRead:
            self.confirmMarkAllRead()
        case .readStatus:
            self.controller?.push(ayuReadHistoryController(context: self.context))
        case let .open(id):
            if let message = self.feed.current.messages.first(where: { $0.id == id }) {
                self.context.engine.messages.ensureMessagesAreLocallyAvailable(messages: [message])
            }
            self.feed.settings.markRead(channelId: id.peerId.toInt64(), messageId: id.id)
            self.context.sharedContext.navigateToChat(accountId: self.context.account.id, peerId: id.peerId, messageId: id)
        }
    }

    private func confirmMarkAllRead() {
        // Capture the scope before presenting the confirmation. A category or selection change
        // while the dialog is open must not silently expand the user's confirmed action.
        let snapshot = self.feed.current
        let state = self.feed.settings.state
        let ids = state.markAllReadChannelIds(available: Set(snapshot.channels.map(\.id)), archived: Set(snapshot.channels.filter(\.archived).map(\.id)))
        guard !ids.isEmpty else { return }
        var maxIds: [Int64: Int32] = [:]
        for message in snapshot.messages where ids.contains(message.id.peerId.toInt64()) {
            let peerId = message.id.peerId.toInt64()
            maxIds[peerId] = max(maxIds[peerId] ?? 0, message.id.id)
        }
        // Read-only preparation freezes both peers and upper bounds before the
        // confirmation. A later refresh/selection change cannot expand the read.
        let capturedMaxIds = maxIds
        self.interactionDisposable.set((ayuReadHistoryKnownBounds(account: self.context.account, peerIdValues: ids.sorted()) |> deliverOnMainQueue).start(next: { [weak self] requests in
            guard let self, let controller = self.controller, controller.isNodeLoaded, controller.view.window != nil, !requests.isEmpty else { return }
            self.presentMarkAllRead(requests: requests, maxIds: capturedMaxIds)
        }))
    }

    private func presentMarkAllRead(requests: [AyuReadHistoryRequest], maxIds: [Int64: Int32]) {
        let alert = UIAlertController(title: self.text("Extera.FeedMarkAllRead", "Read All"), message: self.text("Ayu.ReadStatus.FeedConfirmation", "Queue read receipts for the selected channels through their currently known latest messages? Delivery may wait for a connection. Newer messages are not included."), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Extera.FeedConfirmMarkRead", "Mark as Read"), style: .default, handler: { [weak self] _ in
            guard let self, let controller = self.controller else { return }
            let feed = self.feed
            controller.push(ayuReadHistoryController(context: self.context, requests: requests, onAccepted: { [weak feed] request in
                // Only the captured loaded feed cursor moves locally. Delivery is
                // independently shown as pending/confirmed in the status screen.
                if let maxId = maxIds[request.peerIdValue] {
                    feed?.settings.markRead(channelId: request.peerIdValue, messageId: min(maxId, request.maxId))
                }
            }))
        }))
        self.controller?.present(alert, animated: true)
    }

    private func editCategoryTitle(id: String?) {
        let existing = self.feed.settings.state.categories.first(where: { $0.id == id })
        let alert = UIAlertController(title: self.text(id == nil ? "Extera.FeedNewCategory" : "Extera.FeedRenameCategory", id == nil ? "New Category" : "Rename Category"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = existing?.title
            field.placeholder = self.text("Extera.FeedCategoryName", "Category Name")
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
        alert.addAction(UIAlertAction(title: self.text("Extera.FeedSave", "Save"), style: .default, handler: { [weak self, weak alert] _ in
            guard let self, let title = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
            let newId = id ?? UUID().uuidString
            self.feed.settings.update { state in
                if let index = state.categories.firstIndex(where: { $0.id == newId }) {
                    state.categories[index].title = String(title.prefix(64))
                } else {
                    state.categories.append(ExteraFeedSettings.Category(id: newId, title: String(title.prefix(64))))
                }
            }
            if id == nil { self.push(.category(newId)) }
        }))
        self.controller?.present(alert, animated: true)
    }
}
