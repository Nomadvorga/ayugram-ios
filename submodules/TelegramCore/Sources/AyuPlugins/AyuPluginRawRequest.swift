import Foundation
import MtProtoKit
import SwiftSignalKit
internal import TelegramApi

/// Failures of the plugin bridge's TelegramCore surface (`Sources/AyuPlugins`). The text names
/// an argument or a capability; it never carries account data.
public enum AyuPluginCoreError: Error, Equatable {
    case invalidArguments(String)
    case unsupported(String)
}

public enum AyuPluginRawRequestResult {
    /// The response exactly as the server sent it (after gzip unwrapping): a boxed object, or a
    /// bare vector for a function that returns one.
    case response(Data)
    case rpcError(code: Int32, text: String)
    /// The account's session is gone: the request was never sent and never will be.
    case sessionClosed
    /// A request hook of a plugin cancelled the request.
    case cancelledByHook
}

/// The layer of the generated `Api` types, which is the layer of every TL value this surface
/// reads or returns.
public var ayuPluginApiLayer: Int32 {
    return Int32(Serialization().currentLayer())
}

private let ayuPluginRefusedAccountFunctions: Set<String> = [
    "account.deleteAccount",
    "account.resetAuthorization",
    "account.resetPassword",
    "account.updatePasswordSettings",
]

private let ayuPluginWrapperFunctions: Set<String> = [
    "invokeAfterMsg",
    "invokeAfterMsgs",
    "initConnection",
    "invokeWithLayer",
    "invokeWithoutUpdates",
    "invokeWithMessagesRange",
    "invokeWithTakeout",
    "invokeWithBusinessConnection",
    "invokeWithGooglePlayIntegrity",
    "invokeWithApnsSecret",
    "invokeWithReCaptcha",
]

/// Whether a plugin may never send `name`: everything that changes the authorization of the
/// account, and every wrapper whose inner query cannot be inspected. Decided by name, so a
/// function added to `auth.*` by a later layer is refused without a table update.
func ayuPluginRefusesFunction(named name: String) -> Bool {
    return name.hasPrefix("auth.") || name.hasPrefix("invokeWith") || ayuPluginRefusedAccountFunctions.contains(name) || ayuPluginWrapperFunctions.contains(name)
}

/// The little-endian constructor id at the start of a boxed TL value, nil when `data` cannot be one.
func ayuPluginConstructorId(_ data: Data) -> Int32? {
    guard data.count >= 4, data.count % 4 == 0 else {
        return nil
    }
    return data.withUnsafeBytes { Int32(littleEndian: $0.loadUnaligned(as: Int32.self)) }
}

/// The function `data` starts with, when a plugin may send it.
func ayuPluginSendableFunction(_ data: Data) throws -> RawFunctionInfo {
    guard let constructorId = ayuPluginConstructorId(data), let info = Api.rawFunction(constructorId: constructorId) else {
        throw AyuPluginCoreError.invalidArguments("request is not a function of layer \(ayuPluginApiLayer)")
    }
    if ayuPluginRefusesFunction(named: info.name) {
        throw AyuPluginCoreError.unsupported("telegram.request does not send \(info.name)")
    }
    return info
}

/// Sends a serialized API function through the account's main session, like `Network.request`,
/// and reports the raw response. The request passes the request hooks of
/// `AyuPluginHookedRequestService` like any other.
///
/// - The function must be one of this layer and not one that changes the account's
///   authorization (`invalidArguments` / `unsupported` otherwise). Its arguments are not decoded.
/// - Ghost mode applies by function name with the global setting (per-chat exclusions need the
///   arguments): a suppressed function completes with `400 AYU_GHOST_DROPPED`, as it fails for
///   the app's own callers.
/// - A response of type `Updates` is handed to the account's state manager before `completion`
///   runs, which is what every caller of `Network.request` does by hand. Other per-function
///   handling (the pts of `messages.affectedMessages`, ...) is not reproduced.
/// - `failOnServerErrors` ends the request on a flood wait or a server error instead of retrying.
///
/// `completion` runs once, on an arbitrary queue, unless the returned disposable is disposed first.
public func ayuPluginSendRawRequest(account: Account, function: Data, failOnServerErrors: Bool, completion: @escaping (AyuPluginRawRequestResult) -> Void) throws -> Disposable {
    let info = try ayuPluginSendableFunction(function)
    let network = account.network
    let stateManager: AccountStateManager? = account.stateManager
    if ayuGhostShouldDrop(info.description) {
        completion(.rpcError(code: 400, text: "AYU_GHOST_DROPPED"))
        return EmptyDisposable
    }

    // What was sent: a request hook may replace the function.
    let sent = Atomic<RawFunctionInfo>(value: info)
    // The closures below hold the network and the state manager until the request ends, as
    // the engine's request does; none of them outlives it.
    let request = NetworkEngineRequest(
        payload: function,
        metadata: WrappedRequestMetadata(metadata: WrappedFunctionDescription(info.description), tag: nil),
        shortMetadata: WrappedRequestShortMetadata(shortMetadata: WrappedShortFunctionDescription(info.description)),
        parse: { response in
            return BoxedMessage(response)
        },
        options: NetworkEngineRequestOptions(),
        shouldContinueAfterError: networkRequestErrorPolicy(automaticFloodWait: !failOnServerErrors, onFloodWaitError: nil, failOnServerErrors: failOnServerErrors),
        dependsOn: nil,
        acknowledged: nil,
        progress: nil,
        completed: { result in
            switch result {
            case let .success(response):
                if let data = (response.result as? BoxedMessage)?.body as? Data {
                    let sent = sent.with { $0 }
                    ayuGhostRequestSucceeded(sent.description, network: network)
                    if sent.resultTypeName == "Updates", let updates = Api.parse(Buffer(data: data)) as? Api.Updates {
                        stateManager?.addUpdates(updates)
                    }
                    completion(.response(data))
                } else {
                    completion(.rpcError(code: 500, text: "TL_VERIFICATION_ERROR"))
                }
            case let .failure(failure):
                completion(.rpcError(code: failure.error.errorCode, text: failure.error.errorDescription ?? ""))
            }
        }
    )
    let events = AyuPluginRawRequestEvents(cancelledByHook: {
        completion(.cancelledByHook)
    }, dropped: {
        completion(.sessionClosed)
    }, sent: { info in
        let _ = sent.swap(info)
    })
    let disposable: Disposable
    if let service = network.requestService as? AyuPluginHookedRequestService {
        disposable = service.add(request, plugin: events)
    } else {
        disposable = network.requestService.add(request)
    }
    if (disposable as AnyObject) === (EmptyDisposable as AnyObject) {
        completion(.sessionClosed)
    }
    return disposable
}
