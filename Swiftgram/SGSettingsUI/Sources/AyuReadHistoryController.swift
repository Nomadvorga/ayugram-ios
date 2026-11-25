import AccountContext
import Display
import Foundation
import ItemListUI
import SGStrings
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import UIKit

private struct AyuReadSubmission: Equatable {
    var total = 0
    var outcomes: [AyuReadHistoryEnqueueResult] = []
}

private struct AyuReadStatusEntry: ItemListNodeEntry {
    enum Content: Equatable {
        case header(String)
        case notice(String)
        case pending(String, AyuReadHistoryPending)
        case failure(String, AyuReadHistoryFailure)
    }

    let stableId: String
    let index: Int
    let section: ItemListSectionId
    let content: Content

    static func <(lhs: Self, rhs: Self) -> Bool { lhs.index < rhs.index }

    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let actions = arguments as! AyuReadStatusActions
        switch self.content {
        case let .header(text):
            return ItemListSectionHeaderItem(presentationData: presentationData, text: text, sectionId: self.section)
        case let .notice(text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        case let .pending(title, pending):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: pending.attempts == 0 ? actions.text("Pending", "Pending") : actions.text("RetryPending", "Waiting to retry"), sectionId: self.section, style: .blocks, action: { [weak actions] in actions?.manage(pending, title: title) })
        case let .failure(title, failure):
            return ItemListDisclosureItem(presentationData: presentationData, systemStyle: .glass, title: title, label: actions.text("Failed", "Read failed"), sectionId: self.section, style: .blocks, action: { [weak actions] in actions?.manage(failure, title: title) })
        }
    }
}

/// Reopening this account-scoped screen only observes persisted status. Callers
/// may pass requests only from the action/confirmation that authorized the read.
/// The screen never treats enqueue or disappearance of a pending row as success.
public func ayuReadHistoryController(context: AccountContext, peerId: EnginePeer.Id? = nil, requests: [AyuReadHistoryRequest] = [], onAccepted: ((AyuReadHistoryRequest) -> Void)? = nil) -> ViewController {
    let actions = AyuReadStatusActions(context: context)
    let status = ayuReadHistoryState(account: context.account)
    |> mapToSignal { snapshot -> Signal<(AyuReadHistorySnapshot, [EnginePeer.Id: String]), NoError> in
        let ids = Set(snapshot.pending.map(\.peerIdValue) + snapshot.failures.map(\.peerIdValue) + snapshot.receipts.map(\.peerIdValue) + [context.account.peerId.toInt64()])
        return context.engine.data.subscribe(EngineDataMap(ids.map { TelegramEngine.EngineData.Item.Peer.Peer(id: EnginePeer.Id($0)) }))
        |> map { peers in
            var names: [EnginePeer.Id: String] = [:]
            for (id, peer) in peers {
                if let peer { names[id] = peer.debugDisplayTitle }
            }
            return (snapshot, names)
        }
    }
    let signal = combineLatest(context.sharedContext.presentationData, status, context.account.network.connectionStatus, context.account.loggedOut, actions.submission.get(), actions.notice.get())
    |> deliverOnMainQueue
    |> map { presentationData, statusAndNames, connection, loggedOut, submission, notice -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let (snapshot, names) = statusAndNames
        actions.active = !loggedOut && !snapshot.closed && snapshot.ownerIdValue == context.account.peerId.toInt64()
        let lang = presentationData.strings.baseLanguageCode
        func text(_ key: String, _ fallback: String) -> String {
            let fullKey = "Ayu.ReadStatus." + key
            let value = i18n(fullKey, lang)
            return value == fullKey ? fallback : value
        }
        func name(_ value: Int64) -> String { names[EnginePeer.Id(value)] ?? text("UnknownChat", "Chat") }
        func matches(_ value: Int64) -> Bool { peerId == nil || peerId?.toInt64() == value }
        var entries: [AyuReadStatusEntry] = []
        func add(_ id: String, _ section: Int32, _ content: AyuReadStatusEntry.Content) {
            entries.append(.init(stableId: id, index: entries.count, section: section, content: content))
        }
        add("account", 0, .header(text("Account", "Account") + ": " + name(context.account.peerId.toInt64())))
        if !actions.active {
            add("closed", 0, .notice(text("LoggedOut", "This account is no longer active. Pending reads were cleared.")))
        } else {
            add("info", 0, .notice(text("Info", "Queued reads continue when connected. Select a request to stop retries or retry the same messages.")))
            if !snapshot.pending.isEmpty {
                switch connection {
                case .waitingForNetwork, .connecting:
                    add("offline", 0, .notice(text("Offline", "Waiting for a connection. These reads have not been confirmed by Telegram.")))
                case .online, .updating: break
                }
            }
            if submission.total > 0 {
                let accepted = submission.outcomes.filter { $0 == .queued || $0 == .coalesced }.count
                let completed = submission.outcomes.count == submission.total
                let format = completed ? text("Accepted", "{accepted} of {total} read requests accepted. Check their delivery status below.") : text("Submitting", "Saving read requests…")
                add("submission", 0, .notice(format.replacingOccurrences(of: "{accepted}", with: String(accepted)).replacingOccurrences(of: "{total}", with: String(submission.total))))
                if submission.outcomes.contains(.queueFull) {
                    add("enqueueFull", 0, .notice(text("QueueFull", "Too many unresolved read requests. Resolve or cancel a request, then retry.")))
                }
                if submission.outcomes.contains(.invalidInput) {
                    add("enqueueInvalid", 0, .notice(text("UnknownRange", "The message range is unavailable. Open the chat and choose Read again.")))
                }
                if submission.outcomes.contains(.loggedOut) {
                    add("enqueueLogout", 0, .notice(text("LoggedOut", "This account is no longer active. Pending reads were cleared.")))
                }
            }
            if let notice { add("notice", 0, .notice(notice)) }
            let pending = snapshot.pending.filter { matches($0.peerIdValue) }
            let failures = snapshot.failures.filter { matches($0.peerIdValue) }
            let receipts = snapshot.receipts.filter { matches($0.peerIdValue) }
            if !pending.isEmpty { add("pending", 1, .header(text("Pending", "Pending"))) }
            for item in pending {
                add("pending." + item.id, 1, .pending(name(item.peerIdValue), item))
                var detail = actions.range(item.maxId)
                if item.attempts > 0 {
                    detail += "\n" + text("RetryAfter", "Earliest retry: {date}").replacingOccurrences(of: "{date}", with: actions.date(item.retryAt))
                }
                add("bound." + item.id, 1, .notice(detail))
            }
            if !failures.isEmpty { add("failures", 2, .header(text("Errors", "Read errors"))) }
            for item in failures.reversed() {
                add("failure." + item.id, 2, .failure(name(item.peerIdValue), item))
                add("reason." + item.id, 2, .notice(actions.failureText(item)))
            }
            if !receipts.isEmpty { add("receipts", 3, .header(text("Recent", "Recent results"))) }
            for item in receipts.reversed() {
                let result = item.status == .confirmed ? text("Confirmed", "Confirmed by Telegram") : text("Cancelled", "Retries stopped; delivery may have occurred")
                add("receipt." + item.id, 3, .notice(name(item.peerIdValue) + "\n" + result + "\n" + actions.range(item.maxId) + " · " + actions.date(item.timestamp)))
            }
            if pending.isEmpty && failures.isEmpty && receipts.isEmpty {
                add("empty", 1, .notice(text("Empty", "No saved read requests for this selection.")))
            }
        }
        let allButton: ItemListNavigationButton? = peerId == nil ? nil : ItemListNavigationButton(content: .text(text("AllChats", "All Chats")), style: .regular, enabled: actions.active, action: { [weak actions] in actions?.showAll() })
        let state = ItemListControllerState(presentationData: ItemListPresentationData(presentationData), title: .text(text("Title", "Read Receipts")), leftNavigationButton: nil, rightNavigationButton: allButton, backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back))
        return (state, (ItemListNodeState(presentationData: ItemListPresentationData(presentationData), entries: entries, style: .blocks, animateChanges: false), actions))
    }
    let controller = ItemListController(context: context, state: signal)
    actions.controller = controller
    // This is intentionally outside all signal/map/view-appearance callbacks.
    // Rebuilding or revisiting a page cannot authorize another read.
    actions.submit(requests, onAccepted: onAccepted)
    return controller
}

private final class AyuReadStatusActions {
    let context: AccountContext
    let submission = ValuePromise(AyuReadSubmission(), ignoreRepeated: true)
    let notice = ValuePromise<String?>(nil, ignoreRepeated: true)
    weak var controller: ViewController?
    var active = true
    private var submitted = AyuReadSubmission()
    private let controlDisposable = MetaDisposable()

    init(context: AccountContext) { self.context = context }

    deinit { self.controlDisposable.dispose() }

    func text(_ key: String, _ fallback: String) -> String {
        let fullKey = "Ayu.ReadStatus." + key
        let value = i18n(fullKey, self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
        return value == fullKey ? fallback : value
    }

    func range(_ id: Int32) -> String {
        return self.text("ThroughMessage", "Read through message {id}").replacingOccurrences(of: "{id}", with: String(id))
    }

    func date(_ time: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: self.context.sharedContext.currentPresentationData.with { $0 }.strings.baseLanguageCode)
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: time))
    }

    func submit(_ requests: [AyuReadHistoryRequest], onAccepted: ((AyuReadHistoryRequest) -> Void)?) {
        guard !requests.isEmpty else { return }
        self.submitted.total = requests.count
        self.submission.set(self.submitted)
        for request in requests {
            ayuReadHistoryOnServer(account: self.context.account, peerId: EnginePeer.Id(request.peerIdValue), maxId: request.maxId, completion: { [weak self] result in
                if result == .queued || result == .coalesced { onAccepted?(request) }
                guard let self else { return }
                self.submitted.outcomes.append(result)
                self.submission.set(self.submitted)
            })
        }
    }

    func showAll() {
        guard self.active else { return }
        self.controller?.push(ayuReadHistoryController(context: self.context))
    }

    func failureText(_ failure: AyuReadHistoryFailure) -> String {
        switch failure.code {
        case "LOCAL_QUEUE_FULL": return self.text("QueueFull", "Too many unresolved read requests. Resolve or cancel a request, then retry.")
        case "LOCAL_READ_BOUND_UNAVAILABLE", "LOCAL_INVALID_MESSAGE": return self.text("UnknownRange", "The message range is unavailable. Open the chat and choose Read again.")
        case "LOCAL_UNSUPPORTED_PEER": return self.text("Unsupported", "This chat does not support this read action.")
        default: return self.text("ServerRejected", "Telegram rejected this read. You can retry the same messages or dismiss the error.") + "\n" + self.range(failure.maxId)
        }
    }

    func manage(_ pending: AyuReadHistoryPending, title: String) {
        guard self.active else { return }
        let message = self.range(pending.maxId) + "\n\n" + self.text("CancelInfo", "Stopping retries cannot retract a read Telegram has already received.")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: self.text("Retry", "Retry This Read"), style: .default, handler: { [weak self] _ in
            self?.run(.retryPending(id: pending.id, maxId: pending.maxId))
        }))
        alert.addAction(UIAlertAction(title: self.text("Stop", "Stop Retries"), style: .destructive, handler: { [weak self] _ in
            self?.run(.cancel(id: pending.id, maxId: pending.maxId))
        }))
        self.present(alert)
    }

    func manage(_ failure: AyuReadHistoryFailure, title: String) {
        guard self.active else { return }
        let alert = UIAlertController(title: title, message: self.failureText(failure), preferredStyle: .alert)
        if failure.maxId > 0 && failure.maxId < Int32.max - 1 && (failure.code == "LOCAL_QUEUE_FULL" || !failure.code.hasPrefix("LOCAL_")) {
            alert.addAction(UIAlertAction(title: self.text("Retry", "Retry This Read"), style: .default, handler: { [weak self] _ in
                self?.run(.retryFailure(id: failure.id))
            }))
        }
        alert.addAction(UIAlertAction(title: self.text("DismissError", "Dismiss Error"), style: .destructive, handler: { [weak self] _ in
            self?.run(.dismissFailure(id: failure.id))
        }))
        self.present(alert)
    }

    private func present(_ alert: UIAlertController) {
        alert.addAction(UIAlertAction(title: self.context.sharedContext.currentPresentationData.with { $0 }.strings.Common_Cancel, style: .cancel))
        self.controller?.present(alert, animated: true)
    }

    private func run(_ action: AyuReadHistoryControl) {
        guard self.active else { return }
        self.controlDisposable.set((ayuControlReadHistory(account: self.context.account, action: action) |> deliverOnMainQueue).start(next: { [weak self] result in
            guard let self else { return }
            let message: String
            switch result {
            case .applied: message = self.text("Updated", "Read request updated. Check its current status below.")
            case .stale: message = self.text("Stale", "This read request has changed. Review its current status before acting again.")
            case .waitingForRetry: message = self.text("Wait", "The saved retry delay has not elapsed. The request remains queued.")
            case .queueFull: message = self.text("QueueFull", "Too many unresolved read requests. Resolve or cancel a request, then retry.")
            case .invalidInput: message = self.text("UnknownRange", "The message range is unavailable. Open the chat and choose Read again.")
            case .loggedOut: message = self.text("LoggedOut", "This account is no longer active. Pending reads were cleared.")
            }
            self.notice.set(message)
        }))
    }
}
