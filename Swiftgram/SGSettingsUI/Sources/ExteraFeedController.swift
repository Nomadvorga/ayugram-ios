import AccountContext
import Display
import Foundation
import ItemListUI
import SGSimpleSettings
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private enum ExteraFeedAction: Equatable {
    case refresh
    case older
    case retryHistory
    case channels(String?)
    case categories
    case selectCategory(String?)
    case editCategory(String)
    case newCategory
    case renameCategory(String)
    case deleteCategory(String)
    case moveCategory(String, Int)
    case moreChannels
    case markLoadedRead
    case open(EngineMessage.Id)
}

private enum ExteraFeedToggle: Equatable {
    case archived
    case unread
    case channel(Int64, String?)
    case categoryHidden(String)
}

private struct ExteraFeedEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case notice(String)
        case header(String)
        case action(String, ExteraFeedAction, Bool)
        case toggle(String, Bool, ExteraFeedToggle)
        case post(EngineMessage, String, String, Bool)
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
            return ItemListSwitchItem(presentationData: presentationData, systemStyle: .glass, title: title, value: value, enableInteractiveChanges: false, maximumNumberOfLines: 0, sectionId: self.section, style: .blocks, updated: { actions.toggle(toggle, value: $0) })
        case let .post(message, channel, preview, unread):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: channel, titleFont: unread ? .bold : .regular, titleBadge: unread ? actions.text("Extera.FeedUnread", "Unread") : nil, label: preview, labelStyle: .multilineDetailText, sectionId: self.section, style: .blocks, action: { actions.perform(.open(message.id)) })
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
    let signal = combineLatest(context.sharedContext.presentationData, feed.signal)
    |> deliverOnMainQueue
    |> map { presentationData, snapshot -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let settings = feed.settings.state
        let lang = presentationData.strings.baseLanguageCode
        func text(_ key: String, _ fallback: String) -> String { return i18n(key, lang, fallback) }
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
            add("channels", 0, .action(text("Extera.FeedChannels", "Choose Channels"), .channels(nil), false))
            add("categories", 0, .action(text("Extera.FeedCategories", "Categories"), .categories, false))
            add("unread", 0, .toggle(text("Extera.FeedUnreadOnly", "Unread Only"), settings.unreadOnly, .unread))
            let unreadCount = snapshot.messages.filter { settings.isUnread(channelId: $0.id.peerId.toInt64(), messageId: $0.id.id) }.count
            let countTitle = snapshot.historyUncertain && snapshot.messages.isEmpty ? text("Extera.FeedHistoryUnconfirmed", "Channel history is not confirmed") : "\(text("Extera.FeedLoadedUnread", "Loaded unread posts")): \(unreadCount)"
            add("count", 1, .header(countTitle))
            if !snapshot.messages.isEmpty {
                add("markRead", 1, .action(text("Extera.FeedMarkLoadedRead", "Mark Loaded Posts Read"), .markLoadedRead, false))
            }
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
                let messages = snapshot.messages.filter { !settings.unreadOnly || settings.isUnread(channelId: $0.id.peerId.toInt64(), messageId: $0.id.id) }
                for message in messages {
                    let id = "post.\(message.id.peerId.toInt64()).\(message.id.namespace).\(message.id.id)"
                    var body = message.text
                    if body.isEmpty {
                        body = exteraFeedMediaDescription(message, lang: lang)
                    }
                    // The full original message and attachments open in Telegram's chat renderer.
                    if body.count > 1400 { body = String(body.prefix(1400)) + "…" }
                    let date = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(message.timestamp)))
                    add(id, 2, .post(message, channels[message.id.peerId.toInt64()] ?? message.author?.debugDisplayTitle ?? "", date + "\n" + body, settings.isUnread(channelId: message.id.peerId.toInt64(), messageId: message.id.id)))
                }
                if messages.isEmpty && !snapshot.loading && !snapshot.historyUncertain && snapshot.channelsLoaded {
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
                if snapshot.selectedChannelsLimited {
                    add("channelLimit", 3, .notice(text("Extera.FeedSelectionLimit", "A feed can load up to 40 channels. Choose fewer channels or split them into categories.")))
                }
            }
            add("info", 4, .notice(text("Extera.FeedLocalInfo", "This feed is stored on this device for this account. Opening a post marks it and earlier posts in that channel as read in the feed. Use Refresh to fetch new posts. Photos, videos, and the full post open in the original channel.")))
        case let .channels(categoryId):
            let category = settings.categories.first(where: { $0.id == categoryId })
            title = category?.title ?? text("Extera.FeedChannels", "Choose Channels")
            if categoryId == nil {
                add("archived", 0, .toggle(text("Extera.FeedIncludeArchived", "Include Archived Channels"), settings.includeArchived, .archived))
                add("openFeed", 0, .action(text("Extera.ChannelFeed", "Channel Feed"), .selectCategory(nil), false))
                add("categories", 0, .action(text("Extera.FeedCategories", "Categories"), .categories, false))
            }
            add("info", 0, .notice(text("Extera.FeedChannelSelectionInfo", "Select subscribed broadcast channels. Archived channels appear in the feed only when Include Archived Channels is enabled. Category selections are independent of the main feed.")))
            let selected = category?.channelIds ?? settings.channelIds
            for channel in snapshot.channels {
                let name = channel.peer.debugDisplayTitle + (channel.archived ? " · " + text("Extera.FeedArchived", "Archived") : "")
                add("channel.\(channel.id)", 1, .toggle(name, selected.contains(channel.id), .channel(channel.id, categoryId)))
            }
            if !snapshot.channelsLoaded {
                add("loading", 1, .notice(text("Extera.FeedLoadingChannels", "Loading subscribed channels…")))
            } else if snapshot.channels.isEmpty {
                add("empty", 1, .notice(text("Extera.FeedNoChannels", "No subscribed broadcast channels are available in the local chat list.")))
            }
            if snapshot.channelsHaveMore {
                add("moreChannels", 2, .action(text("Extera.FeedMoreChannels", "Load More Channels"), .moreChannels, false))
            }
            if snapshot.channelLimitReached {
                add("registryLimit", 2, .notice(text("Extera.FeedChannelListLimit", "Channel selection scans up to 2,000 recent chats in each chat list. Older channels may become available after you open them.")))
            }
        case .categories:
            title = text("Extera.FeedCategories", "Categories")
            add("all", 0, .action((settings.selectedCategoryId == nil ? "✓ " : "") + text("Extera.FeedAllChannels", "Main Feed"), .selectCategory(nil), false))
            add("create", 0, .action(text("Extera.FeedNewCategory", "New Category"), .newCategory, false))
            for category in settings.categories {
                add("category.\(category.id)", 1, .action((settings.selectedCategoryId == category.id ? "✓ " : "") + category.title + (category.isHidden ? " · " + text("Extera.FeedHidden", "Hidden") : ""), .editCategory(category.id), false))
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
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    actions.controller = controller
    let pageId = actions.pageId
    controller.didAppear = { [weak feed] _ in feed?.setPageVisible(pageId, visible: true) }
    controller.didDisappear = { [weak feed] _ in feed?.setPageVisible(pageId, visible: false) }
    return controller
}

private func exteraFeedMediaDescription(_ message: EngineMessage, lang: String) -> String {
    for media in message.engineMedia {
        switch media {
        case .image: return i18n("Extera.FeedPhoto", lang, "Photo · Open in Channel")
        case let .file(file):
            if file.isVideo { return i18n("Extera.FeedVideo", lang, "Video · Open in Channel") }
            return file.fileName ?? i18n("Extera.FeedAttachment", lang, "Attachment · Open in Channel")
        case .poll: return i18n("Extera.FeedPoll", lang, "Poll · Open in Channel")
        default: break
        }
    }
    return i18n("Extera.FeedPost", lang, "Post · Open in Channel")
}

private final class ExteraFeedActions {
    let pageId = UUID()
    private let context: AccountContext
    private let feed: ExteraFeedContext
    weak var controller: ViewController?

    init(context: AccountContext, feed: ExteraFeedContext) {
        self.context = context
        self.feed = feed
    }

    deinit {
        // Also release a visibility token if a controller is removed without paired
        // UIKit appearance callbacks (for example, replacement of a navigation stack).
        let feed = self.feed
        let id = self.pageId
        DispatchQueue.main.async { feed.setPageVisible(id, visible: false) }
    }

    func text(_ key: String, _ fallback: String) -> String {
        return i18n(key, self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode, fallback)
    }

    private func push(_ page: ExteraFeedPage) {
        self.controller?.push(exteraFeedPageController(context: self.context, feed: self.feed, page: page))
    }

    func toggle(_ toggle: ExteraFeedToggle, value: Bool) {
        if value, case let .channel(id, categoryId) = toggle {
            let state = self.feed.settings.state
            let selected = categoryId.flatMap { categoryId in state.categories.first(where: { $0.id == categoryId })?.channelIds } ?? state.channelIds
            if !selected.contains(id) && selected.count >= ExteraFeedContext.maximumChannels {
                let alert = UIAlertController(title: self.text("Extera.FeedChannels", "Choose Channels"), message: self.text("Extera.FeedSelectionLimit", "A feed can load up to 40 channels. Choose fewer channels or split them into categories."), preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_OK, style: .default))
                self.controller?.present(alert, animated: true)
                return
            }
        }
        self.feed.settings.update { state in
            switch toggle {
            case .archived: state.includeArchived = value
            case .unread: state.unreadOnly = value
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
        case .markLoadedRead:
            let messages = self.feed.current.messages
            self.feed.settings.update { state in
                for message in messages {
                    let id = String(message.id.peerId.toInt64())
                    state.readMaxIds[id] = max(state.readMaxIds[id] ?? 0, message.id.id)
                }
            }
        case let .open(id):
            if let message = self.feed.current.messages.first(where: { $0.id == id }) {
                self.context.engine.messages.ensureMessagesAreLocallyAvailable(messages: [message])
            }
            self.feed.settings.markRead(channelId: id.peerId.toInt64(), messageId: id.id)
            self.context.sharedContext.navigateToChat(accountId: self.context.account.id, peerId: id.peerId, messageId: id)
        }
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
