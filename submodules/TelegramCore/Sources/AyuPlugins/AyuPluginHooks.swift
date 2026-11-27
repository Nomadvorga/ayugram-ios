import Foundation
import MtProtoKit
import Postbox
import SwiftSignalKit
internal import TelegramApi

/// What the plugin bridge wants to see of an account's traffic: the constructors some plugin
/// hooks, and where to ask. Installed as a whole by `ayuPluginSetHookInterceptor`; nil (no plugin
/// hooks anything) is the state every hook point checks first.
///
/// The closures may be called on any queue and must call their completion exactly once, on any
/// queue, within a bounded time. A nil object in a completion cancels the request, drops the
/// update or drops the container.
public final class AyuPluginHookInterceptor {
    public typealias RPCError = (code: Int32, text: String)

    public let requests: Set<Int32>
    public let updates: Set<Int32>
    public let containers: Set<Int32>
    /// False for a network the bridge does not serve (another account's, or one that is not
    /// logged in): its traffic is never shown.
    let servesNetwork: (Network) -> Bool
    let servesAccount: (PeerId) -> Bool
    let interceptRequest: (Network, Data, @escaping (Data?) -> Void) -> Void
    let interceptResponse: (Network, Int32, Data?, RPCError?, @escaping (Data?, RPCError?) -> Void) -> Void
    let interceptContainer: (PeerId, Data, @escaping (Data?) -> Void) -> Void
    let interceptUpdate: (PeerId, Data, @escaping (Data?) -> Void) -> Void

    public init(
        requests: Set<Int32>,
        updates: Set<Int32>,
        containers: Set<Int32>,
        servesNetwork: @escaping (Network) -> Bool,
        servesAccount: @escaping (PeerId) -> Bool,
        interceptRequest: @escaping (Network, Data, @escaping (Data?) -> Void) -> Void,
        interceptResponse: @escaping (Network, Int32, Data?, RPCError?, @escaping (Data?, RPCError?) -> Void) -> Void,
        interceptContainer: @escaping (PeerId, Data, @escaping (Data?) -> Void) -> Void,
        interceptUpdate: @escaping (PeerId, Data, @escaping (Data?) -> Void) -> Void
    ) {
        self.requests = requests
        self.updates = updates
        self.containers = containers
        self.servesNetwork = servesNetwork
        self.servesAccount = servesAccount
        self.interceptRequest = interceptRequest
        self.interceptResponse = interceptResponse
        self.interceptContainer = interceptContainer
        self.interceptUpdate = interceptUpdate
    }
}

/// One unfair lock around one pointer and one counter: the only cost a hook point pays while no
/// plugin hooks anything.
private final class AyuPluginHookInterceptorStorage {
    private let lock: UnsafeMutablePointer<os_unfair_lock>
    private var interceptor: AyuPluginHookInterceptor?
    private var busyGates = 0

    init() {
        self.lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())
    }

    deinit {
        self.lock.deinitialize(count: 1)
        self.lock.deallocate()
    }

    var current: AyuPluginHookInterceptor? {
        os_unfair_lock_lock(self.lock)
        let result = self.interceptor
        os_unfair_lock_unlock(self.lock)
        return result
    }

    var state: (interceptor: AyuPluginHookInterceptor?, holdsTraffic: Bool) {
        os_unfair_lock_lock(self.lock)
        let result = (self.interceptor, self.busyGates != 0)
        os_unfair_lock_unlock(self.lock)
        return result
    }

    func set(_ interceptor: AyuPluginHookInterceptor?) {
        os_unfair_lock_lock(self.lock)
        let previous = self.interceptor
        self.interceptor = interceptor
        os_unfair_lock_unlock(self.lock)
        withExtendedLifetime(previous) {}
    }

    func gateBusyChanged(_ busy: Bool) {
        os_unfair_lock_lock(self.lock)
        self.busyGates += busy ? 1 : -1
        os_unfair_lock_unlock(self.lock)
    }
}

private let ayuPluginHookInterceptorStorage = AyuPluginHookInterceptorStorage()

/// Replaces the interceptor; nil when no plugin hooks anything.
public func ayuPluginSetHookInterceptor(_ interceptor: AyuPluginHookInterceptor?) {
    ayuPluginHookInterceptorStorage.set(interceptor)
}

/// The interceptor, when one is installed and `listing` holds `constructorId`.
func ayuPluginHookInterceptor(listing: KeyPath<AyuPluginHookInterceptor, Set<Int32>>, constructorId: Int32) -> AyuPluginHookInterceptor? {
    guard let interceptor = ayuPluginHookInterceptorStorage.current, interceptor[keyPath: listing].contains(constructorId) else {
        return nil
    }
    return interceptor
}

func ayuPluginHasHookInterceptor() -> Bool {
    return ayuPluginHookInterceptorStorage.current != nil
}

/// What a hook point reads first: the interceptor, and whether some gate still holds traffic
/// that waits for a plugin (it then has to keep later traffic in order even after the last hook
/// was removed). `(nil, false)` means the point does nothing.
func ayuPluginHookState() -> (interceptor: AyuPluginHookInterceptor?, holdsTraffic: Bool) {
    return ayuPluginHookInterceptorStorage.state
}

/// A gate of a hook point; while it is busy `ayuPluginHookState().holdsTraffic` is true.
func ayuPluginMakeHookGate() -> AyuPluginOrderedGate {
    return AyuPluginOrderedGate(busyChanged: { busy in
        ayuPluginHookInterceptorStorage.gateBusyChanged(busy)
    })
}

/// Shows the response of a request whose function is hooked to the plugins. `completion` runs
/// synchronously when nothing is hooked.
func ayuPluginInterceptResponse(network: Network, constructorId: Int32, response: Data?, error: MTRpcError?, completion: @escaping (Data?, MTRpcError?) -> Void) {
    guard let interceptor = ayuPluginHookInterceptor(listing: \.requests, constructorId: constructorId), interceptor.servesNetwork(network) else {
        completion(response, error)
        return
    }
    interceptor.interceptResponse(network, constructorId, response, error.flatMap { (code: $0.errorCode, text: $0.errorDescription ?? "") }, { response, error in
        completion(response, error.flatMap { MTRpcError(errorCode: $0.code, errorDescription: $0.text) })
    })
}

/// Whether TelegramCore shows the plugin bridge all four hook streams: the requests of the main
/// session of every caller (`AyuPluginHookedRequestService`), their responses, update containers
/// and single updates (`AyuPluginUpdateHooks.swift`). The bridge may offer `telegram.hooks.set`
/// only when it does.
public let ayuPluginInterceptsAllHookStreams = true
