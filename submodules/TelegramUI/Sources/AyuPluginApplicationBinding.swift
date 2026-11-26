import AccountContext
import AppLock
import AyuPluginBridge
import Display
import Foundation
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
        bridge.bindScreen(screen: { [weak self] in self?.screen() }, presenter: { [weak self] in self?.visibleController()?.1 }, presentAlert: { [weak sharedContext] alert in
            sharedContext?.mainWindow?.presentNative(alert)
        }, openURL: { [weak self] screen, url in
            self?.openPluginURL(url, screen: screen)
        }, localeIdentifier: { [weak sharedContext] in
            sharedContext?.currentPresentationData.with { $0 }.strings.baseLanguageCode ?? Locale.current.identifier
        })
        AyuNativePluginRuntime.shared.presenter = { [weak self] in
            self?.visibleController()?.1
        }
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

    private func publishAccounts() {
        self.bridge.updateAccounts(Array(self.accountSnapshots.values), selected: self.primaryID.flatMap { self.slots[$0] })
    }

    /// Process-stable bridge slot for a Telegram account. The bridge never sees
    /// AccountRecordId or any other private account identity.
    func bridgeSlot(for id: AccountRecordId) -> Int64? {
        return self.slots[id]
    }

    /// Pin and later revalidate the real visible root and account identity.
    /// `screen()` fails closed when the app is locked, inactive or covered.
    func pluginMenuContext(accountID: AccountRecordId, peerID: PeerId, messageID: Int64) -> AyuPluginMenuContext? {
        guard messageID > 0, self.active, !self.locked,
              let accountIndex = self.slots[accountID], let accountIdentity = self.identities[accountID],
              let dialogID = AyuPluginMessageMenuInvocation.dialogID(for: peerID),
              let visible = self.screen(), visible.accountIndex == accountIndex, visible.dialogID == dialogID else { return nil }
        return AyuPluginMenuContext(screenIdentity: visible.identity, accountIdentity: accountIdentity,
            accountIndex: accountIndex, dialogID: dialogID, messageID: messageID)
    }

    func isCurrentPluginMenuContext(_ context: AyuPluginMenuContext, accountID: AccountRecordId, peerID: PeerId) -> Bool {
        guard self.active, !self.locked, self.slots[accountID] == context.accountIndex,
              self.identities[accountID] == context.accountIdentity,
              let dialogID = AyuPluginMessageMenuInvocation.dialogID(for: peerID), dialogID == context.dialogID,
              let visible = self.screen(), visible.identity == context.screenIdentity,
              visible.accountIndex == context.accountIndex, visible.dialogID == context.dialogID else { return false }
        return true
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
        return AyuPluginScreenSnapshot(identity: self.screenIdentity, accountIndex: slot, dialogID: dialogID, isGroup: isGroup, isChannel: isChannel)
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
        sharedContext.openExternalUrl(context: accountContext, urlContext: .generic, url: url.absoluteString,
            forceExternal: false, presentationData: presentationData, navigationController: navigationController,
            dismissInput: { [weak navigationController] in navigationController?.view.endEditing(true) })
    }
}

@MainActor func ayuPluginBridgeAccountIndex(for id: AccountRecordId) -> Int64? {
    return AyuTelegramPluginApplicationBinding.current?.bridgeSlot(for: id)
}
