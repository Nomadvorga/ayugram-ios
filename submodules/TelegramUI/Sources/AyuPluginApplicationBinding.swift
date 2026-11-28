import AccountContext
import AppLock
import AyuPluginBridge
import AyuPluginTelegramAdapter
import Display
import Foundation
import PeerMessagesMediaPlaylist
import SwiftSignalKit
import TabBarUI
import TelegramCore
import UIKit

/// Real main-app account and screen wiring. No TelegramApi dependency, runtime
/// reflection, global window lookup or synchronous calls into Python.
@MainActor final class AyuTelegramPluginApplicationBinding {
    static weak var current: AyuTelegramPluginApplicationBinding?
    private weak var sharedContext: SharedAccountContextImpl?
    private let root: () -> (AccountRecordId, UIViewController)?
    private let bridge: AyuPluginApplicationBridge
    private let disposables = DisposableSet()
    private var slots: [AccountRecordId: Int64] = [:]
    private var identities: [AccountRecordId: UUID] = [:]
    private var accountSnapshots: [AccountRecordId: AyuPluginAccountSnapshot] = [:]
    private var accountContexts: [AccountRecordId: AccountContext] = [:]
    private var nextSlot: Int64 = 0
    private var primaryID: AccountRecordId?
    private var locked = true
    private var active = false
    private weak var lastController: UIViewController?
    private var lastAccount: Int64?
    private var lastDialog: Int64?
    private var screenIdentity = UUID()

    init(sharedContext: SharedAccountContextImpl, bridge: AyuPluginApplicationBridge = .shared, root: @escaping () -> (AccountRecordId, UIViewController)?) {
        self.sharedContext = sharedContext; self.bridge = bridge; self.root = root
        AyuTelegramPluginApplicationBinding.current = self
        AyuPluginTelegramAdapter.shared.bind(describesScreen: true, routesSendHook: true, routesURLOpen: true)
        self.installPluginNavigator()
        self.installPluginPlayer()
        bridge.bindScreen(screen: { [weak self] in self?.screen() }, presenter: { [weak self] in self?.visibleController()?.1 }, presentAlert: { [weak sharedContext] alert in
            sharedContext?.mainWindow?.presentNative(alert)
        }, openURL: { [weak self] screen, url in
            self?.openPluginURL(url, screen: screen)
        }, closeScreen: { [weak self] screen, animated in
            self?.closePluginScreen(screen, animated: animated)
        }, localeIdentifier: { [weak sharedContext] in
            sharedContext?.currentPresentationData.with { $0 }.strings.baseLanguageCode ?? Locale.current.identifier
        })
        // Read on the plugin host's worker: the presentation data is an atomic snapshot.
        bridge.presentation.bind(palette: { [weak sharedContext] in
            sharedContext.map { AyuPluginThemePalette(presentationData: $0.currentPresentationData.with { $0 }) }
        }, language: { [weak sharedContext] in
            sharedContext.map { AyuPluginLanguage(strings: $0.currentPresentationData.with { $0 }.strings) }
        })
        AyuNativePluginRuntime.shared.presenter = { [weak self] in
            self?.visibleController()?.1
        }
        AyuPluginMenuBridge.shared.bindLocations(resolve: { [weak self] request in
            self?.pluginMenuLocation(request)
        }, isCurrent: { [weak self] location, request in
            self?.isCurrentPluginMenuLocation(location, request: request) == true
        })
        AyuNativePluginRuntime.shared.nextUnread = { [weak self] policy, completion in
            guard let self, self.active, !self.locked, let (_, root) = self.root() else {
                completion(false)
                return
            }
            guard let root = root as? TelegramRootController else {
                completion(false)
                return
            }
            root.openNextUnreadChat(
                targetKinds: policy.targetKinds,
                currentPeerId: policy.currentPeerId,
                strategy: policy.strategy,
                includeMuted: policy.includeMuted,
                skipPinned: policy.skipPinned,
                otherFolders: policy.otherFolders,
                countMarkedUnread: policy.countMarkedUnread,
                completion: completion
            )
        }
        self.disposables.add((sharedContext.activeAccountContexts |> deliverOnMainQueue).start(next: { [weak self] primary, accounts, _ in
            guard let self else { return }
            self.primaryID = primary?.account.id
            let activeIDs = Set(accounts.map { $0.0 })
            self.identities = self.identities.filter { activeIDs.contains($0.key) }
            self.accountSnapshots = self.accountSnapshots.filter { activeIDs.contains($0.key) }
            self.accountContexts = self.accountContexts.filter { activeIDs.contains($0.key) }
            for (id, context, _) in accounts {
                self.accountContexts[id] = context
                if self.slots[id] == nil { self.slots[id] = self.nextSlot; self.nextSlot += 1 }
                if self.identities[id] == nil { self.identities[id] = UUID() }
                let slot = self.slots[id]!
                let userID = context.account.peerId.id._internalGetInt64Value()
                if self.accountSnapshots[id] == nil {
                    self.accountSnapshots[id] = AyuPluginAccountSnapshot(index: slot, identity: self.identities[id]!, userID: userID)
                }
            }
            self.publishAccounts()
        }))
        self.disposables.add((sharedContext.activeAccountsWithInfo |> deliverOnMainQueue).start(next: { [weak self] _, accounts in
            guard let self else { return }
            for info in accounts {
                let id = info.account.id
                guard let slot = self.slots[id], let identity = self.identities[id], case let .user(user) = info.peer else { continue }
                self.accountSnapshots[id] = AyuPluginAccountSnapshot(index: slot, identity: identity,
                    userID: user.id.id._internalGetInt64Value(), firstName: user.firstName ?? "", lastName: user.lastName, username: user.username)
            }
            self.publishAccounts()
        }))
        if let appLock = sharedContext.appLockContext as? AppLockContextImpl {
            self.disposables.add((appLock.isCurrentlyLocked |> deliverOnMainQueue).start(next: { [weak self] locked in
                self?.locked = locked
                if locked { self?.bridge.invalidatePresentations() }
            }))
        }
        self.disposables.add((combineLatest(sharedContext.applicationBindings.applicationInForeground, sharedContext.applicationBindings.applicationIsActive)
        |> deliverOnMainQueue).start(next: { [weak self] foreground, active in
            self?.active = foreground && active
            if !foreground || !active { self?.bridge.invalidatePresentations() }
            AyuPluginService.shared.applicationDidChange(inForeground: foreground, isActive: active)
        }))
    }

    deinit { self.disposables.dispose() }

    /// `telegram.navigation.open`: a chat (optionally at a message), a profile, or a username.
    /// The call completes once the push is issued on main; a username is resolved afterwards
    /// and a failure is shown with the app's own "not found" text.
    private func installPluginNavigator() {
        // The adapter calls this off main; each body below runs on the main queue, where this
        // class lives.
        AyuPluginTelegramAdapter.shared.setNavigator { [weak self] account, target, completion in
            let accountID = account.id
            switch target {
            case let .dialog(id, screen, messageID):
                let _ = (ayuPluginCachedPeer(account: account, dialogId: id) |> deliverOnMainQueue).start(next: { peer in
                    MainActor.assumeIsolated {
                        guard let peer else {
                            completion(.failure(.invalidArguments("dialog_id is not known to the account")))
                            return
                        }
                        guard let self, self.openPluginPeer(peer, accountID: accountID, profile: screen == .profile, messageID: messageID) else {
                            completion(.failure(.screenUnavailable))
                            return
                        }
                        completion(.success(()))
                    }
                })
            case let .username(name, type):
                Queue.mainQueue().async {
                    MainActor.assumeIsolated {
                        guard let self, self.pluginNavigationContext(accountID: accountID) != nil else {
                            completion(.failure(.screenUnavailable))
                            return
                        }
                        completion(.success(()))
                        self.openPluginUsername(name, type: type, accountID: accountID)
                    }
                }
            }
        }
    }

    private typealias PluginPlayerValue = (Account, SharedMediaPlayerItemPlaybackStateOrLoading, MediaManagerPlayerType)?

    /// `telegram.player`: the app's shared media player, which plays voice messages and music.
    /// An action is issued on main and answered with the state the player reports once the
    /// action shows in it, or after one second with the state it has then.
    private func installPluginPlayer() {
        AyuPluginTelegramAdapter.shared.setPlayer { [weak self] action, completion in
            Queue.mainQueue().async {
                MainActor.assumeIsolated {
                    guard let self, let mediaManager = self.sharedContext?.mediaManager else {
                        completion(.failure(.accountUnavailable))
                        return
                    }
                    self.performPluginPlayerAction(action, mediaManager: mediaManager, completion: completion)
                }
            }
        }
    }

    private static func pluginPlayback(_ value: PluginPlayerValue) -> SharedMediaPlayerItemPlaybackState? {
        guard let value, case let .state(state) = value.1 else { return nil }
        return state
    }

    private static func pluginPlaybackIsPaused(_ state: SharedMediaPlayerItemPlaybackState) -> Bool {
        switch state.status.status {
        case .playing: return false
        case .paused: return true
        case let .buffering(_, whilePlaying, _, _): return !whilePlaying
        }
    }

    private func performPluginPlayerAction(_ action: AyuPluginTelegramPlayerAction, mediaManager: MediaManager,
                                           completion: @escaping @Sendable (Result<AyuPluginTelegramPlayerState, AyuPluginTelegramBackendError>) -> Void) {
        let states = mediaManager.globalMediaPlayerState
        let _ = (states |> take(1) |> deliverOnMainQueue).start(next: { [weak self] before in
            MainActor.assumeIsolated {
                guard let self else {
                    completion(.failure(.accountUnavailable))
                    return
                }
                let playback = Self.pluginPlayback(before)
                // Whether a later state shows the action. Nothing loaded always does: there is
                // nothing the action could change.
                var settled: (SharedMediaPlayerItemPlaybackState) -> Bool = { _ in true }
                switch action {
                case .state:
                    break
                case .pause:
                    mediaManager.playlistControl(.playback(.pause), type: nil)
                    settled = { Self.pluginPlaybackIsPaused($0) }
                case .resume:
                    mediaManager.playlistControl(.playback(.play), type: nil)
                    settled = { !Self.pluginPlaybackIsPaused($0) }
                case .next, .previous:
                    mediaManager.playlistControl(action == .next ? .next : .previous, type: nil)
                    let item = playback?.item
                    settled = { !arePlaylistItemsEqual($0.item, item) }
                case .stop:
                    if let type = before?.2 {
                        mediaManager.setPlaylist(nil, type: type, control: .playback(.pause))
                    }
                    settled = { _ in false }
                case let .seek(progress):
                    if let playback, playback.status.duration > 0.0 {
                        mediaManager.playlistControl(.seek(playback.status.duration * progress), type: nil)
                        let seekId = playback.status.seekId
                        settled = { $0.status.seekId != seekId }
                    }
                }
                let shown = states
                |> filter { value -> Bool in
                    guard let value else { return true }
                    guard case let .state(state) = value.1 else { return false }
                    return settled(state)
                }
                |> take(1)
                |> timeout(1.0, queue: Queue.mainQueue(), alternate: states |> take(1))
                |> deliverOnMainQueue
                let _ = shown.start(next: { [weak self] value in
                    MainActor.assumeIsolated {
                        guard let self, let state = self.pluginPlayerState(value) else {
                            completion(.failure(.accountUnavailable))
                            return
                        }
                        completion(.success(state))
                    }
                })
            }
        })
    }

    /// Nothing is reported as loaded while the player switches items, and for an item that is
    /// not a cloud message the bridge can rebuild (an Instant View audio, a saved music file).
    private func pluginPlayerState(_ value: PluginPlayerValue) -> AyuPluginTelegramPlayerState? {
        if let value, case let .state(state) = value.1, let item = state.item as? MessageMediaPlaylistItem,
           let index = self.slots[value.0.id], let message = ayuPluginMessageTL(item.message) {
            let status = state.status
            var position = status.timestamp
            if case .playing = status.status {
                position += (CACurrentMediaTime() - status.generationTimestamp) * status.baseRate
            }
            let duration = max(0.0, status.duration)
            position = max(0.0, duration > 0.0 ? min(position, duration) : position)
            return AyuPluginTelegramPlayerState(accountIndex: index, paused: Self.pluginPlaybackIsPaused(state), message: message,
                progress: duration > 0.0 ? position / duration : 0.0,
                positionMilliseconds: Int64((position * 1000.0).rounded()), durationMilliseconds: Int64((duration * 1000.0).rounded()))
        }
        guard let selected = self.primaryID.flatMap({ self.slots[$0] }) else { return nil }
        return AyuPluginTelegramPlayerState(accountIndex: selected, paused: true)
    }

    private func openPluginUsername(_ name: String, type: Int32, accountID: AccountRecordId) {
        guard let context = self.pluginNavigationContext(accountID: accountID)?.0 else { return }
        let resolved = context.engine.peers.resolvePeerByName(name: name, referrer: nil)
        |> mapToSignal { result -> Signal<EnginePeer?, NoError> in
            if case let .result(peer) = result { return .single(peer) } else { return .complete() }
        }
        |> take(1)
        |> deliverOnMainQueue
        self.disposables.add(resolved.start(next: { [weak self] peer in
            guard let self else { return }
            guard let peer else {
                let strings = context.sharedContext.currentPresentationData.with { $0 }.strings
                let alert = UIAlertController(title: nil, message: strings.Resolve_ErrorNotFound, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: strings.Common_OK, style: .default))
                context.sharedContext.mainWindow?.presentNative(alert)
                return
            }
            // Android's openByUserName: type 0 opens the profile of a user that is not a bot.
            var profile = false
            if type == 0, case let .user(user) = peer, user.botInfo == nil { profile = true }
            let _ = self.openPluginPeer(peer, accountID: accountID, profile: profile, messageID: nil)
        }))
    }

    /// The account's context and the navigation stack, while that account's root is on screen.
    private func pluginNavigationContext(accountID: AccountRecordId) -> (AccountContext, NavigationController)? {
        guard self.active, !self.locked, let (rootID, root) = self.root(), rootID == accountID, accountID == self.primaryID,
              let context = self.accountContexts[accountID], let navigationController = root as? NavigationController else { return nil }
        return (context, navigationController)
    }

    private func openPluginPeer(_ peer: EnginePeer, accountID: AccountRecordId, profile: Bool, messageID: Int32?) -> Bool {
        guard let (context, navigationController) = self.pluginNavigationContext(accountID: accountID) else { return false }
        if profile {
            guard let controller = context.sharedContext.makePeerInfoController(context: context, updatedPresentationData: nil, peer: peer, mode: .generic,
                                                                                avatarInitiallyExpanded: false, fromChat: false, requestsContext: nil) else { return false }
            navigationController.pushViewController(controller)
        } else {
            var subject: ChatControllerSubject?
            if let messageID {
                subject = .message(id: .id(EngineMessage.Id(peerId: peer.id, namespace: Namespaces.Message.Cloud, id: messageID)),
                                   highlight: ChatControllerSubject.MessageHighlight(quote: nil), timecode: nil, setupReply: false)
            }
            context.sharedContext.navigateToChatController(NavigateToChatControllerParams(navigationController: navigationController, context: context,
                                                                                          chatLocation: .peer(peer), subject: subject))
        }
        return true
    }

    private func publishAccounts() {
        // The adapter first: the bridge must never resolve a slot the Telegram backend does not know yet.
        AyuPluginTelegramAdapter.shared.setAccounts(self.accountContexts.compactMap { entry -> AyuPluginTelegramAdapter.Slot? in
            guard let slot = self.slots[entry.key], let identity = self.identities[entry.key] else { return nil }
            return AyuPluginTelegramAdapter.Slot(index: slot, identity: identity, account: entry.value.account)
        })
        self.bridge.updateAccounts(Array(self.accountSnapshots.values), selected: self.primaryID.flatMap { self.slots[$0] })
    }

    /// Process-stable bridge slot for a Telegram account. The bridge never sees
    /// AccountRecordId or any other private account identity.
    func bridgeSlot(for id: AccountRecordId) -> Int64? {
        return self.slots[id]
    }

    /// Pin and later revalidate the real visible root and account identity.
    /// `screen()` fails closed when the app is locked, inactive or covered.
    func pluginMenuContext(accountID: AccountRecordId, peerID: EnginePeer.Id, messageID: Int64) -> AyuPluginMenuContext? {
        guard messageID > 0, self.active, !self.locked,
              let accountIndex = self.slots[accountID], let accountIdentity = self.identities[accountID],
              let dialogID = AyuPluginMessageMenuInvocation.dialogID(for: peerID),
              let visible = self.screen(), visible.accountIndex == accountIndex, visible.dialogID == dialogID else { return nil }
        return AyuPluginMenuContext(screenIdentity: visible.identity, accountIdentity: accountIdentity,
            accountIndex: accountIndex, dialogID: dialogID, messageID: messageID)
    }

    func isCurrentPluginMenuContext(_ context: AyuPluginMenuContext, accountID: AccountRecordId, peerID: EnginePeer.Id) -> Bool {
        guard self.active, !self.locked, self.slots[accountID] == context.accountIndex,
              self.identities[accountID] == context.accountIdentity,
              let dialogID = AyuPluginMessageMenuInvocation.dialogID(for: peerID), dialogID == context.dialogID,
              let visible = self.screen(), visible.identity == context.screenIdentity,
              visible.accountIndex == context.accountIndex, visible.dialogID == context.dialogID else { return false }
        return true
    }

    /// Menu requests name the account by `AccountRecordId.int64` (nil: the
    /// primary account), so modules below TelegramUI can ask for plugin rows.
    private func pluginMenuAccountID(_ key: Int64?) -> AccountRecordId? {
        guard let key else { return self.primaryID }
        return self.slots.keys.first(where: { $0.int64 == key })
    }

    /// Pins a menu request to the bridge slot and the visible screen. Secret and
    /// local peers have no Android dialog id: their menus get no plugin rows.
    func pluginMenuLocation(_ request: AyuPluginMenuRequest) -> AyuPluginMenuLocation? {
        guard self.active, !self.locked, let accountID = self.pluginMenuAccountID(request.accountKey),
              let accountIdentity = self.identities[accountID],
              let visible = self.screen(), visible.accountIndex == self.slots[accountID] else { return nil }
        var dialogID: Int64?
        if let peer = request.peer {
            let peerID = EnginePeer.Id(namespace: EnginePeer.Id.Namespace._internalFromInt32Value(peer.namespace), id: EnginePeer.Id.Id._internalFromInt64Value(peer.id))
            guard let mapped = AyuPluginMessageMenuInvocation.dialogID(for: peerID) else { return nil }
            dialogID = mapped
        }
        return AyuPluginMenuLocation(kind: request.kind, screen: visible, accountIdentity: accountIdentity, dialogID: dialogID, messageID: request.messageID)
    }

    func isCurrentPluginMenuLocation(_ location: AyuPluginMenuLocation, request: AyuPluginMenuRequest) -> Bool {
        guard self.active, !self.locked, let accountID = self.pluginMenuAccountID(request.accountKey),
              self.slots[accountID] == location.accountIndex else { return false }
        return location.isCurrent(screen: self.screen(), accountIdentity: self.identities[accountID])
    }

    private func visibleController() -> (Int64, UIViewController)? {
        guard self.active, !self.locked, let (id, root) = self.root(), id == self.primaryID,
              let slot = self.slots[id], self.identities[id] != nil else { return nil }
        var controller: UIViewController? = root
        if let navigation = controller as? NavigationController { controller = navigation.topViewController }
        if let tab = controller as? TabBarControllerImpl { controller = tab.currentController }
        guard let controller, controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else { return nil }
        if let chat = controller as? ChatControllerImpl, chat.context.account.id != id { return nil }
        return (slot, controller)
    }

    private func screen() -> AyuPluginScreenSnapshot? {
        guard let (slot, controller) = self.visibleController() else { return nil }
        var dialogID: Int64?
        var isGroup = false
        var isChannel = false
        if let chat = controller as? ChatControllerImpl, let peerID = chat.chatLocation.peerId {
            let id = peerID.id._internalGetInt64Value()
            switch peerID.namespace {
            case Namespaces.Peer.CloudUser: dialogID = id
            case Namespaces.Peer.CloudGroup: dialogID = -id; isGroup = true
            case Namespaces.Peer.CloudChannel:
                dialogID = -id
                let kind = chat.ayuNativePluginChatKind()
                isChannel = kind.channel
                isGroup = kind.group
            default: break // Secret/local IDs are not Android dialog IDs.
            }
        }
        if self.lastController !== controller || self.lastAccount != slot || self.lastDialog != dialogID {
            self.screenIdentity = UUID(); self.lastController = controller; self.lastAccount = slot; self.lastDialog = dialogID
        }
        // `telegram.screen`: the same controller and dialog the fragment adapter reads above.
        var telegram = AyuPluginTelegramScreen(kind: .other)
        if let chat = controller as? ChatControllerImpl {
            if let dialogID {
                var chatMode: Int32 = 0
                if case .some(.scheduledMessages) = chat.subject { chatMode = 1 } else if case .some(.pinnedMessages) = chat.subject { chatMode = 2 }
                telegram = AyuPluginTelegramScreen(kind: .chat, dialogID: dialogID, topicID: chat.chatLocation.threadId.flatMap { Int32(exactly: $0) }, chatMode: chatMode)
            }
        } else if let profile = controller as? PeerInfoScreen {
            if let profileDialogID = ayuPluginDialogId(peerId: profile.peerId) {
                telegram = AyuPluginTelegramScreen(kind: .profile, dialogID: profileDialogID)
            }
        } else if controller is ChatListController {
            telegram = AyuPluginTelegramScreen(kind: .dialogs)
        }
        return AyuPluginScreenSnapshot(identity: self.screenIdentity, accountIndex: slot, dialogID: dialogID, isGroup: isGroup, isChannel: isChannel, telegram: telegram)
    }

    /// `BaseFragment.finishFragment`: pops the screen the plugin's fragment stands for. The first
    /// screen of the stack stays: Android closes the app's window there, which a plugin must not do here.
    private func closePluginScreen(_ expected: AyuPluginScreenSnapshot, animated: Bool) {
        guard self.active, !self.locked,
              let (accountID, rootController) = self.root(),
              let current = self.screen(), current.identity == expected.identity,
              current.accountIndex == expected.accountIndex,
              accountID == self.primaryID,
              let navigationController = rootController as? NavigationController,
              navigationController.viewControllers.count > 1 else { return }
        navigationController.view.endEditing(true)
        let _ = navigationController.popViewController(animated: animated)
    }

    private func openPluginURL(_ url: URL, screen expected: AyuPluginScreenSnapshot) {
        guard self.active, !self.locked,
              let (accountID, rootController) = self.root(),
              let current = self.screen(), current.identity == expected.identity,
              current.accountIndex == expected.accountIndex,
              accountID == self.primaryID,
              self.slots[accountID] == expected.accountIndex, self.identities[accountID] != nil,
              let sharedContext = self.sharedContext, let accountContext = self.accountContexts[accountID],
              let navigationController = rootController as? NavigationController else { return }
        let presentationData = sharedContext.currentPresentationData.with { $0 }
        // Past the plugins' `Browser.openUrl` hooks: a plugin's own `startActivity(ACTION_VIEW)` never enters that
        // method on Android, and a hook that cancels a link and opens another one would be asked about its own URL.
        openExternalUrlImpl(context: accountContext, urlContext: .generic, url: url.absoluteString,
            forceExternal: false, presentationData: presentationData, navigationController: navigationController,
            dismissInput: { [weak navigationController] in navigationController?.view.endEditing(true) })
    }
}

@MainActor func ayuPluginBridgeAccountIndex(for id: AccountRecordId) -> Int64? {
    return AyuTelegramPluginApplicationBinding.current?.bridgeSlot(for: id)
}
