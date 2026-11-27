import Foundation
import AyuPluginPython

/// Bounded hand-over of host-to-Python deliveries (callbacks, lifecycle events) to the
/// interpreter queue. Each plugin has a FIFO; plugins take turns; at most `inFlight` deliveries
/// are on the interpreter queue at a time, so installation, unload and settings calls always
/// find room there. Nothing here waits or polls: a delivery is offered when it arrives, when
/// an earlier one completes, and when the runtime reports room after a refusal.
///
/// Every delivery ends in exactly one completion: the interpreter's answer, `overflow`
/// when the plugin's queue had no room for it, or `cancelled` when the plugin was unloaded
/// or the delivery was revoked before it was sent.
final class AyuPluginDeliveryQueue: @unchecked Sendable {
    struct Limits: Sendable {
        /// Pending deliveries of one plugin that no host quota bounds: listeners, settings rows, awaited calls.
        var pendingPerPlugin = 1024
        /// Pending quota-backed deliveries of one plugin: 128 timers, 64 requests in flight, lifecycle events.
        var guaranteedPerPlugin = 256
        /// JSON bytes pending for one plugin, and for all plugins together.
        var pendingBytesPerPlugin = 8_388_608
        var pendingBytes = 25_165_824
        /// JSON bytes of one delivery: the SDK reads 6,000,000 characters.
        var itemBytes = 6_000_000
        /// A quota-backed delivery (or a substitute) this small is bounded by its count alone.
        var exemptBytes = 1024
        var inFlight = 16
        /// JSON bytes on the interpreter queue; one delivery of any admitted size may go alone.
        var inFlightBytes = 2_097_152
    }

    enum Entry: Sendable { case callback, event }
    typealias Completion = @Sendable (String?, Error?) -> Void
    /// Offers one delivery to the interpreter queue. A refusal is the completion called with
    /// `queueFullCode`, possibly before `Submit` returns.
    typealias Submit = @Sendable (Entry, _ json: String, _ owner: String, @escaping Completion) -> Void

    static let errorDomain = "AyuPluginPython"
    /// The runtime's "queue is full" code; also this queue's own overflow.
    static let queueFullCode = 4
    static let cancelledCode = 6
    /// The runtime's answer for a callback or event that was released while its delivery waited
    /// (a cancelled timer, a removed listener, an unloaded generation): nothing ran.
    static let expiredCode = 7
    static func overflow() -> NSError { NSError(domain: errorDomain, code: queueFullCode) }
    static func cancelled() -> NSError { NSError(domain: errorDomain, code: cancelledCode) }
    static func isCancelled(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == errorDomain && error.code == cancelledCode
    }
    static func isExpired(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == errorDomain && error.code == expiredCode
    }
    static func isQueueFull(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return false }
        return error.domain == errorDomain && error.code == queueFullCode
    }

    struct Counters: Sendable, Equatable {
        var completed = 0
        var substituted = 0
        var overflowed = 0
        var cancelled = 0
        var refusals = 0
    }

    private struct Item {
        let owner: String
        let entry: Entry
        let json: String
        let bytes: Int
        /// Zero for an exempt delivery.
        let countedBytes: Int
        let guaranteed: Bool
        let epoch: UInt64
        let isCurrent: @Sendable () -> Bool
        let started: (@Sendable () -> Void)?
        let completion: Completion
    }
    private struct Pending {
        var items: [Item] = []
        var ordinary = 0
        var guaranteed = 0
        var bytes = 0
    }

    private let limits: Limits
    private let submit: Submit
    private let lock = NSLock()
    private var pending: [String: Pending] = [:]
    /// Plugins with pending deliveries, in the order they are served.
    private var rotation: [String] = []
    private var epochs: [String: UInt64] = [:]
    private var pendingBytes = 0
    private var inFlight = 0
    private var inFlightBytes = 0
    /// The interpreter queue refused a delivery; wait for a completion or for `capacityAvailable`.
    private var stalled = false
    private var pumping = false
    private var totals = Counters()

    init(limits: Limits = Limits(), submit: @escaping Submit) {
        self.limits = limits
        self.submit = submit
    }

    var counters: Counters {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.totals
    }

    /// `guaranteed` deliveries are bounded by a quota their producer holds until `started` or
    /// `completion`, so they are refused only past `guaranteedPerPlugin`. `substitute` produces a
    /// small replacement that is queued when `json` does not fit the byte bounds. `started` runs
    /// each time the delivery is offered to the interpreter queue, before the offer.
    func enqueue(owner: String, entry: Entry, json: String, guaranteed: Bool = false, substitute: (@Sendable () -> String?)? = nil,
                 isCurrent: @escaping @Sendable () -> Bool = { true }, started: (@Sendable () -> Void)? = nil, completion: @escaping Completion) {
        self.lock.lock()
        var state = self.pending[owner] ?? Pending()
        var json = json
        var bytes = json.utf8.count
        var exempt = guaranteed && bytes <= self.limits.exemptBytes
        var admitted = bytes <= self.limits.itemBytes && (exempt || (state.bytes + bytes <= self.limits.pendingBytesPerPlugin && self.pendingBytes + bytes <= self.limits.pendingBytes))
        if !admitted, let replacement = substitute?(), replacement.utf8.count <= self.limits.exemptBytes {
            json = replacement; bytes = replacement.utf8.count; exempt = true; admitted = true
            self.totals.substituted += 1
        }
        guard admitted, guaranteed || exempt ? state.guaranteed < self.limits.guaranteedPerPlugin : state.ordinary < self.limits.pendingPerPlugin else {
            self.totals.overflowed += 1
            self.lock.unlock()
            completion(nil, Self.overflow())
            return
        }
        let item = Item(owner: owner, entry: entry, json: json, bytes: bytes, countedBytes: exempt ? 0 : bytes, guaranteed: guaranteed || exempt,
                        epoch: self.epochs[owner, default: 0], isCurrent: isCurrent, started: started, completion: completion)
        if state.items.isEmpty { self.rotation.append(owner) }
        state.items.append(item)
        if item.guaranteed { state.guaranteed += 1 } else { state.ordinary += 1 }
        state.bytes += item.countedBytes
        self.pendingBytes += item.countedBytes
        self.pending[owner] = state
        self.lock.unlock()
        self.pump()
    }

    /// Unload: pending deliveries of the plugin complete as cancelled; one already on the
    /// interpreter queue is answered by the interpreter.
    func cancel(owner: String) {
        self.lock.lock()
        self.epochs[owner, default: 0] += 1
        let dropped = self.pending.removeValue(forKey: owner)
        self.rotation.removeAll { $0 == owner }
        self.pendingBytes -= dropped?.bytes ?? 0
        self.totals.cancelled += dropped?.items.count ?? 0
        self.lock.unlock()
        for item in dropped?.items ?? [] { item.completion(nil, Self.cancelled()) }
    }

    /// The runtime has room again after refusing a delivery.
    func capacityAvailable() {
        self.lock.lock(); self.stalled = false; self.lock.unlock()
        self.pump()
    }

    private func pump() {
        self.lock.lock()
        guard !self.pumping else { self.lock.unlock(); return }
        self.pumping = true
        while !self.stalled, self.inFlight < self.limits.inFlight, let owner = self.rotation.first,
              var state = self.pending[owner], let item = state.items.first,
              self.inFlight == 0 || self.inFlightBytes + item.bytes <= self.limits.inFlightBytes {
            state.items.removeFirst()
            if item.guaranteed { state.guaranteed -= 1 } else { state.ordinary -= 1 }
            state.bytes -= item.countedBytes
            self.pendingBytes -= item.countedBytes
            self.rotation.removeFirst()
            if state.items.isEmpty { self.pending.removeValue(forKey: owner) } else { self.pending[owner] = state; self.rotation.append(owner) }
            guard item.isCurrent() else {
                self.totals.cancelled += 1
                self.lock.unlock()
                item.completion(nil, Self.cancelled())
                self.lock.lock()
                continue
            }
            self.inFlight += 1
            self.inFlightBytes += item.bytes
            self.lock.unlock()
            item.started?()
            self.submit(item.entry, item.json, item.owner) { [weak self] result, error in
                guard let self else { item.completion(result, error); return }
                self.finished(item, result, error)
            }
            self.lock.lock()
        }
        self.pumping = false
        self.lock.unlock()
    }

    private func finished(_ item: Item, _ result: String?, _ error: Error?) {
        self.lock.lock()
        self.inFlight -= 1
        self.inFlightBytes -= item.bytes
        guard Self.isQueueFull(error) else {
            self.stalled = false
            self.totals.completed += 1
            self.lock.unlock()
            item.completion(result, error)
            self.pump()
            return
        }
        // Refused, not run: it goes back to the head of its plugin's queue, and that plugin
        // keeps its turn, so order is unchanged.
        self.stalled = true
        self.totals.refusals += 1
        guard self.epochs[item.owner, default: 0] == item.epoch else {
            self.totals.cancelled += 1
            self.lock.unlock()
            item.completion(nil, Self.cancelled())
            return
        }
        var state = self.pending[item.owner] ?? Pending()
        state.items.insert(item, at: 0)
        if item.guaranteed { state.guaranteed += 1 } else { state.ordinary += 1 }
        state.bytes += item.countedBytes
        self.pendingBytes += item.countedBytes
        self.pending[item.owner] = state
        self.rotation.removeAll { $0 == item.owner }
        self.rotation.insert(item.owner, at: 0)
        self.lock.unlock()
    }
}

/// Encodes callbacks and lifecycle events for the SDK entry points and feeds them to the
/// interpreter through one `AyuPluginDeliveryQueue`. What each kind of delivery is promised is
/// written in `Python/protocol.md` ("Delivery queue").
final class AyuPluginRuntimeRelay: @unchecked Sendable {
    enum Problem: Sendable {
        /// The interpreter reported a failure of the callback or event.
        case handler
        /// A delivery was discarded because the plugin's queue was full.
        case overflow
    }
    /// `generation` is the SDK generation the delivery was addressed to, when it names one.
    typealias ErrorSink = @Sendable (_ owner: String, _ generation: String?, _ problem: Problem) -> Void

    private struct CallbackEvent: Encodable { let version = 1; let plugin_id: String; let callback_id: String; let arguments: [AyuBridgeValue] }
    private struct LifecycleEvent: Encodable { let version = 1; let plugin_id: String; let generation: String; let name = "app"; let arguments: [String] }

    private let lock = NSLock()
    private var runtime: APBPythonRuntime?
    private var errorSink: ErrorSink?
    private var deliveries: AyuPluginDeliveryQueue?
    private let limits: AyuPluginDeliveryQueue.Limits

    init(limits: AyuPluginDeliveryQueue.Limits = AyuPluginDeliveryQueue.Limits()) { self.limits = limits }

    func attach(_ runtime: APBPythonRuntime, errorSink: @escaping ErrorSink) {
        let deliveries = AyuPluginDeliveryQueue(limits: self.limits) { [weak runtime] entry, json, owner, completion in
            guard let runtime else { completion(nil, NSError(domain: AyuPluginDeliveryQueue.errorDomain, code: 2)); return }
            switch entry {
            case .callback: runtime.invokeCallback(json: json, pluginID: owner, completion: completion)
            case .event: runtime.emitEvent(json: json, pluginID: owner, completion: completion)
            }
        }
        runtime.setQueueCapacityHandler { [weak deliveries] in deliveries?.capacityAvailable() }
        self.lock.lock(); self.runtime = runtime; self.errorSink = errorSink; self.deliveries = deliveries; self.lock.unlock()
    }

    var counters: AyuPluginDeliveryQueue.Counters { self.queue()?.counters ?? AyuPluginDeliveryQueue.Counters() }

    private func queue() -> AyuPluginDeliveryQueue? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.deliveries
    }

    /// A cancelled or expired delivery ran nothing and is the expected end of a race with the
    /// plugin's own cancel or unload; only a failure of the handler flags the plugin.
    private func report(_ owner: String, _ generation: String?, _ error: Error?) {
        guard error != nil, !AyuPluginDeliveryQueue.isCancelled(error), !AyuPluginDeliveryQueue.isExpired(error) else { return }
        self.lock.lock(); let sink = self.errorSink; self.lock.unlock()
        sink?(owner, generation, AyuPluginDeliveryQueue.isQueueFull(error) ? .overflow : .handler)
    }

    private static func json<Value: Encodable>(_ value: Value) -> String? {
        // Base64 contains `/`; escaping it would make a TL value's size depend on its bytes.
        let encoder = JSONEncoder(); encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Callback arguments keep each number's type in its spelling.
    private static func json(_ event: CallbackEvent) -> String? {
        let value: AyuBridgeValue = .object(["version": .integer(Int64(event.version)), "plugin_id": .string(event.plugin_id),
                                             "callback_id": .string(event.callback_id), "arguments": .array(event.arguments)])
        return (try? AyuBridgeJSON.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Callback ids are `<SDK generation>:<number>`.
    private static func generation(of callback: String) -> String? { callback.split(separator: ":").first.map(String.init) }

    /// A callback nobody waits for (a settings row): dropped, with the plugin flagged, on overflow.
    func deliver(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue]) {
        self.invoke(owner, callback, arguments) { _, _ in }
    }

    /// A callback from the native host, with the quota and substitute the host attached to it.
    func deliver(_ delivery: AyuPluginNativeHost.Delivery) {
        let owner = delivery.owner, callback = delivery.callbackID, generation = Self.generation(of: callback)
        guard !delivery.dropped else {
            self.report(owner, generation, AyuPluginDeliveryQueue.overflow())
            delivery.completion()
            return
        }
        guard let queue = self.queue(), let json = Self.json(CallbackEvent(plugin_id: owner, callback_id: callback, arguments: delivery.arguments)) else {
            delivery.completion(); return
        }
        let substitute = delivery.substitute.map { arguments in
            { @Sendable in Self.json(CallbackEvent(plugin_id: owner, callback_id: callback, arguments: arguments)) }
        }
        queue.enqueue(owner: owner, entry: .callback, json: json, guaranteed: delivery.guaranteed, substitute: substitute, isCurrent: delivery.isCurrent, started: delivery.started) { [weak self] _, error in
            self?.report(owner, generation, error)
            delivery.completion()
        }
    }

    /// A callback whose result is awaited (hook, menu condition, sub-page): on overflow the
    /// completion receives the queue-full error at once.
    func invoke(_ owner: String, _ callback: String, _ arguments: [AyuBridgeValue], completion: @escaping @Sendable (String?, Error?) -> Void) {
        guard let queue = self.queue(), let json = Self.json(CallbackEvent(plugin_id: owner, callback_id: callback, arguments: arguments)) else {
            completion(nil, NSError(domain: AyuPluginDeliveryQueue.errorDomain, code: 2)); return
        }
        queue.enqueue(owner: owner, entry: .callback, json: json) { [weak self] result, error in
            self?.report(owner, Self.generation(of: callback), error)
            completion(result, error)
        }
    }

    /// Lifecycle events are few, ordered and never coalesced.
    func event(_ owner: String, generation: String, name: String) {
        guard let queue = self.queue(), let json = Self.json(LifecycleEvent(plugin_id: owner, generation: generation, arguments: [name])) else { return }
        queue.enqueue(owner: owner, entry: .event, json: json, guaranteed: true) { [weak self] _, error in
            self?.report(owner, generation, error)
        }
    }

    /// Unload or a failed load: nothing queued for the plugin reaches the interpreter afterwards.
    func cancel(_ owner: String) { self.queue()?.cancel(owner: owner) }
}
