import Foundation
internal import TelegramApi
import Postbox
import SwiftSignalKit
import MtProtoKit
import SGSimpleSettings

private typealias SignalKitTimer = SwiftSignalKit.Timer


private final class AccountPresenceManagerImpl {
    private let queue: Queue
    private let network: Network
    let isPerformingUpdate = ValuePromise<Bool>(false, ignoreRepeated: true)
    
    private var shouldKeepOnlinePresenceDisposable: Disposable?
    private let currentRequestDisposable = MetaDisposable()
    private var onlineTimer: SignalKitTimer?
    
    private var wasOnline: Bool = false
    // MARK: AyuGram
    private var ayuLastSentOnline: Bool = false
    private var ayuSuppressesOnline: Bool = AyuGhostSettings.shared.suppressOnlineStatus
    private var ayuSettingsObserver: NSObjectProtocol?
    
    init(queue: Queue, shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        self.queue = queue
        self.network = network
        
        // MARK: AyuGram
        // Turning ghost mode on while the app is open hides the online status at once, turning it off shows it.
        self.ayuSettingsObserver = NotificationCenter.default.addObserver(forName: ayuSettingsDidChangeNotification, object: nil, queue: nil, using: { [weak self] _ in
            queue.async {
                self?.ayuGhostSettingsChanged()
            }
        })
        
        self.shouldKeepOnlinePresenceDisposable = (shouldKeepOnlinePresence
        |> distinctUntilChanged
        |> deliverOn(self.queue)).start(next: { [weak self] value in
            guard let `self` = self else {
                return
            }
            if self.wasOnline != value {
                self.wasOnline = value
                self.updatePresence(value)
            }
        })
    }
    
    deinit {
        assert(self.queue.isCurrent())
        self.shouldKeepOnlinePresenceDisposable?.dispose()
        self.currentRequestDisposable.dispose()
        self.onlineTimer?.invalidate()
        if let ayuSettingsObserver = self.ayuSettingsObserver {
            NotificationCenter.default.removeObserver(ayuSettingsObserver)
        }
    }
    
    // MARK: AyuGram
    private func ayuGhostSettingsChanged() {
        let suppressesOnline = AyuGhostSettings.shared.suppressOnlineStatus
        if suppressesOnline != self.ayuSuppressesOnline {
            self.ayuSuppressesOnline = suppressesOnline
            if self.wasOnline {
                self.updatePresence(true)
            }
        }
    }
    
    private func updatePresence(_ isOnline: Bool) {
        let request: Signal<Api.Bool, MTRpcError>
        // MARK: AyuGram
        // Ghost presence as in Telegram-iOS-Ghost: Telegram's 30-second online refresh timer is not created; an
        // online status already announced is ended at once, and "Send offline packet" keeps "last seen" moving.
        if isOnline && AyuGhostSettings.shared.suppressOnlineStatus {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            if !self.ayuLastSentOnline && !AyuGhostSettings.shared.sendAutomaticOffline {
                self.currentRequestDisposable.set(nil)
                self.isPerformingUpdate.set(false)
                return
            }
            self.ayuLastSentOnline = false
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue), ayuBypassGhost: true)
        } else if isOnline {
            let timer = SignalKitTimer(timeout: 30.0, repeat: false, completion: { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updatePresence(true)
            }, queue: self.queue)
            self.onlineTimer = timer
            timer.start()
            self.ayuLastSentOnline = true // MARK: AyuGram
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolFalse), ayuBypassGhost: true)
        } else {
            self.onlineTimer?.invalidate()
            self.onlineTimer = nil
            // MARK: AyuGram
            if AyuGhostSettings.shared.suppressOnlineStatus && !self.ayuLastSentOnline && !AyuGhostSettings.shared.sendAutomaticOffline {
                return
            }
            self.ayuLastSentOnline = false
            request = self.network.request(Api.functions.account.updateStatus(offline: .boolTrue))
        }
        self.isPerformingUpdate.set(true)
        self.currentRequestDisposable.set((request
        |> `catch` { _ -> Signal<Api.Bool, NoError> in
            return .single(.boolFalse)
        }
        |> deliverOn(self.queue)).start(completed: { [weak self] in
            guard let strongSelf = self else {
                return
            }
            strongSelf.isPerformingUpdate.set(false)
        }))
    }
}

final class AccountPresenceManager {
    private let queue = Queue()
    private let impl: QueueLocalObject<AccountPresenceManagerImpl>
    
    init(shouldKeepOnlinePresence: Signal<Bool, NoError>, network: Network) {
        let queue = self.queue
        self.impl = QueueLocalObject(queue: self.queue, generate: {
            return AccountPresenceManagerImpl(queue: queue, shouldKeepOnlinePresence: shouldKeepOnlinePresence, network: network)
        })
    }
    
    func isPerformingUpdate() -> Signal<Bool, NoError> {
        return Signal { subscriber in
            let disposable = MetaDisposable()
            self.impl.with { impl in
                disposable.set(impl.isPerformingUpdate.get().start(next: { value in
                    subscriber.putNext(value)
                }))
            }
            return disposable
        }
    }
}
