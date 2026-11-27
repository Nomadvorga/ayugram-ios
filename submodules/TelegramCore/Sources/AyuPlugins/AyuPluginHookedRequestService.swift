import Foundation
import MtProtoKit
import SwiftSignalKit
internal import TelegramApi

/// What a plugin's own request (`ayuPluginSendRawRequest`) is told and an app request is not.
struct AyuPluginRawRequestEvents {
    /// A request hook cancelled the request: it is never sent and never completes.
    let cancelledByHook: () -> Void
    /// The session is gone: the request is never sent and never completes.
    let dropped: () -> Void
    /// A request hook replaced the function by another one, which is what is sent.
    let sent: (RawFunctionInfo) -> Void
}

private final class AyuPluginHookedResponse {
    let raw: Data
    let parsed: Any

    init(raw: Data, parsed: Any) {
        self.raw = raw
        self.parsed = parsed
    }
}

/// The request hook point of an account: the request service of `Network`'s main session, so
/// it sees `Network.request`, `requestWithAdditionalInfo` and plugin requests alike. File part
/// transfers run on worker sessions (`Download`) and never pass here.
///
/// - While no plugin hooks anything a request costs one unfair lock (`ayuPluginHookState`).
/// - A hooked request is shown to the plugins before it is sent, and its response before it is
///   delivered. Both waits are asynchronous: `add` returns at once and the engine's queues are
///   never held.
/// - Requests that carry a dependency tag are sent in the order they were added: while one of
///   them waits for a plugin, later tagged ones wait behind it (`invokeAfterMsg` orders a chat's
///   messages by the order of `add`).
/// - A function the plugin surface refuses to send (`ayuPluginRefusesFunction`) is never shown.
/// - An app request can be replaced only by a function with the same result type: its caller
///   parses the response with the deserializer of what it asked for. A plugin's own request can
///   be replaced by any function a plugin may send. A replacement that is not accepted is
///   ignored and the original is sent.
/// - A cancelled app request is never answered, which is what Android's `sendRequest` does.
final class AyuPluginHookedRequestService: NetworkEngineRequestService {
    private let service: NetworkEngineRequestService
    weak var network: Network?
    private let gate = ayuPluginMakeHookGate()

    init(_ service: NetworkEngineRequestService) {
        self.service = service
    }

    func add(_ request: NetworkEngineRequest) -> Disposable {
        return self.add(request, plugin: nil)
    }

    func add(_ request: NetworkEngineRequest, plugin: AyuPluginRawRequestEvents?) -> Disposable {
        let state = ayuPluginHookState()
        if state.interceptor == nil && !state.holdsTraffic {
            return self.service.add(request)
        }
        var hook: Hook?
        if let interceptor = state.interceptor, let constructorId = ayuPluginConstructorId(request.payload), interceptor.requests.contains(constructorId), let network = self.network, interceptor.servesNetwork(network), let info = Api.rawFunction(constructorId: constructorId), !ayuPluginRefusesFunction(named: info.name) {
            hook = Hook(interceptor: interceptor, network: network, function: info)
        }
        let ordered = request.metadata.tag != nil
        if hook == nil && !(ordered && self.gate.isBusy) {
            return self.service.add(request)
        }

        let service = self.service
        let cancelled = Atomic<Bool>(value: false)
        let disposable = MetaDisposable()
        let send: (NetworkEngineRequest) -> Void = { request in
            if cancelled.with({ $0 }) {
                return
            }
            let requestDisposable = service.add(request)
            if (requestDisposable as AnyObject) === (EmptyDisposable as AnyObject) {
                plugin?.dropped()
            } else {
                disposable.set(requestDisposable)
            }
        }
        let step: AyuPluginOrderedGate.Step = { done in
            guard let hook else {
                send(request)
                done()
                return
            }
            hook.interceptor.interceptRequest(hook.network, request.payload, { replacement in
                if let replacement {
                    if let hooked = AyuPluginHookedRequestService.hookedRequest(request, replacement: replacement, hook: hook, plugin: plugin, cancelled: cancelled) {
                        send(hooked)
                    }
                } else {
                    plugin?.cancelledByHook()
                }
                done()
            })
        }
        if ordered {
            self.gate.add(step)
        } else {
            step({})
        }
        return ActionDisposable {
            let _ = cancelled.swap(true)
            disposable.dispose()
        }
    }

    private struct Hook {
        let interceptor: AyuPluginHookInterceptor
        let network: Network
        let function: RawFunctionInfo
    }

    /// The function a hooked request is sent as: `replacement` when it is one the sender can
    /// take the response of, else the original.
    private static func acceptedReplacement(_ replacement: Data, of request: NetworkEngineRequest, function: RawFunctionInfo, fromPlugin: Bool) -> RawFunctionInfo? {
        guard replacement != request.payload, let info = try? ayuPluginSendableFunction(replacement) else {
            return nil
        }
        if info.constructorId == function.constructorId || fromPlugin {
            return info
        }
        if let resultTypeName = info.resultTypeName, resultTypeName == function.resultTypeName {
            return info
        }
        return nil
    }

    /// Nil when the request ended here (ghost mode suppresses the function it was replaced by).
    private static func hookedRequest(_ request: NetworkEngineRequest, replacement: Data, hook: Hook, plugin: AyuPluginRawRequestEvents?, cancelled: Atomic<Bool>) -> NetworkEngineRequest? {
        var payload = request.payload
        var metadata = request.metadata
        var shortMetadata = request.shortMetadata
        var sentConstructorId = hook.function.constructorId
        if let info = self.acceptedReplacement(replacement, of: request, function: hook.function, fromPlugin: plugin != nil) {
            payload = replacement
            if info.constructorId != hook.function.constructorId {
                if ayuGhostShouldDrop(info.description) {
                    request.completed(.failure(NetworkEngineRequestFailure(error: MTRpcError(errorCode: 400, errorDescription: "AYU_GHOST_DROPPED"), info: NetworkEngineResponseInfo(timestamp: 0.0, networkType: 0, duration: 0.0))))
                    return nil
                }
                sentConstructorId = info.constructorId
                metadata = WrappedRequestMetadata(metadata: WrappedFunctionDescription(info.description), tag: request.metadata.tag)
                shortMetadata = WrappedRequestShortMetadata(shortMetadata: WrappedShortFunctionDescription(info.description))
                plugin?.sent(info)
            }
        }
        let network = hook.network
        return NetworkEngineRequest(
            payload: payload,
            metadata: metadata,
            shortMetadata: shortMetadata,
            parse: { data in
                // The sender's own parser still decides whether the server's answer is valid, so
                // the engine handles an unreadable one as it always does.
                guard let parsed = request.parse(data) else {
                    return nil
                }
                return AyuPluginHookedResponse(raw: data, parsed: parsed)
            },
            options: request.options,
            shouldContinueAfterError: { context in
                return request.shouldContinueAfterError(context)
            },
            dependsOn: request.dependsOn,
            acknowledged: request.acknowledged,
            progress: request.progress,
            completed: { result in
                switch result {
                case let .success(response):
                    guard let hooked = response.result as? AyuPluginHookedResponse else {
                        request.completed(result)
                        return
                    }
                    ayuPluginInterceptResponse(network: network, constructorId: sentConstructorId, response: hooked.raw, error: nil, completion: { data, error in
                        if cancelled.with({ $0 }) {
                            return
                        }
                        if let error {
                            request.completed(.failure(NetworkEngineRequestFailure(error: error, info: response.info)))
                        } else if let data, data != hooked.raw, let parsed = request.parse(data) {
                            request.completed(.success(NetworkEngineResponse(result: parsed, info: response.info)))
                        } else {
                            request.completed(.success(NetworkEngineResponse(result: hooked.parsed, info: response.info)))
                        }
                    })
                case let .failure(failure):
                    ayuPluginInterceptResponse(network: network, constructorId: sentConstructorId, response: nil, error: failure.error, completion: { data, error in
                        if cancelled.with({ $0 }) {
                            return
                        }
                        if let data, let parsed = request.parse(data) {
                            request.completed(.success(NetworkEngineResponse(result: parsed, info: failure.info)))
                        } else {
                            request.completed(.failure(NetworkEngineRequestFailure(error: error ?? failure.error, info: failure.info)))
                        }
                    })
                }
            }
        )
    }
}
