import Foundation
import ImageIO
import UIKit

/// Native JSON host. `dispatch` is synchronous for a Python C extension but is worker-only.
/// Never call it from main or have main wait for the Python/host worker.
public final class AyuPluginNativeHost: @unchecked Sendable {
    public static let settingsDidChange = Notification.Name("AyuPluginNativeSettingsDidChange")
    public typealias CallbackSink = @Sendable (String, String, [AyuBridgeValue]) -> Void
    public typealias OwnerResolver = @Sendable () -> String?
    private struct Remote {
        let owner: String
        let className: String
        let kind: String
        var fields: [String: AyuBridgeValue]
        var arrayCost: ArrayCost? = nil
    }
    private struct ArrayCost {
        let elements: Int
        let encodedBytes: Int
    }
    private struct Session: @unchecked Sendable {
        let generation: UUID
        var backgroundOutlineProviderHandle: String? = nil
        var active = false
        var sdkGeneration: String?
        var timers: [String: DispatchWorkItem] = [:]
        var timerCallbacks: [String: String] = [:]
        var state: [String: AyuBridgeValue] = [:]
        var callbackIDs: Set<String> = []
        var persistentCallbackIDs: Set<String> = []
    }
    private let worker = DispatchQueue(label: "AyuPluginBridge.native")
    private let workerKey = DispatchSpecificKey<Bool>()
    private let delivery = DispatchQueue(label: "AyuPluginBridge.callbacks")
    private let provider: AyuPluginHostProvider
    private let classRegistry: AyuBridgeClassRegistry
    private let defaults: UserDefaults
    private let limits: AyuPluginBridgeLimits
    private let callback: CallbackSink
    private let trustedOwner: OwnerResolver
    private let callbackGate = AyuBridgeCallbackGate()
    private var sessions: [String: Session] = [:]
    private var objects: [String: Remote] = [:]
    private var commands: UInt64 = 0
    private var queueNanoseconds: UInt64 = 0
    private lazy var ui: AyuBridgeUI = AyuBridgeUI(limit: self.limits.pendingUICommands, byteLimit: self.limits.pendingUIBytes, callback: { [weak self] owner, generation, callbackID, args in
        self?.enqueueCallback(owner: owner, generation: generation, callbackID: callbackID, arguments: args)
    })

    public init(defaults: UserDefaults, provider: AyuPluginHostProvider = AyuUnsupportedPluginHostProvider(), classRegistry: AyuBridgeClassRegistry = .standard, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits(), trustedOwner: @escaping OwnerResolver, callback: @escaping CallbackSink) {
        self.classRegistry = classRegistry
        self.defaults = defaults; self.provider = provider; self.limits = limits
        self.trustedOwner = trustedOwner; self.callback = callback
        self.worker.setSpecific(key: self.workerKey, value: true)
    }

    /// The owner comes from embedding/TLS, never from a plugin-supplied JSON field.
    public func dispatch(_ request: String) -> String {
        guard let owner = self.trustedOwner() else { return self.encode(id: .null, error: AyuBridgeFailure("unauthorized", "No trusted plugin context")) }
        return self.dispatch(request, owner: owner)
    }

    public func dispatch(_ request: String, owner: String) -> String {
        guard DispatchQueue.getSpecific(key: self.workerKey) == nil else { return self.encode(id: .null, error: AyuBridgeFailure("wrong_queue", "Recursive bridge dispatch is forbidden")) }
        guard !Thread.isMainThread else { return self.encode(id: .null, error: AyuBridgeFailure("wrong_thread", "Bridge dispatch cannot run on main")) }
        guard request.utf8.count <= self.limits.requestBytes else { return self.encode(id: .null, error: AyuBridgeFailure("resource_limit", "Request is too large")) }
        let received = DispatchTime.now().uptimeNanoseconds
        return self.worker.sync {
            self.queueNanoseconds &+= DispatchTime.now().uptimeNanoseconds - received
            var id = AyuBridgeValue.null
            do {
                let data = Data(request.utf8)
                try AyuBridgeJSONValidation.validate(data)
                let envelope = try JSONDecoder().decode(AyuBridgeValue.self, from: data)
                guard let fields = envelope.object, Set(fields.keys) == Set(["version", "id", "plugin_id", "operation", "arguments"]) else { throw AyuBridgeFailure("invalid_request", "Unexpected envelope fields") }
                let value = try JSONDecoder().decode(AyuBridgeRequest.self, from: data)
                id = value.id
                guard value.version == 1 else { throw AyuBridgeFailure("protocol_version", "Only protocol version 1 is supported") }
                guard let requestID = value.id.string, !requestID.isEmpty, requestID.utf8.count <= 128, requestID.utf8.allSatisfy({ (48...57).contains($0) }) else { throw AyuBridgeFailure("invalid_request", "Request id must be a decimal string") }
                let bootstrap = value.operation == "runtime.capabilities" && value.pluginID == "$runtime"
                guard self.validID(owner), bootstrap || value.pluginID == owner else { throw AyuBridgeFailure("owner_mismatch", "Request owner does not match runtime context") }
                self.commands &+= 1
                let result = try self.perform(owner: owner, operation: value.operation, arguments: value.arguments)
                return self.encode(id: id, result: result)
            } catch let error as AyuBridgeFailure {
                return self.encode(id: id, error: error)
            } catch {
                return self.encode(id: id, error: AyuBridgeFailure("invalid_request", "Malformed request or arguments"))
            }
        }
    }

    /// App integration supplies a container; no global/key-window discovery or private APIs.
    /// Completion runs off main. Passing nil detaches the visual surface only.
    @MainActor public func setMountContainer(_ container: UIView?, pluginID: String, completion: @escaping @Sendable () -> Void = {}) {
        precondition(Thread.isMainThread)
        // Capture UIView only inside a sendable box; it is used exclusively on main.
        let box = AyuBridgeContainerBox(container)
        self.worker.async {
            guard self.sessions[pluginID] != nil else { self.delivery.async(execute: completion); return }
            DispatchQueue.main.async {
                self.ui.setContainer(owner: pluginID, container: box.value)
                self.delivery.async(execute: completion)
            }
        }
    }

    /// Embedding calls this on interpreter unload/error even if plugin cleanup raises.
    public func detach(pluginID: String, completion: @escaping @Sendable () -> Void = {}) {
        self.worker.async { self.cleanup(owner: pluginID); self.delivery.async(execute: completion) }
    }

    private func perform(owner: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        if operation == "runtime.capabilities" { return self.capabilities() }
        if operation == "plugin.authorize" {
            guard self.sessions[owner] == nil else { throw AyuBridgeFailure("invalid_state", "Plugin is already authorized") }
            guard self.sessions.count < self.limits.plugins else { throw AyuBridgeFailure("resource_limit", "Too many plugins") }
            if let requirements = arguments["operations"]?.array {
                let known = Set(self.operations + self.provider.capabilities)
                guard requirements.allSatisfy({ $0.string.map(known.contains) ?? false }) else { throw AyuBridgeFailure("unsupported_api", "Plugin requires an unsupported operation") }
            }
            if let requirements = arguments["requirements"]?.array, !requirements.isEmpty {
                throw AyuBridgeFailure("unsupported_api", "External Python dependencies are not available in this host")
            }
            if let classes = arguments["classes"]?.array {
                guard classes.allSatisfy({ $0.string.map(self.knownClass) ?? false }) else { throw AyuBridgeFailure("unsupported_api", "Plugin requires an unsupported class") }
            }
            if self.provider.capabilities.contains("plugin.authorize") {
                guard try self.provider.call(pluginID: owner, operation: "plugin.authorize", arguments: arguments) == .bool(true) else {
                    throw AyuBridgeFailure("unauthorized", "Plugin policy rejected authorization")
                }
            } else if let metadata = arguments["metadata"]?.object,
                      metadata.keys.contains(where: { ["__sdk_version__", "__app_version__", "__min_version__", "sdk_version", "app_version", "min_version"].contains($0) }) {
                throw AyuBridgeFailure("unsupported_api", "Version constraints require an application policy provider")
            }
            let generation = UUID()
            self.sessions[owner] = Session(generation: generation)
            DispatchQueue.main.sync { self.ui.install(owner: owner, generation: generation, container: nil) }
            return .bool(true)
        }
        guard let session = self.sessions[owner] else { throw AyuBridgeFailure("unauthorized", "Authorize plugin before using host APIs") }
        try self.validateReferences(.object(arguments), owner: owner)
        switch operation {
        case "plugin.activate":
            guard !session.active else { throw AyuBridgeFailure("invalid_state", "Plugin is already active") }
            let sdkGeneration = try self.text(arguments, "generation")
            guard sdkGeneration.utf8.count <= 128 else { throw AyuBridgeFailure("invalid_arguments", "Invalid generation") }
            self.sessions[owner]?.sdkGeneration = sdkGeneration
            self.sessions[owner]?.active = true
            self.callbackGate.activate(owner: owner, generation: session.generation)
            return .null
        case "plugin.deactivate":
            if let generation = session.sdkGeneration, arguments["generation"]?.string != generation { throw AyuBridgeFailure("callback_expired", "Stale plugin generation") }
            self.cleanup(owner: owner); return .null
        case "host.metrics": return .object(["commands": .number(Double(self.commands)), "queue_nanoseconds": .number(Double(self.queueNanoseconds)), "objects": .number(Double(self.objects.values.filter { $0.owner == owner }.count))])
        case "state.get": return session.state[try self.text(arguments, "key")] ?? arguments["default"] ?? .null
        case "state.set":
            let key = try self.text(arguments, "key")
            var state = session.state; state[key] = arguments["value"] ?? .null
            guard try JSONEncoder().encode(state).count <= self.limits.settingsBytesPerPlugin else { throw AyuBridgeFailure("resource_limit", "Transient state quota exceeded") }
            self.sessions[owner]?.state = state; return .null
        case "log.write":
            let level = try self.text(arguments, "level")
            guard ["debug", "info", "warning", "error", "critical"].contains(level.lowercased()), let message = arguments["message"]?.string, message.utf8.count <= 4096 else { throw AyuBridgeFailure("invalid_arguments", "Invalid log record") }
            if self.provider.capabilities.contains(operation) { return try self.provider.call(pluginID: owner, operation: operation, arguments: arguments) }
            NSLog("AyuPluginBridge [%@] %@ (plugin log payload redacted)", owner, level); return .null
        case "settings.get":
            let key = try self.text(arguments, "key")
            return try self.settings(owner)[key] ?? arguments["default"] ?? .null
        case "settings.all": return .object(try self.settings(owner))
        case "settings.replace":
            guard Set(arguments.keys) == ["values", "reload_settings"],
                  let values = arguments["values"]?.object,
                  let reload = arguments["reload_settings"], case .bool = reload else { throw AyuBridgeFailure("invalid_arguments", "Invalid settings replacement") }
            guard values.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && !$0.hasPrefix("$") }) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid setting key")
            }
            try self.validatePersistentValue(.object(values))
            let data = try JSONEncoder().encode(values)
            guard data.count <= self.limits.settingsBytesPerPlugin else { throw AyuBridgeFailure("resource_limit", "Plugin settings quota exceeded") }
            // Validate and encode the entire namespace before a single mutation.
            self.defaults.set(data, forKey: self.settingsKey(owner))
            if reload == .bool(true) { self.notifySettingsChanged(owner: owner) }
            return .null
        case "settings.set":
            let key = try self.text(arguments, "key")
            guard key.utf8.count <= 256 else { throw AyuBridgeFailure("resource_limit", "Setting key is too long") }
            let setting = arguments["value"] ?? .null
            try self.validatePersistentValue(setting)
            var values = try self.settings(owner)
            values[key] = setting
            let data = try JSONEncoder().encode(values)
            guard data.count <= self.limits.settingsBytesPerPlugin else { throw AyuBridgeFailure("resource_limit", "Plugin settings quota exceeded") }
            self.defaults.set(data, forKey: self.settingsKey(owner))
            if arguments["reload_settings"] == .bool(true) { self.notifySettingsChanged(owner: owner) }
            return .null
        case "java.class":
            let name = try self.className(arguments)
            guard self.knownClass(name) else { throw AyuBridgeFailure.unsupported(name) }
            return try self.store(owner: owner, className: name, kind: "class")
        case "java.construct": return try self.construct(owner: owner, arguments: arguments, generation: session.generation)
        case "java.member":
            let remote = try self.targetRemote(arguments, owner: owner)
            let name = try self.text(arguments, "name")
            if remote.kind == "class" {
                let nested = remote.className + "$" + name
                if self.knownClass(nested) { return .object(["kind": .string("class"), "class_name": .string(nested)]) }
                if remote.className == "android.view.ViewOutlineProvider", name == "BACKGROUND" {
                    let reference = try self.backgroundOutlineProvider(owner: owner)
                    let member: AyuBridgeValue = .object(["kind": .string("field"), "value": reference])
                    try self.validateAdapterResponse(member)
                    return member
                }
                if let constant = self.constants(for: remote.className)[name] { return .object(["kind": .string("field"), "value": constant]) }
                if self.classRegistry.adapters[remote.className]?.staticFields[name] != nil {
                    let snapshot = self.objects
                    do {
                        let value = try self.getField(owner: owner, arguments: arguments)
                        let member: AyuBridgeValue = .object(["kind": .string("field"), "value": value])
                        try self.validateAdapterResponse(member)
                        return member
                    } catch { self.objects = snapshot; throw error }
                }
            }
            if remote.kind == "layout", self.isReadableLayoutField(name, className: remote.className) {
                return .object(["kind": .string("field"), "value": remote.fields[name] ?? .integer(0)])
            }
            if remote.kind == "adapter", self.classRegistry.adapters[remote.className]?.readableFields.contains(name) == true {
                return .object(["kind": .string("field"), "value": remote.fields[name] ?? .null])
            }
            let methods = remote.kind == "class" ? Self.reflectionMethods.union(self.staticMethods(for: remote.className)) : remote.kind == "method" ? Set(["getName"]) : self.methods(for: remote.className)
            guard methods.contains(name) else { throw AyuBridgeFailure.unsupported(remote.className + "." + name) }
            return .object(["kind": .string("method")])
        case "java.invoke": return try self.invoke(owner: owner, arguments: arguments, generation: session.generation)
        case "java.get_field", "java.get_private_field": return try self.getField(owner: owner, arguments: arguments)
        case "java.set_field", "java.set_private_field":
            let target = try self.target(arguments); let remote = try self.remote(target, owner: owner)
            let name = try self.text(arguments, "name")
            if remote.kind == "adapter", self.classRegistry.adapters[remote.className]?.writableFields.contains(name) == true {
                var fields = remote.fields; fields[name] = arguments["value"] ?? .null
                try self.validateAdapterState(fields, className: remote.className, owner: owner, replacing: target)
                self.objects[target]?.fields = fields; return .null
            }
            guard remote.kind == "layout", self.isReadableLayoutField(name, className: remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + "." + name)
            }
            let number = try self.number(arguments["value"] ?? .null)
            if name == "weight" {
                guard number.isFinite, (0...100_000).contains(number) else { throw AyuBridgeFailure("invalid_arguments", "Invalid LinearLayout weight") }
            } else {
                guard number >= 0 || ((name == "width" || name == "height") && (number == -1 || number == -2)) else { throw AyuBridgeFailure("invalid_arguments", "Invalid layout dimension") }
            }
            let snapshot = self.objects
            self.objects[target]?.fields[name] = .number(number)
            do { try self.propagateLayoutParams(owner: owner, generation: session.generation, layoutHandle: target) }
            catch { self.objects = snapshot; throw error }
            return .null
        case "java.release":
            let target = try self.target(arguments); let remote = try self.remote(target, owner: owner)
            guard !self.objects.values.contains(where: { $0.owner == owner && $0.fields["parent"]?.string == target }) else { throw AyuBridgeFailure("invalid_state", "Remove children before releasing their parent") }
            guard !self.objects.values.contains(where: { $0.owner == owner && $0.kind == "view" && $0.fields["context_handle"]?.string == target }) else {
                throw AyuBridgeFailure("invalid_state", "Context is retained by a live view")
            }
            guard !self.objects.values.contains(where: { $0.owner == owner && $0.kind == "view" && $0.fields["resources_handle"]?.string == target }) else {
                throw AyuBridgeFailure("invalid_state", "Resources are retained by a live view")
            }
            guard !self.objects.values.contains(where: { $0.owner == owner && $0.kind == "view" && $0.fields["background_drawable"]?.string == target }) else {
                throw AyuBridgeFailure("invalid_state", "Drawable is retained by a live view background")
            }
            guard !self.objects.values.contains(where: { $0.owner == owner && $0.fields["text_watchers"]?.array?.contains(.string(target)) == true }) else {
                throw AyuBridgeFailure("invalid_state", "Remove text watcher before releasing its listener")
            }
            if remote.kind == "view" {
                if let animatorHandle = remote.fields["animator_handle"]?.string,
                   self.objects[animatorHandle]?.owner == owner,
                   self.objects[animatorHandle]?.kind == "animator" {
                    self.objects.removeValue(forKey: animatorHandle)
                }
                if let parent = remote.fields["parent"]?.string, parent != "$mount",
                   self.objects[parent]?.owner == owner {
                    var siblings = self.objects[parent]?.fields["children"]?.array ?? []
                    siblings.removeAll(where: { $0 == .string(target) })
                    self.objects[parent]?.fields["children"] = siblings.isEmpty ? nil : .array(siblings)
                }
                DispatchQueue.main.sync { self.ui.release(owner: owner, handle: target) }
            } else if remote.kind == "animator", let viewHandle = remote.fields["view"]?.string {
                DispatchQueue.main.sync { self.ui.cancelAnimations(owner: owner, handle: viewHandle) }
                if self.objects[viewHandle]?.fields["animator_handle"]?.string == target {
                    self.objects[viewHandle]?.fields.removeValue(forKey: "animator_handle")
                }
            }
            if remote.kind == "proxy" {
                let ids = remote.fields.values.compactMap { $0["$callback"].string }
                self.sessions[owner]?.persistentCallbackIDs.subtract(ids)
                for id in ids where self.sessions[owner]?.timerCallbacks.values.contains(id) != true {
                    self.sessions[owner]?.callbackIDs.remove(id)
                }
            }
            self.objects.removeValue(forKey: target); return .null
        case "java.cast":
            let value = arguments["value"] ?? .null
            if value == .null { return .null }
            let target = try self.handle(value); let remote = try self.remote(target, owner: owner)
            let name = try self.className(arguments)
            let actualClass: String
            switch remote.kind {
            case "class": actualClass = "java.lang.Class"
            case "method": actualClass = "java.lang.reflect.Method"
            default: actualClass = remote.className
            }
            guard self.isAssignable(actualClass, to: name) || (name == "android.view.View" && remote.kind == "view") else {
                throw AyuBridgeFailure.unsupported("cast to " + name)
            }
            return self.reference(target, className: remote.className)
        case "java.array":
            let component = try self.text(arguments, "component")
            guard component != "void", !component.hasPrefix("["),
                  let arrayClass = Self.arrayClasses[component] ?? (self.knownClass(component) ? "[L" + component + ";" : nil),
                  let values = arguments["values"]?.array else {
                throw AyuBridgeFailure("invalid_arguments", "Array requires a supported declared component and bounded values")
            }
            guard values.count <= self.limits.arrayElementsPerPlugin else {
                throw AyuBridgeFailure("resource_limit", "Array element quota exceeded")
            }
            for value in values { try self.validateArrayValue(value, component: component, owner: owner) }
            return try self.store(owner: owner, className: arrayClass, kind: "array", fields: ["component": .string(component), "values": .array(values)])
        case "java.length":
            let remote = try self.targetRemote(arguments, owner: owner)
            if remote.kind == "adapter", remote.className == "java.util.ArrayList" {
                return try self.invoke(owner: owner, arguments: ["target": arguments["target"] ?? .null, "name": .string("size"), "args": .array([])], generation: session.generation)
            }
            guard remote.kind == "array", let values = remote.fields["values"]?.array else { throw AyuBridgeFailure.unsupported("length") }
            return .integer(Int64(values.count))
        case "java.get_item", "java.set_item":
            let handle = try self.target(arguments); let remote = try self.remote(handle, owner: owner)
            if remote.kind == "adapter", remote.className == "java.util.ArrayList" {
                let args = [arguments["index"] ?? .null] + (operation == "java.set_item" ? [arguments["value"] ?? .null] : [])
                let result = try self.invoke(owner: owner, arguments: ["target": arguments["target"] ?? .null, "name": .string(operation == "java.get_item" ? "get" : "set"), "args": .array(args)], generation: session.generation)
                return operation == "java.set_item" ? .null : result
            }
            guard remote.kind == "array", var values = remote.fields["values"]?.array, let index = arguments["index"]?.integer, index >= 0, index < Int64(values.count) else { throw AyuBridgeFailure("invalid_arguments", "Array index out of range") }
            if operation == "java.get_item" { return values[Int(index)] }
            let value = arguments["value"] ?? .null
            guard let component = remote.fields["component"]?.string else {
                throw AyuBridgeFailure("invalid_state", "Invalid owned array state")
            }
            try self.validateArrayValue(value, component: component, owner: owner)
            let cost = try self.replacingArrayElement(owner: owner, handle: handle,
                oldValue: values[Int(index)], with: value)
            values[Int(index)] = value
            var updated = remote
            updated.fields["values"] = .array(values)
            updated.arrayCost = cost
            self.objects[handle] = updated
            return .null
        case "java.proxy":
            guard let interfaces = arguments["interfaces"]?.array, interfaces.count == 1, let name = interfaces.first?.string, let required = Self.proxyInterfaces[name] else { throw AyuBridgeFailure.unsupported("proxy interface") }
            guard let callbacks = arguments["callbacks"]?.object, Set(callbacks.keys) == Set(required) else { throw AyuBridgeFailure("invalid_arguments", "Proxy requires all declared interface callbacks") }
            var callbackIDs: Set<String> = []
            for callback in callbacks.values { callbackIDs.insert(try self.callbackID(callback, owner: owner, method: "")) }
            let result = try self.store(owner: owner, className: name, kind: "proxy", fields: callbacks)
            self.sessions[owner]?.persistentCallbackIDs.formUnion(callbackIDs)
            return result
        case "scheduler.schedule":
            guard session.active else { throw AyuBridgeFailure("inactive_plugin", "Plugin is not active") }
            let queue = arguments["queue"]?.string ?? "pluginsQueue"
            guard Self.schedulerQueues.contains(queue) else { throw AyuBridgeFailure.unsupported("scheduler queue " + queue) }
            let callbackID = try self.callbackID(arguments["callback"] ?? .null, owner: owner, method: "run")
            let delay = try self.number(arguments["delay_ms"] ?? .number(0))
            guard delay >= 0 && delay <= 86_400_000, session.timers.count < self.limits.callbacksPerPlugin else { throw AyuBridgeFailure("resource_limit", "Scheduler limit exceeded") }
            let token = UUID().uuidString
            self.callbackGate.register(token: token, owner: owner)
            let item = DispatchWorkItem { [weak self] in
                guard let self, self.sessions[owner]?.generation == session.generation else { return }
                if queue == "main" {
                    DispatchQueue.main.async { self.enqueueCallback(owner: owner, generation: session.generation, callbackID: callbackID, arguments: [], token: token) }
                } else { self.enqueueCallback(owner: owner, generation: session.generation, callbackID: callbackID, arguments: [], token: token) }
            }
            self.sessions[owner]?.timers[token] = item
            self.sessions[owner]?.timerCallbacks[token] = callbackID
            self.worker.asyncAfter(deadline: .now() + delay / 1000, execute: item)
            return .string(token)
        case "scheduler.cancel":
            let token = try self.text(arguments, "token")
            guard let item = self.sessions[owner]?.timers.removeValue(forKey: token) else { throw AyuBridgeFailure("invalid_handle", "Unknown scheduled callback") }
            self.callbackGate.cancel(token: token, owner: owner)
            self.finishTimer(owner: owner, token: token)
            item.cancel(); return .null
        case "ui.mount":
            let target = try self.target(arguments); let remote = try self.remote(target, owner: owner)
            guard remote.kind == "view", remote.fields["parent"] == nil || remote.fields["parent"]?.string == "$mount" else { throw AyuBridgeFailure("invalid_state", "Mount requires an unparented view") }
            try DispatchQueue.main.sync { try self.ui.mount(owner: owner, handle: target) }
            self.objects[target]?.fields["parent"] = .string("$mount")
            return .null
        case "ui.transaction":
            guard let calls = arguments["commands"]?.array, calls.count <= self.limits.commandsPerTransaction else { throw AyuBridgeFailure("resource_limit", "UI transaction is too large") }
            // Validate all before applying anything. Only explicitly
            // batch-dispatchable methods may reach the UIKit command applier.
            let snapshot = self.objects
            var batch: [AyuBridgeUI.Command] = []
            do {
                for call in calls {
                    guard let args = call.object else { throw AyuBridgeFailure("invalid_arguments", "Invalid UI command") }
                    let method = args["method"]?.string ?? args["name"]?.string ?? ""
                    guard Self.transactionCommandMethods.contains(method) else {
                        throw AyuBridgeFailure.unsupported("UI transaction command " + method)
                    }
                    let command = try self.uiCommand(owner: owner, arguments: args, generation: session.generation)
                    self.track(command)
                    batch.append(command)
                }
                try self.ui.enqueue(batch)
            } catch { self.objects = snapshot; throw error }
            return .null
        case "ui.animate":
            var args = arguments; args["method"] = .string("animate"); args["args"] = .array([arguments["properties"] ?? .object([:])])
            try self.ui.enqueue([try self.uiCommand(owner: owner, arguments: args, generation: session.generation)]); return .null
        case "client.call", "hooks.register", "hooks.unregister", "menus.register", "menus.unregister", "ui.present":
            if operation == "ui.present", let kind = arguments["kind"]?.string, let config = arguments["config"]?.object {
                if kind == "alert", config["view"] != nil {
                    return try self.presentCustomDialog(owner: owner, config: config, generation: session.generation)
                }
                if kind == "bulletin", DispatchQueue.main.sync(execute: { self.ui.hasVisibleCustomDialog(owner: owner) }) {
                    // The dialog-local overlay cannot validate screen fragments
                    // or implement custom durations/buttons. Reject those options
                    // instead of silently bypassing the application provider.
                    guard Set(arguments.keys) == ["kind", "config"],
                          Set(config.keys).isSubset(of: ["style", "text", "fragment"]),
                          config["fragment"] == nil || config["fragment"] == .null else {
                        throw AyuBridgeFailure.unsupported("custom-dialog bulletin options or fragment")
                    }
                    guard let text = config["text"]?.string, !text.isEmpty, text.utf8.count <= 4096,
                          let style = config["style"]?.string, ["simple", "success", "error"].contains(style) else {
                        throw AyuBridgeFailure("invalid_arguments", "Invalid custom-dialog bulletin")
                    }
                    DispatchQueue.main.sync { self.ui.showDialogBulletin(owner: owner, text: text, style: style) }
                    return .null
                }
            }
            guard self.provider.capabilities.contains(operation) else { throw AyuBridgeFailure.unsupported(operation) }
            try self.validateReferences(.object(arguments), owner: owner)
            let prepared = try self.provider.prepareCall(pluginID: owner, operation: operation, arguments: arguments, context: self.adapterContext(owner: owner, generation: session.generation))
            do {
                let result = try self.adapterResult(prepared.result, owner: owner)
                prepared.commit(result)
                return result
            } catch { prepared.rollback(); throw error }
        default: throw AyuBridgeFailure.unsupported(operation)
        }
    }

    private func construct(owner: String, arguments: [String: AyuBridgeValue], generation: UUID) throws -> AyuBridgeValue {
        try self.validateJavaArguments(arguments)
        let name = try self.className(arguments)
        guard self.knownClass(name) else { throw AyuBridgeFailure.unsupported(name) }
        let args = arguments["args"]?.array ?? []
        if let adapter = self.classRegistry.adapters[name] {
            guard let constructor = adapter.constructor else { throw AyuBridgeFailure.unsupported("constructor " + name) }
            let fields = try constructor(args, self.adapterContext(owner: owner, generation: generation))
            try self.validateAdapterState(fields, className: name, owner: owner)
            try self.validateAdapterResponse(self.reference(String(repeating: "0", count: 36), className: name))
            return try self.store(owner: owner, className: name, kind: "adapter", fields: fields)
        }
        if name.hasSuffix("$LayoutParams") {
            let isLinearParams = name == "android.widget.LinearLayout$LayoutParams"
            guard args.count == 2 || (isLinearParams && args.count == 3) else {
                throw AyuBridgeFailure("invalid_arguments", "LayoutParams requires width and height, with optional LinearLayout weight")
            }
            let width = try self.number(args[0]); let height = try self.number(args[1])
            guard [width, height].allSatisfy({ $0 >= 0 || $0 == -1 || $0 == -2 }) else { throw AyuBridgeFailure("invalid_arguments", "Invalid layout size") }
            var fields: [String: AyuBridgeValue] = ["width": .number(width), "height": .number(height)]
            if isLinearParams {
                let weight = args.count == 3 ? try self.number(args[2]) : 0
                guard weight.isFinite, (0...100_000).contains(weight) else { throw AyuBridgeFailure("invalid_arguments", "Invalid LinearLayout weight") }
                fields["weight"] = .number(weight)
            }
            return try self.store(owner: owner, className: name, kind: "layout", fields: fields)
        }
        var progressBarMode: String?
        if name == "android.widget.ProgressBar" {
            if args.count == 1 {
                progressBarMode = "indeterminate"
            } else if args.count == 3, args[1] == .null, args[2].integer == 0x0101_0078 {
                progressBarMode = "horizontal"
            } else {
                throw AyuBridgeFailure.unsupported("ProgressBar constructor")
            }
        }
        if name == "android.widget.CheckBox",
           args.count != 1 || args[0].object?["$handle"] == nil {
            throw AyuBridgeFailure.unsupported("CheckBox constructor")
        }
        let contextArgument = progressBarMode != nil
            ? (args.first == .null || args.first?.object?["$handle"] != nil)
            : (args.isEmpty || (args.count == 1 && (args[0] == .null || args[0].object?["$handle"] != nil)))
        guard Self.viewClasses.contains(name), contextArgument else { throw AyuBridgeFailure.unsupported("constructor " + name) }
        var viewFields: [String: AyuBridgeValue] = [:]
        if let progressBarMode {
            viewFields["progress_mode"] = .string(progressBarMode)
            viewFields["progress_max"] = .integer(100)
            viewFields["progress"] = .integer(0)
        }
        if name == "android.widget.CheckBox" { viewFields["checked"] = .bool(false) }
        if let contextValue = args.first, contextValue != .null {
            let contextHandle = try self.handle(contextValue)
            let context = try self.remote(contextHandle, owner: owner)
            guard context.kind == "adapter", context.className == "android.content.Context" else {
                throw AyuBridgeFailure.unsupported("View constructor Context")
            }
            viewFields["context_handle"] = .string(contextHandle)
        }
        let value = try self.store(owner: owner, className: name, kind: "view", fields: viewFields)
        let handle = value["$handle"].string!
        DispatchQueue.main.sync {
            self.ui.create(owner: owner, generation: generation, handle: handle, className: name,
                           isIndeterminateProgressBar: progressBarMode == "indeterminate")
        }
        return value
    }

    private func presentCustomDialog(owner: String, config: [String: AyuBridgeValue], generation: UUID) throws -> AyuBridgeValue {
        guard Set(config.keys).isSubset(of: ["context", "title", "message", "view", "positive_button", "negative_button", "neutral_button", "cancelable"]),
              config["view"] != nil else { throw AyuBridgeFailure.unsupported("alert configuration") }
        if let context = config["context"], context != .null { _ = try self.remote(self.handle(context), owner: owner) }
        let viewHandle = try self.handle(config["view"] ?? .null)
        let content = try self.remote(viewHandle, owner: owner)
        guard content.kind == "view", content.fields["parent"] == nil else { throw AyuBridgeFailure("invalid_state", "Dialog content must be an unparented view") }
        let title = try self.dialogText(config["title"], limit: 1024)
        let message = try self.dialogText(config["message"], limit: 8192)
        guard let dialogHost = self.provider as? AyuPluginDialogHost else { throw AyuBridgeFailure.unsupported("dialog host") }
        let token = UUID().uuidString
        try dialogHost.reserveDialogToken(token, pluginID: owner)
        let reference = try self.store(owner: owner, className: "org.telegram.ui.ActionBar.AlertDialog", kind: "adapter", fields: ["token": .string(token)])
        var actions: [AyuBridgeUI.DialogAction] = []
        for (key, which, style) in [("neutral_button", Int64(-3), 0), ("negative_button", Int64(-2), 1), ("positive_button", Int64(-1), 0)] {
            guard let value = config[key] else { continue }
            guard let button = value.object, Set(button.keys) == ["text", "on_click"],
                  let text = button["text"]?.string, !text.isEmpty, text.utf8.count <= 1024,
                  let callback = button["on_click"] else { throw AyuBridgeFailure("invalid_arguments", "Invalid dialog button") }
            let callbackID: String?
            if callback == .null {
                callbackID = nil
            } else {
                callbackID = try self.callbackID(callback, owner: owner, method: "onClick")
            }
            actions.append(AyuBridgeUI.DialogAction(title: text, style: style, handler: { [weak self] in
                (self?.provider as? AyuPluginDialogHost)?.dismissBridgeDialog(token: token, pluginID: owner)
                guard let self, let callbackID else { return }
                self.enqueueCallback(owner: owner, generation: generation, callbackID: callbackID, arguments: [reference, .integer(which)])
            }))
        }
        guard !actions.isEmpty else {
            dialogHost.dismissBridgeDialog(token: token, pluginID: owner)
            throw AyuBridgeFailure("invalid_arguments", "Dialog requires a button")
        }
        let cancelable = config["cancelable"]?.bool ?? true
        do {
            try DispatchQueue.main.sync {
                let controller = try self.ui.makeCustomDialog(owner: owner, generation: generation, handle: viewHandle, title: title, message: message, actions: actions, cancelable: cancelable)
                controller.onDismiss = { [weak self] in (self?.provider as? AyuPluginDialogHost)?.dismissBridgeDialog(token: token, pluginID: owner) }
                self.ui.trackCustomDialog(owner: owner, controller: controller)
                try dialogHost.presentBridgeDialog(controller, token: token, pluginID: owner)
            }
        } catch {
            dialogHost.dismissBridgeDialog(token: token, pluginID: owner)
            throw error
        }
        return reference
    }

    private func dialogText(_ value: AyuBridgeValue?, limit: Int) throws -> String? {
        if value == nil || value == .null { return nil }
        guard let text = value?.string, text.utf8.count <= limit else { throw AyuBridgeFailure("invalid_arguments", "Invalid dialog text") }
        return text
    }

    private func invoke(owner: String, arguments: [String: AyuBridgeValue], generation: UUID) throws -> AyuBridgeValue {
        try self.validateJavaArguments(arguments)
        let remote = try self.targetRemote(arguments, owner: owner)
        let method = arguments["name"]?.string ?? arguments["method"]?.string ?? ""
        if method == "getClass", remote.kind != "class" { return try self.store(owner: owner, className: remote.className, kind: "class") }
        if remote.kind == "class" {
            if let handler = self.classRegistry.adapters[remote.className]?.staticMethods[method] {
                return try self.adapterResult(handler(arguments["args"]?.array ?? [], self.adapterContext(owner: owner, generation: generation)), owner: owner)
            }
            if remote.className == "android.text.TextUtils", method == "isEmpty" {
                let args = arguments["args"]?.array ?? []
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "TextUtils.isEmpty requires one string") }
                if args[0] == .null { return .bool(true) }
                return .bool(try self.textValue(args[0], owner: owner).isEmpty)
            }
            if remote.className == "java.lang.reflect.Array" {
                return try self.reflectArray(method, arguments: arguments["args"]?.array ?? [], owner: owner)
            }
            if remote.className == "java.lang.Class", method == "forName" {
                guard let args = arguments["args"]?.array, args.count == 1,
                      let name = args[0].string, name.utf8.count <= 256,
                      name.range(of: "\\A[A-Za-z][A-Za-z0-9_.$]*\\z", options: .regularExpression) != nil else {
                    throw AyuBridgeFailure("invalid_arguments", "Class.forName requires one exact class name")
                }
                guard self.knownClass(name) else { throw AyuBridgeFailure.unsupported(name) }
                return try self.store(owner: owner, className: name, kind: "class")
            }
            if method == "getName" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.getName takes no arguments") }
                return .string(remote.className)
            }
            if method == "getDeclaredMethod" {
                guard let args = arguments["args"]?.array, args.count == 1, let name = args[0].string else {
                    throw AyuBridgeFailure("invalid_arguments", "Class.getDeclaredMethod supports name-only lookup")
                }
                guard self.declaredMethods(for: remote.className).contains(name) else {
                    throw AyuBridgeFailure.unsupported("reflection target")
                }
                return try self.store(owner: owner, className: "java.lang.reflect.Method", kind: "method", fields: ["name": .string(name), "declaring_class": .string(remote.className)])
            }
            if method == "getDeclaredMethods" {
                guard (arguments["args"]?.array ?? []).isEmpty else {
                    throw AyuBridgeFailure("invalid_arguments", "Class.getDeclaredMethods takes no arguments")
                }
                let snapshot = self.objects
                do {
                    let results = try self.declaredMethods(for: remote.className).sorted().map {
                        try self.store(owner: owner, className: "java.lang.reflect.Method", kind: "method", fields: ["name": .string($0), "declaring_class": .string(remote.className)])
                    }
                    // `encode` falls back to a small quota error if the final
                    // response is too large. Validate before returning so the
                    // handles cannot remain allocated when that fallback would
                    // hide the result from the caller.
                    try self.validateAdapterResponse(.array(results))
                    return .array(results)
                } catch {
                    // Reflection results are transactional: a failed response
                    // must not retain method handles that the caller never saw.
                    self.objects = snapshot
                    throw error
                }
            }
            if method == "getSimpleName" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.getSimpleName takes no arguments") }
                return .string(Self.simpleClassName(remote.className))
            }
            if method == "getPackageName" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.getPackageName takes no arguments") }
                return .string(Self.packageName(for: remote.className))
            }
            if method == "isPrimitive" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.isPrimitive takes no arguments") }
                return .bool(Self.primitiveClassNames.contains(remote.className))
            }
            if method == "isArray" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.isArray takes no arguments") }
                return .bool(Self.arrayComponentName(for: remote.className) != nil)
            }
            if method == "isInterface" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.isInterface takes no arguments") }
                return .bool(Self.interfaceClassNames.contains(remote.className))
            }
            if method == "isEnum" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.isEnum takes no arguments") }
                return .bool(Self.enumClassNames.contains(remote.className))
            }
            if method == "getComponentType" {
                guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Class.getComponentType takes no arguments") }
                guard let component = Self.arrayComponentName(for: remote.className) else { return .null }
                return try self.store(owner: owner, className: component, kind: "class")
            }
            throw AyuBridgeFailure.unsupported(remote.className + "." + method)
        }
        if remote.kind == "method", method == "getName" { return remote.fields["name"] ?? .null }
        if remote.kind == "view", method == "getContext" {
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "getContext takes no arguments")
            }
            guard let contextHandle = remote.fields["context_handle"]?.string else { return .null }
            let context = try self.remote(contextHandle, owner: owner)
            guard context.kind == "adapter", context.className == "android.content.Context" else {
                throw AyuBridgeFailure("invalid_state", "View context is unavailable")
            }
            return self.reference(contextHandle, className: context.className)
        }
        if remote.kind == "view", method == "getResources" {
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "getResources takes no arguments")
            }
            guard let contextHandle = remote.fields["context_handle"]?.string else {
                throw AyuBridgeFailure.unsupported("View.getResources without a bound Context")
            }
            let contextRemote = try self.remote(contextHandle, owner: owner)
            guard contextRemote.kind == "adapter", contextRemote.className == "android.content.Context",
                  let getResources = self.classRegistry.adapters[contextRemote.className]?.methods["getResources"] else {
                throw AyuBridgeFailure.unsupported("View.getResources Context adapter")
            }
            var contextState = contextRemote.fields
            let result = try getResources(&contextState, [], self.adapterContext(owner: owner, generation: generation))
            guard contextState == contextRemote.fields else {
                self.rollbackPreparedResult(result)
                throw AyuBridgeFailure("invalid_state", "Context.getResources must be read-only")
            }
            guard case let .instance(className, fields) = result,
                  className == "android.content.res.Resources" else {
                self.rollbackPreparedResult(result)
                throw AyuBridgeFailure.unsupported("Context.getResources result")
            }
            try self.validateAdapterState(fields, className: className, owner: owner)
            try self.validateAdapterResponse(self.reference(String(repeating: "0", count: 36), className: className))
            let reference: AyuBridgeValue
            if let cachedHandle = remote.fields["resources_handle"]?.string,
               var cached = self.objects[cachedHandle], cached.owner == owner,
               cached.kind == "adapter", cached.className == className {
                cached.fields = fields
                self.objects[cachedHandle] = cached
                reference = self.reference(cachedHandle, className: className)
            } else {
                reference = try self.store(owner: owner, className: className, kind: "adapter", fields: fields)
                self.objects[handle]?.fields["resources_handle"] = reference["$handle"]
            }
            return reference
        }
        if remote.kind == "view", method == "animate" {
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "View.animate takes no arguments")
            }
            let viewHandle = try self.target(arguments)
            if let animatorHandle = remote.fields["animator_handle"]?.string,
               let animator = try? self.remote(animatorHandle, owner: owner),
               animator.kind == "animator", animator.className == "android.view.ViewPropertyAnimator" {
                return self.reference(animatorHandle, className: animator.className)
            }
            let reference = try self.store(owner: owner, className: "android.view.ViewPropertyAnimator", kind: "animator", fields: [
                "view": .string(viewHandle),
                "properties": .object([:]),
                "duration_ms": .number(250),
                "start_delay_ms": .number(0),
            ])
            if let animatorHandle = reference["$handle"].string {
                self.objects[viewHandle]?.fields["animator_handle"] = .string(animatorHandle)
            }
            return reference
        }
        if remote.kind == "view", (method == "post" || method == "postDelayed") {
            let args = arguments["args"]?.array ?? []
            let delay: Int64
            if method == "post" {
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "View.post expects one Runnable") }
                delay = 0
            } else {
                guard args.count == 2, let requestedDelay = args[1].integer else {
                    throw AyuBridgeFailure("invalid_arguments", "View.postDelayed expects a Runnable and integer delay")
                }
                guard (0...60_000).contains(requestedDelay) else {
                    throw AyuBridgeFailure("invalid_arguments", "View callback delay is out of range")
                }
                delay = requestedDelay
            }
            let runnable = try self.remote(self.handle(args[0]), owner: owner)
            guard runnable.kind == "proxy", runnable.className == "java.lang.Runnable" else {
                throw AyuBridgeFailure("invalid_arguments", "View.post requires an owned Runnable proxy")
            }
            let callbackID = try self.callbackID(runnable.fields["run"] ?? .null, owner: owner, method: "run")
            let prepared = try self.prepareScheduledCallback(owner: owner, generation: generation,
                callbackID: callbackID, delayMilliseconds: delay)
            guard case let .value(value) = prepared.result else {
                prepared.rollback()
                throw AyuBridgeFailure("invalid_state", "Runnable scheduling did not produce a value")
            }
            do { try self.validateAdapterResponse(value) }
            catch { prepared.rollback(); throw error }
            prepared.commit(value)
            return value
        }
        if remote.kind == "adapter" {
            guard let handler = self.classRegistry.adapters[remote.className]?.methods[method] else { throw AyuBridgeFailure.unsupported(remote.className + "." + method) }
            let handle = try self.target(arguments)
            var fields = remote.fields
            let snapshot = self.objects
            do {
                let result = try handler(&fields, arguments["args"]?.array ?? [], self.adapterContext(owner: owner, generation: generation))
                do {
                    try self.validateAdapterState(fields, className: remote.className, owner: owner, replacing: handle)
                } catch {
                    self.rollbackPreparedResult(result)
                    throw error
                }
                self.objects[handle]?.fields = fields
                if case let .instance(className, returnedFields) = result,
                   className == remote.className,
                   self.classRegistry.adapters[remote.className]?.receiverMethods.contains(method) == true {
                    // Android mutators return the same object. Keep the
                    // existing owner-scoped handle rather than allocating a
                    // second identity for an Intent/View/Paint-style setter.
                    try self.validateAdapterState(returnedFields, className: className, owner: owner, replacing: handle)
                    let reference = self.reference(handle, className: className)
                    try self.validateAdapterResponse(reference)
                    if className == "android.graphics.drawable.ColorDrawable" || className == "android.graphics.drawable.GradientDrawable" {
                        let updates = self.backgroundMutationCommands(owner: owner, generation: generation,
                            drawableHandle: handle, className: className, fields: returnedFields)
                        if !updates.isEmpty { try self.ui.enqueue(updates) }
                        self.updateBackgroundSnapshots(owner: owner, generation: generation,
                            drawableHandle: handle, className: className, fields: returnedFields)
                    }
                    self.objects[handle]?.fields = returnedFields
                    return reference
                }
                return try self.adapterResult(result, owner: owner)
            } catch { self.objects = snapshot; throw error }
        }
        if remote.kind == "animator" {
            guard let viewHandle = remote.fields["view"]?.string else {
                throw AyuBridgeFailure("invalid_state", "Animator view is unavailable")
            }
            let view = try self.remote(viewHandle, owner: owner)
            guard view.kind == "view" else { throw AyuBridgeFailure("invalid_state", "Animator target is not a view") }
            let args = arguments["args"]?.array ?? []
            let animatorHandle = try self.target(arguments)
            var updated = remote
            switch method {
            case "alpha", "translationX", "translationY", "scaleX", "scaleY", "rotation", "rotationX", "rotationY":
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Animator property requires one value") }
                let value = try self.number(args[0])
                if method == "alpha" {
                    guard (0...1).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Invalid animation alpha") }
                }
                guard abs(value) <= 100_000 else { throw AyuBridgeFailure("invalid_arguments", "Animation value is out of range") }
                var properties = updated.fields["properties"]?.object ?? [:]
                let propertyNames: [String: String] = [
                    "alpha": "alpha", "translationX": "translation_x", "translationY": "translation_y",
                    "scaleX": "scale_x", "scaleY": "scale_y", "rotation": "rotation",
                    "rotationX": "rotation_x", "rotationY": "rotation_y",
                ]
                properties[propertyNames[method]!] = .number(value)
                updated.fields["properties"] = .object(properties)
                self.objects[animatorHandle] = updated
                return self.reference(animatorHandle, className: updated.className)
            case "setDuration":
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Animator duration requires one value") }
                guard args[0].integer != nil else { throw AyuBridgeFailure("invalid_arguments", "Animator duration requires an integer") }
                let duration = try self.number(args[0])
                guard duration >= 0, duration <= 10_000 else {
                    throw AyuBridgeFailure("invalid_arguments", "Animation exceeds duration limit")
                }
                updated.fields["duration_ms"] = .number(duration)
                self.objects[animatorHandle] = updated
                return self.reference(animatorHandle, className: updated.className)
            case "setStartDelay":
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Animator start delay requires one value") }
                guard args[0].integer != nil else { throw AyuBridgeFailure("invalid_arguments", "Animator start delay requires an integer") }
                let delay = try self.number(args[0])
                guard delay >= 0, delay <= 60_000 else {
                    throw AyuBridgeFailure("invalid_arguments", "Animation start delay is out of range")
                }
                updated.fields["start_delay_ms"] = .number(delay)
                self.objects[animatorHandle] = updated
                return self.reference(animatorHandle, className: updated.className)
            case "setInterpolator":
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Animator interpolator requires one value") }
                let interpolatorHandle = try self.handle(args[0])
                let interpolator = try self.remote(interpolatorHandle, owner: owner)
                guard interpolator.kind == "adapter",
                      ["android.view.animation.LinearInterpolator", "android.view.animation.DecelerateInterpolator", "android.view.animation.OvershootInterpolator"].contains(interpolator.className) else {
                    throw AyuBridgeFailure.unsupported("ViewPropertyAnimator interpolator")
                }
                if interpolator.className == "android.view.animation.DecelerateInterpolator",
                   interpolator.fields["parameter"]?.number != 1 {
                    throw AyuBridgeFailure.unsupported("ViewPropertyAnimator DecelerateInterpolator factor")
                }
                updated.fields["interpolator"] = .object([
                    "class": .string(interpolator.className),
                    "state": .object(interpolator.fields),
                ])
                self.objects[animatorHandle] = updated
                return self.reference(animatorHandle, className: updated.className)
            case "withEndAction":
                guard args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Animator end action requires one Runnable") }
                if args[0] == .null {
                    updated.fields.removeValue(forKey: "end_callback")
                } else {
                    let runnableHandle = try self.handle(args[0])
                    let runnable = try self.remote(runnableHandle, owner: owner)
                    guard runnable.kind == "proxy", runnable.className == "java.lang.Runnable" else {
                        throw AyuBridgeFailure.unsupported("ViewPropertyAnimator.withEndAction Runnable")
                    }
                    let callbackID = try self.callbackID(runnable.fields["run"] ?? .null, owner: owner, method: "run")
                    updated.fields["end_callback"] = .string(callbackID)
                }
                self.objects[animatorHandle] = updated
                return self.reference(animatorHandle, className: updated.className)
            case "start":
                guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Animator.start takes no arguments") }
                var options = updated.fields["properties"]?.object ?? [:]
                options["duration_ms"] = updated.fields["duration_ms"] ?? .number(250)
                options["start_delay_ms"] = updated.fields["start_delay_ms"] ?? .number(0)
                if let interpolator = updated.fields["interpolator"] { options["interpolator"] = interpolator }
                let command = AyuBridgeUI.Command(owner: owner, generation: generation, handle: viewHandle,
                    method: "animate", arguments: [.object(options)], backgroundDrawableHandle: nil,
                    layoutClassName: nil, layoutHandle: nil,
                    animationCompletionCallbackID: updated.fields["end_callback"]?.string)
                try self.ui.enqueue([command])
                // Android consumes the pending property and completion action
                // when a run starts; do not replay them on a later start().
                updated.fields["properties"] = .object([:])
                updated.fields.removeValue(forKey: "end_callback")
                self.objects[animatorHandle] = updated
                return .null
            case "cancel":
                guard args.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Animator.cancel takes no arguments") }
                DispatchQueue.main.sync { self.ui.cancelAnimations(owner: owner, handle: viewHandle) }
                return .null
            default:
                throw AyuBridgeFailure.unsupported("ViewPropertyAnimator." + method)
            }
        }
        if remote.kind == "layout", method == "setMargins" {
            let values = try (arguments["args"]?.array ?? []).map(self.number)
            guard values.count == 4, values.allSatisfy({ abs($0) <= 100_000 }) else { throw AyuBridgeFailure("invalid_arguments", "Invalid layout margins") }
            let layoutHandle = try self.target(arguments)
            let snapshot = self.objects
            self.objects[layoutHandle]?.fields["margins"] = .array(values.map { .number($0) })
            do { try self.propagateLayoutParams(owner: owner, generation: generation, layoutHandle: layoutHandle) }
            catch { self.objects = snapshot; throw error }
            return .null
        }
        guard remote.kind == "view", Self.methods(for: remote.className).contains(method) else { throw AyuBridgeFailure.unsupported(remote.className + "." + method) }
        let handle = try self.target(arguments)
        if method == "requestFocus" {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "requestFocus takes no arguments") }
            guard remote.className == "android.widget.EditText" else { throw AyuBridgeFailure.unsupported(remote.className + ".requestFocus") }
            return .bool(DispatchQueue.main.sync { self.ui.requestFocus(owner: owner, handle: handle) })
        }
        if method == "setSelection" {
            guard remote.className == "android.widget.EditText" else { throw AyuBridgeFailure.unsupported(remote.className + ".setSelection") }
            guard let args = arguments["args"]?.array, args.count == 1,
                  let rawOffset = args[0].integer, let offset = Int(exactly: rawOffset), offset >= 0 else {
                throw AyuBridgeFailure("invalid_arguments", "EditText.setSelection expects one nonnegative UTF-16 offset")
            }
            try DispatchQueue.main.sync { try self.ui.setSelection(owner: owner, handle: handle, offset: offset) }
            return .null
        }
        if (method == "setColorFilter" || method == "clearColorFilter"),
           !Self.isImageViewClass(remote.className) {
            throw AyuBridgeFailure.unsupported(remote.className + "." + method)
        }
        if method == "getParent" {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "getParent takes no arguments") }
            guard let parent = remote.fields["parent"]?.string else { return .null }
            guard parent != "$mount" else { throw AyuBridgeFailure.unsupported("mounted root parent") }
            let parentRemote = try self.remote(parent, owner: owner)
            guard parentRemote.kind == "view", Self.viewGroupClasses.contains(parentRemote.className) else {
                throw AyuBridgeFailure("invalid_state", "View parent is not a supported ViewGroup")
            }
            return self.reference(parent, className: parentRemote.className)
        }
        if method == "getChildCount" {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "getChildCount takes no arguments") }
            guard Self.viewGroupClasses.contains(remote.className) else { throw AyuBridgeFailure.unsupported("getChildCount") }
            return .integer(Int64(remote.fields["children"]?.array?.count ?? 0))
        }
        if method == "getChildAt" {
            guard Self.viewGroupClasses.contains(remote.className) else { throw AyuBridgeFailure.unsupported("getChildAt") }
            guard let args = arguments["args"]?.array, args.count == 1, let rawIndex = args[0].integer,
                  let index = Int(exactly: rawIndex) else { throw AyuBridgeFailure("invalid_arguments", "getChildAt expects one bounded index") }
            let children = remote.fields["children"]?.array ?? []
            guard index >= 0, index < children.count, let child = children[index].string else { return .null }
            let childRemote = try self.remote(child, owner: owner)
            guard childRemote.kind == "view" else { throw AyuBridgeFailure("invalid_state", "Child is not a view") }
            return self.reference(child, className: childRemote.className)
        }
        if method == "findViewById" {
            guard let args = arguments["args"]?.array, args.count == 1,
                  let rawID = args[0].integer, Int32(exactly: rawID) != nil else {
                throw AyuBridgeFailure("invalid_arguments", "findViewById expects one signed 32-bit ID")
            }
            var pending = [handle]
            var visited: Set<String> = []
            while let candidate = pending.popLast() {
                guard visited.insert(candidate).inserted else {
                    throw AyuBridgeFailure("invalid_state", "View hierarchy contains a cycle")
                }
                let candidateRemote = try self.remote(candidate, owner: owner)
                guard candidateRemote.kind == "view" else {
                    throw AyuBridgeFailure("invalid_state", "View hierarchy contains a non-view child")
                }
                if (candidateRemote.fields["id"]?.integer ?? -1) == rawID {
                    return self.reference(candidate, className: candidateRemote.className)
                }
                if Self.viewGroupClasses.contains(candidateRemote.className) {
                    let children = candidateRemote.fields["children"]?.array ?? []
                    for child in children.reversed() {
                        guard let childHandle = child.string else {
                            throw AyuBridgeFailure("invalid_state", "View hierarchy contains an invalid child")
                        }
                        pending.append(childHandle)
                    }
                }
            }
            return .null
        }
        if method == "getRootView" {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "getRootView takes no arguments") }
            var root = handle
            var visited: Set<String> = [root]
            while let parent = self.objects[root]?.fields["parent"]?.string, parent != "$mount" {
                guard visited.insert(parent).inserted else { throw AyuBridgeFailure("invalid_state", "View hierarchy contains a cycle") }
                let parentRemote = try self.remote(parent, owner: owner)
                guard parentRemote.kind == "view", Self.viewGroupClasses.contains(parentRemote.className) else {
                    throw AyuBridgeFailure("invalid_state", "View parent is not a supported ViewGroup")
                }
                root = parent
            }
            let rootRemote = try self.remote(root, owner: owner)
            return self.reference(root, className: rootRemote.className)
        }
        if method == "getTag" {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "getTag takes no arguments") }
            let value = remote.fields["tag"] ?? .null
            try self.validateAdapterResponse(value)
            return value
        }
        if method == "getColorFilter" {
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "getColorFilter takes no arguments")
            }
            guard Self.isImageViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".getColorFilter")
            }
            guard let filter = remote.fields["color_filter"]?.object,
                  let color = filter["color"], filter["mode"]?.string == "SRC_IN" else { return .null }
            if let cachedHandle = remote.fields["color_filter_handle"]?.string,
               let cached = try? self.remote(cachedHandle, owner: owner),
               cached.className == "android.graphics.PorterDuffColorFilter", cached.kind == "adapter" {
                return self.reference(cachedHandle, className: cached.className)
            }
            let reference = try self.store(owner: owner, className: "android.graphics.PorterDuffColorFilter", kind: "adapter",
                fields: ["color": color, "mode": .string("SRC_IN")])
            self.objects[handle]?.fields["color_filter_handle"] = reference["$handle"]
            return reference
        }
        if method == "getBackground" {
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "getBackground takes no arguments")
            }
            if let drawableHandle = remote.fields["background_drawable"]?.string,
               let drawable = try? self.remote(drawableHandle, owner: owner),
               drawable.kind == "adapter", Self.backgroundDrawableClasses.contains(drawable.className) {
                return self.reference(drawableHandle, className: drawable.className)
            }
            guard let snapshot = remote.fields["background_snapshot"]?.object,
                  let className = snapshot["class_name"]?.string,
                  Self.backgroundDrawableClasses.contains(className),
                  let fields = snapshot["fields"]?.object else { return .null }
            try self.validateAdapterState(fields, className: className, owner: owner)
            let reference = try self.store(owner: owner, className: className, kind: "adapter", fields: fields)
            self.objects[handle]?.fields["background_drawable"] = reference["$handle"]
            self.objects[handle]?.fields["background_drawable_generation"] = generation.uuidString
            return reference
        }
        if method == "getOutlineProvider" {
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "getOutlineProvider takes no arguments")
            }
            if let configured = remote.fields["outline_provider"], configured != .string("BACKGROUND") { return .null }
            return try self.backgroundOutlineProvider(owner: owner)
        }
        if method == "setTag" {
            guard let args = arguments["args"]?.array, args.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "setTag expects one value") }
            let value = args[0]
            try self.validateReferences(value, owner: owner, registerCallbacks: false)
            switch value {
            case .null, .bool(_), .integer(_):
                break
            case let .number(number):
                guard number.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Expected a finite tag value") }
            case let .string(string):
                guard string.utf8.count <= 65_536 else { throw AyuBridgeFailure("resource_limit", "View tag exceeds quota") }
            case .object(_):
                guard let taggedHandle = value["$handle"].string else { throw AyuBridgeFailure("invalid_arguments", "Expected a supported owned tag object") }
                let taggedRemote = try self.remote(taggedHandle, owner: owner)
                guard !["proxy", "method", "class", "array"].contains(taggedRemote.kind) else {
                    throw AyuBridgeFailure("invalid_arguments", "Callback and metadata handles cannot be stored as view tags")
                }
            case .array(_):
                throw AyuBridgeFailure("invalid_arguments", "Expected a supported scalar or owned tag object")
            }
            self.objects[handle]?.fields["tag"] = value == .null ? nil : value
            return .null
        }
        if method == "getLayoutParams" {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", "getLayoutParams takes no arguments") }
            guard let snapshot = remote.fields["layout_params"]?.object,
                  let className = snapshot["class_name"]?.string,
                  let fields = snapshot["fields"]?.object else { return .null }
            guard className.hasSuffix("$LayoutParams"), self.knownClass(className) else {
                throw AyuBridgeFailure("invalid_state", "Stored layout parameters are unavailable")
            }
            if let cachedHandle = remote.fields["layout_params_handle"]?.string,
               var cached = self.objects[cachedHandle], cached.owner == owner,
               cached.className == className, cached.kind == "layout" {
                cached.fields = fields
                self.objects[cachedHandle] = cached
                return self.reference(cachedHandle, className: className)
            }
            let reference = try self.store(owner: owner, className: className, kind: "layout", fields: fields)
            self.objects[handle]?.fields["layout_params_handle"] = reference["$handle"]
            return reference
        }
        if method == "getText", remote.className == "android.widget.EditText" {
            let text = try DispatchQueue.main.sync { try self.ui.readText(owner: owner, handle: handle) }
            return try self.store(owner: owner, className: "java.lang.String", kind: "adapter", fields: ["value": .string(text)])
        }
        if method == "isChecked" {
            guard remote.className == "android.widget.CheckBox" else {
                throw AyuBridgeFailure.unsupported(remote.className + ".isChecked")
            }
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", "isChecked takes no arguments")
            }
            return try DispatchQueue.main.sync { try self.ui.read(owner: owner, handle: handle, method: method) }
        }
        if Self.progressReadMethods.contains(method) {
            guard remote.className == "android.widget.ProgressBar" else {
                throw AyuBridgeFailure.unsupported(remote.className + "." + method)
            }
            guard (arguments["args"]?.array ?? []).isEmpty else {
                throw AyuBridgeFailure("invalid_arguments", method + " takes no arguments")
            }
            return remote.fields[method == "getMax" ? "progress_max" : "progress"] ?? .integer(0)
        }
        if Self.readMethods.contains(method) || (Self.isScrollViewClass(remote.className) && Self.scrollReadMethods.contains(method)) {
            guard (arguments["args"]?.array ?? []).isEmpty else { throw AyuBridgeFailure("invalid_arguments", method + " takes no arguments") }
            guard method != "getText" || ["android.widget.TextView", "android.widget.CheckBox"].contains(remote.className) else { throw AyuBridgeFailure.unsupported(method) }
            if ["hasFocus", "getSelectionStart", "getSelectionEnd"].contains(method), remote.className != "android.widget.EditText" {
                throw AyuBridgeFailure.unsupported(remote.className + "." + method)
            }
            return try DispatchQueue.main.sync { try self.ui.read(owner: owner, handle: handle, method: method) }
        }
        let snapshot = self.objects
        do {
            let command = try self.uiCommand(owner: owner, arguments: arguments, generation: generation)
            try self.ui.enqueue([command])
            self.track(command)
        } catch { self.objects = snapshot; throw error }
        return method == "performHapticFeedback" ? .bool(true) : .null
    }

    private func track(_ command: AyuBridgeUI.Command) {
        if command.method == "setBackgroundColor" || command.method == "setBackgroundStyle" || command.method == "clearBackground" {
            if let drawableHandle = command.backgroundDrawableHandle {
                self.objects[command.handle]?.fields["background_drawable"] = .string(drawableHandle)
                self.objects[command.handle]?.fields["background_drawable_generation"] = .string(command.generation.uuidString)
                self.updateBackgroundSnapshot(view: command.handle, drawable: drawableHandle)
            } else {
                self.objects[command.handle]?.fields.removeValue(forKey: "background_drawable")
                self.objects[command.handle]?.fields.removeValue(forKey: "background_drawable_generation")
                if command.method == "setBackgroundColor", let color = command.arguments.first?.integer {
                    self.objects[command.handle]?.fields["background_snapshot"] = .object([
                        "class_name": .string("android.graphics.drawable.ColorDrawable"),
                        "fields": .object(["color": .integer(color)]),
                    ])
                } else {
                    self.objects[command.handle]?.fields.removeValue(forKey: "background_snapshot")
                }
            }
        }
        if command.method == "setId", let identifier = command.arguments.first?.integer {
            self.objects[command.handle]?.fields["id"] = .integer(identifier)
        }
        if command.method == "setMax", let maximum = command.arguments.first?.integer {
            self.objects[command.handle]?.fields["progress_max"] = .integer(maximum)
            let current = self.objects[command.handle]?.fields["progress"]?.integer ?? 0
            self.objects[command.handle]?.fields["progress"] = .integer(min(current, maximum))
        }
        if command.method == "setProgress", let progress = command.arguments.first?.integer {
            self.objects[command.handle]?.fields["progress"] = .integer(progress)
        }
        if command.method == "setChecked", let checked = command.arguments.first?.bool {
            self.objects[command.handle]?.fields["checked"] = .bool(checked)
        }
        if command.method == "setOutlineProvider" {
            self.objects[command.handle]?.fields["outline_provider"] = command.arguments.first?.bool == true
                ? .string("BACKGROUND") : .null
        }
        if command.method == "setColorFilter" {
            self.objects[command.handle]?.fields.removeValue(forKey: "color_filter_handle")
            if let color = command.arguments.first?.integer {
                self.objects[command.handle]?.fields["color_filter"] = .object(["color": .integer(color), "mode": .string("SRC_IN")])
            } else {
                self.objects[command.handle]?.fields.removeValue(forKey: "color_filter")
            }
        }
        if command.method == "clearImage" {
            self.objects[command.handle]?.fields.removeValue(forKey: "image_cost")
        }
        if command.method == "addView", let child = command.arguments.first?["$handle"].string {
            var children = self.objects[command.handle]?.fields["children"]?.array ?? []
            children.removeAll(where: { $0 == .string(child) })
            let index: Int
            if command.arguments.count >= 3, let rawIndex = command.arguments[2].integer, let value = Int(exactly: rawIndex) {
                index = value
            } else {
                index = children.count
            }
            children.insert(.string(child), at: min(max(index, 0), children.count))
            self.objects[command.handle]?.fields["children"] = .array(children)
            self.objects[child]?.fields["parent"] = .string(command.handle)
            if let className = command.layoutClassName, command.arguments.count > 1,
               let fields = command.arguments[1].object {
                self.recordLayoutParams(view: child, owner: command.owner, className: className,
                    fields: fields, layoutHandle: command.layoutHandle)
            }
        }
        if command.method == "setLayoutParams", let className = command.layoutClassName,
           let fields = command.arguments.first?.object {
            self.recordLayoutParams(view: command.handle, owner: command.owner, className: className,
                fields: fields, layoutHandle: command.layoutHandle)
        }
        if command.method == "removeView", let child = command.arguments.first?["$handle"].string {
            self.objects[child]?.fields.removeValue(forKey: "parent")
            var children = self.objects[command.handle]?.fields["children"]?.array ?? []
            children.removeAll(where: { $0 == .string(child) })
            self.objects[command.handle]?.fields["children"] = children.isEmpty ? nil : .array(children)
        }
        if command.method == "unmount" {
            if let parent = self.objects[command.handle]?.fields["parent"]?.string, parent != "$mount",
               self.objects[parent]?.owner == command.owner {
                var children = self.objects[parent]?.fields["children"]?.array ?? []
                children.removeAll(where: { $0 == .string(command.handle) })
                self.objects[parent]?.fields["children"] = children.isEmpty ? nil : .array(children)
            }
            self.objects[command.handle]?.fields.removeValue(forKey: "parent")
        }
        if command.method == "bringToFront",
           let parent = self.objects[command.handle]?.fields["parent"]?.string, parent != "$mount",
           self.objects[parent]?.owner == command.owner {
            var children = self.objects[parent]?.fields["children"]?.array ?? []
            if let index = children.firstIndex(of: .string(command.handle)) {
                children.remove(at: index)
                children.append(.string(command.handle))
                self.objects[parent]?.fields["children"] = .array(children)
            }
        }
        if command.method == "removeAllViews" {
            let children = self.objects.filter { $0.value.owner == command.owner && $0.value.fields["parent"]?.string == command.handle }.map(\.key)
            for child in children { self.objects[child]?.fields.removeValue(forKey: "parent") }
            self.objects[command.handle]?.fields.removeValue(forKey: "children")
        }
        if command.method == "addTextChangedListener", let listener = command.arguments.first?["listener_handle"].string {
            var watchers = self.objects[command.handle]?.fields["text_watchers"]?.array ?? []
            watchers.append(.string(listener))
            self.objects[command.handle]?.fields["text_watchers"] = .array(watchers)
        }
        if command.method == "removeTextChangedListener", let listener = command.arguments.first?["listener_handle"].string,
           var watchers = self.objects[command.handle]?.fields["text_watchers"]?.array,
           let index = watchers.firstIndex(of: .string(listener)) {
            watchers.remove(at: index)
            self.objects[command.handle]?.fields["text_watchers"] = watchers.isEmpty ? nil : .array(watchers)
        }
    }

    private func updateBackgroundSnapshot(view: String, drawable: String) {
        guard let remote = self.objects[drawable], remote.kind == "adapter",
              Self.backgroundDrawableClasses.contains(remote.className) else { return }
        self.objects[view]?.fields["background_snapshot"] = .object([
            "class_name": .string(remote.className),
            "fields": .object(remote.fields),
        ])
    }

    private func updateBackgroundSnapshots(owner: String, generation: UUID, drawableHandle: String,
                                           className: String, fields: [String: AyuBridgeValue]) {
        guard Self.backgroundDrawableClasses.contains(className) else { return }
        let snapshot: AyuBridgeValue = .object([
            "class_name": .string(className),
            "fields": .object(fields),
        ])
        let viewHandles = self.objects.compactMap { handle, remote in
            remote.owner == owner && remote.kind == "view"
                && remote.fields["background_drawable"]?.string == drawableHandle
                && remote.fields["background_drawable_generation"]?.string == generation.uuidString ? handle : nil
        }
        for viewHandle in viewHandles {
            self.objects[viewHandle]?.fields["background_snapshot"] = snapshot
        }
    }

    private func backgroundOutlineProvider(owner: String) throws -> AyuBridgeValue {
        if let handle = self.sessions[owner]?.backgroundOutlineProviderHandle,
           let provider = try? self.remote(handle, owner: owner),
           provider.kind == "enum", provider.className == "android.view.ViewOutlineProvider",
           provider.fields["value"]?.string == "BACKGROUND" {
            return self.reference(handle, className: provider.className)
        }
        let value = try self.store(owner: owner, className: "android.view.ViewOutlineProvider", kind: "enum",
            fields: ["value": .string("BACKGROUND")])
        guard let handle = value["$handle"].string else {
            throw AyuBridgeFailure("invalid_state", "Outline provider handle is unavailable")
        }
        self.sessions[owner]?.backgroundOutlineProviderHandle = handle
        return value
    }

    private func recordLayoutParams(view: String, owner: String, className: String, fields: [String: AyuBridgeValue], layoutHandle: String?) {
        guard self.objects[view]?.owner == owner else { return }
        self.objects[view]?.fields["layout_params"] = .object([
            "class_name": .string(className), "fields": .object(fields),
        ])
        if let layoutHandle, self.objects[layoutHandle]?.owner == owner,
           self.objects[layoutHandle]?.kind == "layout", self.objects[layoutHandle]?.className == className {
            self.objects[view]?.fields["layout_params_handle"] = .string(layoutHandle)
        } else if let cachedHandle = self.objects[view]?.fields["layout_params_handle"]?.string,
           var cached = self.objects[cachedHandle], cached.owner == owner,
           cached.className == className, cached.kind == "layout" {
            cached.fields = fields
            self.objects[cachedHandle] = cached
        } else {
            self.objects[view]?.fields.removeValue(forKey: "layout_params_handle")
        }
    }

    private func propagateLayoutParams(owner: String, generation: UUID, layoutHandle: String) throws {
        guard let layout = self.objects[layoutHandle], layout.owner == owner, layout.kind == "layout" else {
            throw AyuBridgeFailure("invalid_handle", "Layout parameters are unavailable")
        }
        let attachedViews = self.objects.compactMap { handle, remote -> (String, Remote)? in
            guard remote.owner == owner, remote.kind == "view",
                  remote.fields["layout_params_handle"]?.string == layoutHandle else { return nil }
            return (handle, remote)
        }
        guard !attachedViews.isEmpty else { return }
        let value: AyuBridgeValue = .object(["class_name": .string(layout.className), "fields": .object(layout.fields)])
        var commands: [AyuBridgeUI.Command] = []
        commands.reserveCapacity(attachedViews.count)
        for (handle, _) in attachedViews {
            self.objects[handle]?.fields["layout_params"] = value
            commands.append(AyuBridgeUI.Command(owner: owner, generation: generation, handle: handle,
                method: "setLayoutParams", arguments: [.object(layout.fields)], backgroundDrawableHandle: nil,
                layoutClassName: layout.className, layoutHandle: layoutHandle))
        }
        try self.ui.enqueue(commands)
    }

    private func uiCommand(owner: String, arguments: [String: AyuBridgeValue], generation: UUID) throws -> AyuBridgeUI.Command {
        let handle = try self.target(arguments); let remote = try self.remote(handle, owner: owner)
        let method = arguments["method"]?.string ?? arguments["name"]?.string ?? ""
        guard remote.kind == "view", Self.methods(for: remote.className).contains(method),
              let arity = Self.writeMethods[method] ?? Self.scrollWriteMethods[method] ?? Self.otherWriteMethods[method] else {
            throw AyuBridgeFailure.unsupported(remote.className + "." + method)
        }
        var args = arguments["args"]?.array ?? []
        var nativeMethod = method
        var backgroundDrawableHandle: String?
        var layoutClassName: String?
        var layoutHandle: String?
        let validArity = args.count == arity || (method == "addView" && (2...3).contains(args.count)) ||
            (method == "setTextSize" && args.count == 2) || (method == "setTypeface" && args.count == 2) ||
            (method == "setColorFilter" && args.count == 2)
        guard validArity else { throw AyuBridgeFailure("invalid_arguments", "Wrong argument count for " + method) }
        try self.validateReferences(.array(args), owner: owner)
        if ["setText", "setTextColor", "setTextSize", "setHint", "setHintTextColor", "setSingleLine", "setMinLines"].contains(method),
           !["android.widget.TextView", "android.widget.EditText", "android.widget.CheckBox"].contains(remote.className) { throw AyuBridgeFailure.unsupported(method) }
        if ["setMaxLines", "setEllipsize", "setTextAlignment"].contains(method), remote.className != "android.widget.TextView" { throw AyuBridgeFailure.unsupported(method) }
        if method == "setTypeface", !["android.widget.TextView", "android.widget.EditText"].contains(remote.className) { throw AyuBridgeFailure.unsupported(method) }
        if method == "setInputType", remote.className != "android.widget.EditText" { throw AyuBridgeFailure.unsupported(method) }
        if ["setMax", "setProgress", "setProgressTintList"].contains(method),
           remote.className != "android.widget.ProgressBar" || remote.fields["progress_mode"] != .string("horizontal") {
            throw AyuBridgeFailure.unsupported(remote.className + "." + method)
        }
        if ["setChecked", "setButtonTintList", "setOnCheckedChangeListener"].contains(method),
           remote.className != "android.widget.CheckBox" {
            throw AyuBridgeFailure.unsupported(remote.className + "." + method)
        }
        if ["clearFocus", "hasFocus", "requestFocus"].contains(method), remote.className != "android.widget.EditText" { throw AyuBridgeFailure.unsupported(method) }
        if method == "setScaleType", !Self.isImageViewClass(remote.className) { throw AyuBridgeFailure.unsupported(method) }
        if method == "setOrientation", remote.className != "android.widget.LinearLayout" { throw AyuBridgeFailure.unsupported(method) }
        if ["setImageBase64", "setImageDrawable", "setImageResource"].contains(method), !Self.isImageViewClass(remote.className) { throw AyuBridgeFailure.unsupported(method) }
        if method == "addView" || method == "removeView" {
            guard Self.viewGroupClasses.contains(remote.className) else { throw AyuBridgeFailure.unsupported(method) }
            let child = try self.handle(args[0]); let childRemote = try self.remote(child, owner: owner)
            guard childRemote.kind == "view", child != handle else { throw AyuBridgeFailure("invalid_arguments", "Expected a distinct child view") }
            if method == "addView" {
                guard childRemote.fields["parent"] == nil else { throw AyuBridgeFailure("invalid_state", "Child already has a parent") }
                var ancestor: String? = handle
                while let current = ancestor { guard current != child else { throw AyuBridgeFailure("invalid_arguments", "View hierarchy cycle") }; ancestor = self.objects[current]?.fields["parent"]?.string }
                let childCount = self.objects.values.filter { $0.owner == owner && $0.fields["parent"]?.string == handle }.count
                guard childCount < 64 else { throw AyuBridgeFailure("resource_limit", "Too many child views") }
                if Self.isScrollViewClass(remote.className) {
                    guard childCount == 0 else { throw AyuBridgeFailure("invalid_state", "ScrollView accepts only one direct child") }
                }
                if args.count == 2, let index = args[1].integer {
                    guard index >= -1, index == -1 || index <= Int64(childCount) else {
                        throw AyuBridgeFailure("invalid_arguments", "Child insertion index is out of range")
                    }
                    args = [args[0], .null, .integer(index == -1 ? Int64(childCount) : index)]
                } else if args.count == 2 || args.count == 3 {
                    let layoutIndex = args.count == 2 ? 1 : 2
                    let layout = try self.remote(self.handle(args[layoutIndex]), owner: owner)
                    guard layout.kind == "layout" else { throw AyuBridgeFailure("invalid_arguments", "Expected LayoutParams") }
                    let accepted = remote.className == "android.widget.LinearLayout"
                        ? ["android.view.ViewGroup$LayoutParams", "android.widget.LinearLayout$LayoutParams"].contains(layout.className)
                        : ["android.view.ViewGroup$LayoutParams", "android.widget.FrameLayout$LayoutParams"].contains(layout.className)
                    guard accepted else { throw AyuBridgeFailure("invalid_arguments", "LayoutParams do not match the parent") }
                    if args.count == 2 {
                        layoutClassName = layout.className
                        layoutHandle = try self.handle(args[1])
                        args[1] = .object(layout.fields)
                    } else {
                        guard let index = args[1].integer else { throw AyuBridgeFailure("invalid_arguments", "Expected child insertion index") }
                        guard index >= -1, index == -1 || index <= Int64(childCount) else {
                            throw AyuBridgeFailure("invalid_arguments", "Child insertion index is out of range")
                        }
                        layoutClassName = layout.className
                        layoutHandle = try self.handle(args[layoutIndex])
                        args = [args[0], .object(layout.fields), .integer(index == -1 ? Int64(childCount) : index)]
                    }
                }
            } else if childRemote.fields["parent"]?.string != handle { throw AyuBridgeFailure("invalid_state", "View is not a child of this parent") }
        }
        if method == "addTextChangedListener" || method == "removeTextChangedListener" {
            guard ["android.widget.TextView", "android.widget.EditText"].contains(remote.className) else {
                throw AyuBridgeFailure.unsupported(method)
            }
            let listenerHandle = try self.handle(args[0])
            let listener = try self.remote(listenerHandle, owner: owner)
            guard listener.kind == "proxy", listener.className == "android.text.TextWatcher" else {
                throw AyuBridgeFailure.unsupported("TextView TextWatcher reference")
            }
            let watchers = remote.fields["text_watchers"]?.array ?? []
            if method == "addTextChangedListener" {
                guard watchers.count < 8 else { throw AyuBridgeFailure("resource_limit", "Too many TextWatchers") }
                var callbacks: [String: AyuBridgeValue] = [:]
                for callbackMethod in Self.proxyInterfaces["android.text.TextWatcher", default: []] {
                    callbacks[callbackMethod] = .string(try self.callbackID(listener.fields[callbackMethod] ?? .null, owner: owner, method: callbackMethod))
                }
                args = [.object(["listener_handle": .string(listenerHandle), "callbacks": .object(callbacks)])]
            } else {
                guard watchers.contains(.string(listenerHandle)) else {
                    throw AyuBridgeFailure("invalid_state", "TextWatcher is not registered")
                }
                args = [.object(["listener_handle": .string(listenerHandle)])]
            }
        }
        if method == "setOnCheckedChangeListener" {
            if args[0] == .null {
                args = [.null]
            } else {
                let listener = try self.remote(self.handle(args[0]), owner: owner)
                guard listener.kind == "proxy", listener.className == "android.widget.CompoundButton$OnCheckedChangeListener" else {
                    throw AyuBridgeFailure.unsupported("CheckBox.OnCheckedChangeListener reference")
                }
                let callbackID = try self.callbackID(listener.fields["onCheckedChanged"] ?? .null,
                                                     owner: owner, method: "onCheckedChanged")
                args = [.object(["$callback": .string(callbackID)])]
            }
        }
        if method == "setLayoutParams" {
            let layout = try self.remote(self.handle(args[0]), owner: owner)
            guard layout.kind == "layout" else { throw AyuBridgeFailure("invalid_arguments", "Expected LayoutParams") }
            guard ["android.view.ViewGroup$LayoutParams", "android.widget.LinearLayout$LayoutParams", "android.widget.FrameLayout$LayoutParams"].contains(layout.className) else {
                throw AyuBridgeFailure("invalid_arguments", "Unsupported LayoutParams class")
            }
            layoutClassName = layout.className
            layoutHandle = try self.handle(args[0])
            args[0] = .object(layout.fields)
        } else if method == "setBackground" || method == "setBackgroundDrawable" {
            if args[0] == .null {
                nativeMethod = "clearBackground"
                args = []
            } else {
                let drawableHandle = try self.handle(args[0])
                let drawable = try self.remote(drawableHandle, owner: owner)
                guard drawable.kind == "adapter" else { throw AyuBridgeFailure.unsupported("View.setBackground drawable") }
                if drawable.className == "android.graphics.drawable.ColorDrawable", let color = drawable.fields["color"]?.integer {
                    backgroundDrawableHandle = drawableHandle
                    args[0] = .integer(color)
                } else if drawable.className == "android.graphics.drawable.GradientDrawable" {
                    backgroundDrawableHandle = drawableHandle
                    args[0] = .object(drawable.fields)
                    nativeMethod = "setBackgroundStyle"
                } else {
                    throw AyuBridgeFailure.unsupported("View.setBackground drawable")
                }
            }
            if nativeMethod == method { nativeMethod = "setBackgroundColor" }
        } else if method == "addTextChangedListener" || method == "removeTextChangedListener" {
            // The worker validates owner, interface, and callback tokens. UIKit
            // receives only opaque callback IDs and a listener handle.
        } else if method == "setOnClickListener" || method == "setOnTouchListener" {
            if args[0] != .null { args[0] = .object(["$callback": .string(try self.callbackID(args[0], owner: owner, method: method == "setOnClickListener" ? "onClick" : "onTouch"))]) }
        } else if method == "setChecked" {
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected checked boolean") }
        } else if method == "performHapticFeedback" {
            guard let feedback = args[0].integer else {
                throw AyuBridgeFailure("invalid_arguments", "Expected a supported haptic feedback constant")
            }
            guard [0, 4].contains(feedback) else {
                throw AyuBridgeFailure.unsupported("View.performHapticFeedback constant")
            }
        } else if method == "setButtonTintList" {
            if args[0] == .null {
                nativeMethod = "setButtonTintColor"
                args = [.null]
            } else {
                let tint = try self.remote(self.handle(args[0]), owner: owner)
                guard tint.kind == "adapter", tint.className == "android.content.res.ColorStateList",
                      let color = tint.fields["color"]?.integer,
                      (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
                    throw AyuBridgeFailure.unsupported("CheckBox.setButtonTintList ColorStateList")
                }
                nativeMethod = "setButtonTintColor"
                args = [.integer(color)]
            }
        } else if method == "setOnCheckedChangeListener" {
            // The host passes only the declared, revocable listener callback ID to UIKit.
        } else if method == "setText" {
            args[0] = .string(try self.textValue(args[0], owner: owner))
        } else if method == "setHint" {
            args[0] = .string(try self.textValue(args[0], owner: owner))
        } else if method == "setContentDescription" {
            if args[0] != .null { args[0] = .string(try self.textValue(args[0], owner: owner)) }
        } else if method == "setInputType" {
            guard let inputType = args[0].integer else { throw AyuBridgeFailure("invalid_arguments", "Expected EditText input type") }
            if inputType & 0x2_0000 != 0 { throw AyuBridgeFailure.unsupported("EditText multiline input") }
            guard [1, 0x8_0001, 0x81, 0x8_0081].contains(inputType) else {
                throw AyuBridgeFailure.unsupported("EditText input type flags")
            }
        } else if method == "setScaleType" {
            let scaleType = try self.remote(self.handle(args[0]), owner: owner)
            guard scaleType.kind == "adapter", scaleType.className == "android.widget.ImageView$ScaleType",
                  let mode = scaleType.fields["mode"]?.string,
                  ["CENTER", "FIT_XY", "FIT_CENTER", "CENTER_INSIDE", "CENTER_CROP", "MATRIX"].contains(mode) else {
                throw AyuBridgeFailure.unsupported("ImageView.ScaleType")
            }
            args = [.string(mode)]
        } else if method == "setColorFilter" {
            guard Self.isImageViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".setColorFilter")
            }
            if args.count == 2 {
                guard let color = args[0].integer,
                      (Int64(Int32.min)...Int64(UInt32.max)).contains(color) else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid ImageView color filter")
                }
                let mode = try self.remote(self.handle(args[1]), owner: owner)
                guard mode.kind == "adapter", mode.className == "android.graphics.PorterDuff$Mode",
                      mode.fields["value"]?.string == "SRC_IN" else {
                    throw AyuBridgeFailure.unsupported("ImageView.setColorFilter PorterDuff.Mode")
                }
                args = [.integer(color)]
            } else if args[0] == .null {
                nativeMethod = "setColorFilter"
            } else if let color = args[0].integer {
                guard (Int64(Int32.min)...Int64(UInt32.max)).contains(color) else {
                    throw AyuBridgeFailure("invalid_arguments", "Invalid ImageView color filter")
                }
                args[0] = .integer(color)
            } else {
                let filter = try self.remote(self.handle(args[0]), owner: owner)
                guard filter.kind == "adapter", filter.className == "android.graphics.PorterDuffColorFilter",
                      let color = filter.fields["color"]?.integer,
                      (Int64(Int32.min)...Int64(UInt32.max)).contains(color),
                      filter.fields["mode"]?.string == "SRC_IN" else {
                    throw AyuBridgeFailure.unsupported("ImageView.setColorFilter ColorFilter")
                }
                args[0] = .integer(color)
            }
        } else if method == "clearColorFilter" {
            guard Self.isImageViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".clearColorFilter")
            }
            nativeMethod = "setColorFilter"
            args = [.null]
        } else if method == "setTypeface" {
            let style: Int64
            if args.count == 1 {
                style = try self.typefaceStyle(args[0], owner: owner, allowNull: false)
            } else {
                _ = try self.typefaceStyle(args[0], owner: owner, allowNull: true)
                guard let value = args[1].integer, (0...3).contains(value) else {
                    throw AyuBridgeFailure("invalid_arguments", "Unsupported Typeface style")
                }
                style = value
            }
            nativeMethod = "setTypefaceStyle"
            args = [.integer(style)]
        } else if method == "setTextSize" {
            let size: AyuBridgeValue
            if args.count == 1 {
                size = args[0]
                nativeMethod = "setTextSizeSP"
            } else {
                guard let unit = args[0].integer else { throw AyuBridgeFailure("invalid_arguments", "Expected TextView size unit") }
                guard (0...2).contains(unit) else { throw AyuBridgeFailure.unsupported("TextView.setTextSize unit") }
                size = args[1]
                if unit == 0 { nativeMethod = "setTextSizePixels" }
                if unit == 2 { nativeMethod = "setTextSizeSP" }
            }
            guard let value = size.number, value.isFinite, (1...256).contains(value) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid font size")
            }
            args = [size]
        } else if method == "setMaxLines" {
            guard let maximum = args[0].integer, (1...64).contains(maximum) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid maximum line count")
            }
        } else if method == "setMax" {
            guard let maximum = args[0].integer, (0...Int64(Int32.max)).contains(maximum) else {
                throw AyuBridgeFailure("invalid_arguments", "ProgressBar maximum is outside the supported range")
            }
        } else if method == "setProgress" {
            guard let progress = args[0].integer, (0...Int64(Int32.max)).contains(progress) else {
                throw AyuBridgeFailure("invalid_arguments", "ProgressBar value is outside the supported range")
            }
            args[0] = .integer(min(progress, remote.fields["progress_max"]?.integer ?? 100))
        } else if method == "setProgressTintList" {
            nativeMethod = "setProgressTintColor"
            if args[0] == .null {
                args = [.null]
            } else {
                let tint = try self.remote(self.handle(args[0]), owner: owner)
                guard tint.kind == "adapter", tint.className == "android.content.res.ColorStateList",
                      let color = tint.fields["color"]?.integer,
                      (Int64(Int32.min)...Int64(Int32.max)).contains(color) else {
                    throw AyuBridgeFailure.unsupported("ProgressBar.setProgressTintList ColorStateList")
                }
                args = [.integer(color)]
            }
        } else if method == "setEllipsize" {
            let mode = try self.truncateAtMode(args[0], owner: owner)
            args = [mode.map(AyuBridgeValue.string) ?? .null]
        } else if method == "setEnabled" {
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected enabled boolean") }
        } else if method == "setFocusable" || method == "setSelected" {
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected boolean view state") }
        } else if method == "setClickable" {
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected clickable boolean") }
        } else if method == "setElevation" {
            let elevation = try self.number(args[0])
            guard elevation >= 0, elevation <= 100_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid native-point view elevation")
            }
            args[0] = .number(elevation)
        } else if method == "setClipChildren" {
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected clip-children boolean") }
            guard Self.viewGroupClasses.contains(remote.className), !Self.isScrollViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".setClipChildren")
            }
        } else if method == "setMinimumHeight" {
            guard let height = args[0].integer, (0...100_000).contains(height) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid minimum height")
            }
        } else if method == "setMinimumWidth" {
            guard let width = args[0].integer, (0...100_000).contains(width) else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid minimum width")
            }
        } else if method == "setId" {
            guard let identifier = args[0].integer, Int32(exactly: identifier) != nil else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid view ID")
            }
        } else if ["setRotation", "setRotationX", "setRotationY"].contains(method) {
            guard let rotation = args[0].number, rotation.isFinite, abs(rotation) <= 360_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid view rotation")
            }
        } else if ["setPivotX", "setPivotY"].contains(method) {
            guard let pivot = args[0].number, pivot.isFinite, abs(pivot) <= 100_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid view pivot")
            }
        } else if method == "setCameraDistance" {
            guard let distance = args[0].number, distance.isFinite, distance > 0, distance <= 1_000_000 else {
                throw AyuBridgeFailure("invalid_arguments", "Invalid camera distance")
            }
        } else if method == "setTextAlignment" {
            guard let alignment = args[0].integer, (0...6).contains(alignment) else {
                throw AyuBridgeFailure("invalid_arguments", "Unsupported text alignment")
            }
        } else if method == "setSingleLine" {
            guard args[0] == .bool(true) || args[0] == .bool(false) || args[0].number != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected boolean") }
        } else if method == "setMinLines" {
            let lines = try self.number(args[0])
            guard lines >= 0, lines <= 64, lines == lines.rounded() else { throw AyuBridgeFailure("invalid_arguments", "Invalid line count") }
        } else if method == "setGravity" {
            guard let gravity = try? AyuBridgeViewGravity(args[0]) else { throw AyuBridgeFailure("invalid_arguments", "Unsupported gravity value") }
            if remote.className == "android.widget.EditText", ![.unspecified, .center].contains(gravity.vertical) {
                throw AyuBridgeFailure.unsupported("EditText vertical gravity")
            }
            args[0] = .integer(gravity.rawValue)
        } else if method == "setImageBase64" {
            guard let text = args[0].string, text.utf8.count <= 131_072, let data = Data(base64Encoded: text), let cost = self.imageCost(data) else { throw AyuBridgeFailure("invalid_arguments", "Expected a small bounded PNG or JPEG") }
            let otherCost = self.objects.filter { $0.key != handle && $0.value.owner == owner }.values.reduce(0) { $0 + Int($1.fields["image_cost"]?.number ?? 0) }
            guard cost <= self.limits.decodedImageBytesPerPlugin - otherCost else { throw AyuBridgeFailure("resource_limit", "Plugin image memory quota exceeded") }
            self.objects[handle]?.fields["image_cost"] = .integer(Int64(cost))
        } else if method == "setImageDrawable" {
            guard args[0] == .null else {
                throw AyuBridgeFailure.unsupported("ImageView.setImageDrawable Drawable")
            }
            nativeMethod = "clearImage"
            args = []
        } else if method == "setImageResource" {
            guard let resourceID = args[0].integer else {
                throw AyuBridgeFailure("invalid_arguments", "Expected an image resource ID")
            }
            guard Int32(exactly: resourceID) != nil else {
                throw AyuBridgeFailure("invalid_arguments", "Image resource ID is outside the signed 32-bit range")
            }
            guard resourceID == 0 else {
                throw AyuBridgeFailure.unsupported("ImageView.setImageResource resource lookup")
            }
            nativeMethod = "clearImage"
            args = []
        } else if method == "setClipToOutline" {
            guard args[0].bool != nil else {
                throw AyuBridgeFailure("invalid_arguments", "Expected clip-to-outline boolean")
            }
        } else if method == "setFillViewport" {
            guard Self.isScrollViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".setFillViewport")
            }
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected fill-viewport boolean") }
        } else if method == "setVerticalScrollBarEnabled" {
            guard remote.className == "android.widget.ScrollView" else {
                throw AyuBridgeFailure.unsupported("ScrollView.setVerticalScrollBarEnabled")
            }
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected scrollbar boolean") }
        } else if method == "setHorizontalScrollBarEnabled" {
            guard remote.className == "android.widget.HorizontalScrollView" else {
                throw AyuBridgeFailure.unsupported(remote.className + ".setHorizontalScrollBarEnabled")
            }
            guard args[0].bool != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected scrollbar boolean") }
        } else if method == "setClipToPadding" {
            guard Self.isScrollViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".setClipToPadding")
            }
            guard let clip = args[0].bool else { throw AyuBridgeFailure("invalid_arguments", "Expected clip-to-padding boolean") }
            guard clip else { throw AyuBridgeFailure.unsupported("ScrollView.setClipToPadding(false)") }
        } else if method == "setOverScrollMode" {
            guard Self.isScrollViewClass(remote.className) else {
                throw AyuBridgeFailure.unsupported(remote.className + ".setOverScrollMode")
            }
            guard let mode = args[0].integer else {
                throw AyuBridgeFailure("invalid_arguments", "Expected an overscroll mode integer")
            }
            guard mode == 2 else {
                throw AyuBridgeFailure.unsupported("ScrollView.setOverScrollMode; only OVER_SCROLL_NEVER is supported")
            }
            nativeMethod = "setOverScrollNever"
        } else if method == "scrollTo" || method == "scrollBy" || method == "smoothScrollTo" {
            guard Self.isScrollViewClass(remote.className),
                  let horizontal = args[0].integer, let vertical = args[1].integer,
                  Int32(exactly: horizontal) != nil, Int32(exactly: vertical) != nil else {
                throw AyuBridgeFailure.unsupported(remote.className + "." + method + " bounded scroll coordinates")
            }
            if remote.className == "android.widget.ScrollView", horizontal != 0 {
                throw AyuBridgeFailure.unsupported("ScrollView horizontal scrolling")
            }
            if remote.className == "android.widget.HorizontalScrollView", vertical != 0 {
                throw AyuBridgeFailure.unsupported("HorizontalScrollView vertical scrolling")
            }
        } else if method == "setOutlineProvider" {
            if args[0] != .null {
                guard let reference = args[0].object,
                      Set(reference.keys) == ["$handle", "$class"],
                      reference["$class"]?.string == "android.view.ViewOutlineProvider",
                      let providerHandle = reference["$handle"]?.string else {
                    throw AyuBridgeFailure.unsupported("View.setOutlineProvider provider")
                }
                let provider = try self.remote(providerHandle, owner: owner)
                guard provider.kind == "enum", provider.className == "android.view.ViewOutlineProvider",
                      provider.fields["value"]?.string == "BACKGROUND" else {
                    throw AyuBridgeFailure.unsupported("View.setOutlineProvider provider")
                }
            }
            args = [.bool(args[0] != .null)]
        } else if method == "setBackgroundColor" {
            guard let color = args[0].integer,
                  (Int64(Int32.min)...Int64(UInt32.max)).contains(color) else {
                throw AyuBridgeFailure("invalid_arguments", "Expected a signed or unsigned 32-bit ARGB color")
            }
            args[0] = .integer(color)
        } else if method == "animate" {
            guard let properties = args[0].object, !properties.isEmpty, Set(properties.keys).isSubset(of: ["duration_ms", "alpha", "translation_x", "translation_y"]) else { throw AyuBridgeFailure("invalid_arguments", "Unsupported animation property") }
            for (key, value) in properties {
                let number = try self.number(value)
                if key == "duration_ms" && !(0...10_000).contains(number) { throw AyuBridgeFailure("invalid_arguments", "Animation exceeds duration limit") }
                if key == "alpha" && !(0...1).contains(number) { throw AyuBridgeFailure("invalid_arguments", "Invalid alpha") }
            }
        } else if !["addView", "removeView", "removeAllViews", "bringToFront", "unmount", "requestLayout", "invalidate", "setClickable", "setMinimumWidth", "setMinimumHeight", "addTextChangedListener", "removeTextChangedListener", "setColorFilter", "clearColorFilter"].contains(method) {
            let numbers = try args.map(self.number)
            if method == "setVisibility", ![0, 4, 8].contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid visibility") }
            if method == "setOrientation", ![0, 1].contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid orientation") }
            if method == "setAlpha", !(0...1).contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid alpha") }
            if method == "setFrame", numbers[2] < 0 || numbers[3] < 0 { throw AyuBridgeFailure("invalid_arguments", "Negative frame size") }
        }
        return AyuBridgeUI.Command(owner: owner, generation: generation, handle: handle, method: nativeMethod,
            arguments: args, backgroundDrawableHandle: backgroundDrawableHandle, layoutClassName: layoutClassName,
            layoutHandle: layoutHandle)
    }

    private func typefaceStyle(_ value: AyuBridgeValue, owner: String, allowNull: Bool) throws -> Int64 {
        if value == .null {
            guard allowNull else { throw AyuBridgeFailure.unsupported("TextView.setTypeface(null)") }
            return 0
        }
        guard let object = value.object, object.count == 2, object["$handle"]?.string != nil,
              object["$class"]?.string == "android.graphics.Typeface" else {
            throw AyuBridgeFailure.unsupported("TextView.setTypeface Typeface reference")
        }
        let typeface = try self.remote(try self.handle(value), owner: owner)
        guard typeface.kind == "adapter", typeface.className == "android.graphics.Typeface",
              let style = typeface.fields["style"]?.integer, (0...3).contains(style) else {
            throw AyuBridgeFailure.unsupported("TextView.setTypeface Typeface reference")
        }
        return style
    }

    private func truncateAtMode(_ value: AyuBridgeValue, owner: String) throws -> String? {
        guard value != .null else { return nil }
        let className = "android.text.TextUtils$TruncateAt"
        guard value.object?["$class"]?.string == className else {
            throw AyuBridgeFailure.unsupported("TextView.setEllipsize TruncateAt reference")
        }
        let truncated = try self.remote(self.handle(value), owner: owner)
        guard truncated.kind == "adapter", truncated.className == className,
              let mode = truncated.fields["mode"]?.string,
              ["END", "START", "MIDDLE"].contains(mode) else {
            throw AyuBridgeFailure.unsupported("TextView.setEllipsize TruncateAt reference")
        }
        return mode
    }

    /// Re-apply a drawable's latest state to every view still referring to that
    /// owned handle in this plugin generation. UIKit receives bounded commands;
    /// its generation check drops work queued before unload/reload.
    private func backgroundMutationCommands(owner: String, generation: UUID, drawableHandle: String,
                                           className: String, fields: [String: AyuBridgeValue]) -> [AyuBridgeUI.Command] {
        guard self.sessions[owner]?.generation == generation else { return [] }
        let method: String
        let value: AyuBridgeValue
        switch className {
        case "android.graphics.drawable.ColorDrawable":
            guard let color = fields["color"] else { return [] }
            method = "setBackgroundColor"
            value = color
        case "android.graphics.drawable.GradientDrawable":
            method = "setBackgroundStyle"
            value = .object(fields)
        default:
            return []
        }
        return self.objects.compactMap { handle, remote in
            guard remote.owner == owner, remote.kind == "view",
                  remote.fields["background_drawable"]?.string == drawableHandle,
                  remote.fields["background_drawable_generation"]?.string == generation.uuidString else { return nil }
            return AyuBridgeUI.Command(owner: owner, generation: generation, handle: handle,
                method: method, arguments: [value], backgroundDrawableHandle: drawableHandle,
                layoutClassName: nil, layoutHandle: nil)
        }
    }

    private func getField(owner: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue {
        let remote = try self.targetRemote(arguments, owner: owner)
        let name = try self.text(arguments, "name")
        if remote.kind == "class", let value = self.constants(for: remote.className)[name] { return value }
        if remote.kind == "class", let reader = self.classRegistry.adapters[remote.className]?.staticFields[name], let session = self.sessions[owner] {
            return try self.adapterResult(reader(self.adapterContext(owner: owner, generation: session.generation)), owner: owner)
        }
        if remote.kind == "adapter", self.classRegistry.adapters[remote.className]?.readableFields.contains(name) == true { return remote.fields[name] ?? .null }
        if remote.kind == "layout", self.isReadableLayoutField(name, className: remote.className) { return remote.fields[name] ?? .number(0) }
        throw AyuBridgeFailure.unsupported(remote.className + "." + name)
    }

    private func isReadableLayoutField(_ name: String, className: String) -> Bool {
        Self.layoutFields.contains(name) || (className == "android.widget.LinearLayout$LayoutParams" && name == "weight")
    }

    private func enqueueCallback(owner: String, generation: UUID, callbackID: String, arguments: [AyuBridgeValue], token: String? = nil) {
        guard self.callbackGate.reserve(owner: owner, generation: generation, limit: self.limits.callbacksPerPlugin) else {
            if let token { self.worker.async { self.finishTimer(owner: owner, token: token) } }
            return
        }
        self.worker.async {
            guard let session = self.sessions[owner], session.active, session.generation == generation, session.callbackIDs.contains(callbackID) else {
                self.callbackGate.finish(owner: owner); return
            }
            do {
                try self.validateReferences(.array(arguments), owner: owner, registerCallbacks: false)
                guard try JSONEncoder().encode(arguments).count <= self.limits.responseBytes else { throw AyuBridgeFailure("resource_limit", "Callback payload exceeds quota") }
            } catch {
                self.callbackGate.finish(owner: owner)
                if let token { self.finishTimer(owner: owner, token: token) }
                return
            }
            let sink = self.callback
            self.delivery.async {
                defer { self.callbackGate.finish(owner: owner) }
                guard self.callbackGate.enter(owner: owner, generation: generation, token: token) else { return }
                sink(owner, callbackID, arguments)
                if let token { self.worker.async { self.finishTimer(owner: owner, token: token) } }
            }
        }
    }

    private func finishTimer(owner: String, token: String) {
        self.callbackGate.cancel(token: token, owner: owner)
        self.sessions[owner]?.timers.removeValue(forKey: token)
        if let id = self.sessions[owner]?.timerCallbacks.removeValue(forKey: token),
           self.sessions[owner]?.timerCallbacks.values.contains(id) != true,
           self.sessions[owner]?.persistentCallbackIDs.contains(id) != true {
            self.sessions[owner]?.callbackIDs.remove(id)
        }
    }

    /// View and Handler one-shot callbacks share the bounded worker-owned timer
    /// table. The queued main hop retains no adapter context and is harmless
    /// after generation revocation.
    private func prepareScheduledCallback(owner: String, generation: UUID, callbackID: String, delayMilliseconds: Int64) throws -> AyuBridgeProviderResult {
        guard let session = self.sessions[owner], session.active, session.generation == generation,
              session.callbackIDs.contains(callbackID) else {
            throw AyuBridgeFailure("callback_expired", "Callback is unavailable")
        }
        guard (0...60_000).contains(delayMilliseconds), session.timers.count < self.limits.callbacksPerPlugin else {
            throw AyuBridgeFailure("resource_limit", "Pending callback limit exceeded")
        }
        return AyuBridgeProviderResult(.value(.bool(true)), commit: { [weak self] _ in
            self?.scheduleCallback(owner: owner, generation: generation, callbackID: callbackID, delayMilliseconds: delayMilliseconds)
        })
    }

    private func scheduleCallback(owner: String, generation: UUID, callbackID: String, delayMilliseconds: Int64) {
        guard let session = self.sessions[owner], session.active, session.generation == generation,
              session.callbackIDs.contains(callbackID), session.timers.count < self.limits.callbacksPerPlugin else { return }
        let token = UUID().uuidString
        self.callbackGate.register(token: token, owner: owner)
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.sessions[owner]?.generation == generation else { return }
            DispatchQueue.main.async {
                self.enqueueCallback(owner: owner, generation: generation, callbackID: callbackID, arguments: [], token: token)
            }
        }
        self.sessions[owner]?.timers[token] = item
        self.sessions[owner]?.timerCallbacks[token] = callbackID
        if delayMilliseconds == 0 {
            self.worker.async(execute: item)
        } else {
            self.worker.asyncAfter(deadline: .now() + Double(delayMilliseconds) / 1000.0, execute: item)
        }
    }

    private func cleanup(owner: String) {
        self.callbackGate.revoke(owner: owner)
        guard let session = self.sessions.removeValue(forKey: owner) else { return }
        for timer in session.timers.values { timer.cancel() }
        self.objects = self.objects.filter { $0.value.owner != owner }
        self.provider.detach(pluginID: owner)
        DispatchQueue.main.sync { self.ui.remove(owner: owner) }
    }
    private func store(owner: String, className: String, kind: String, fields: [String: AyuBridgeValue] = [:]) throws -> AyuBridgeValue {
        guard self.objects.values.filter({ $0.owner == owner }).count < self.limits.objectsPerPlugin else { throw AyuBridgeFailure("resource_limit", "Remote object quota exceeded") }
        var cachedArrayCost: ArrayCost?
        if kind == "array" {
            guard let component = fields["component"]?.string, let values = fields["values"]?.array else {
                throw AyuBridgeFailure("invalid_state", "Invalid new array state")
            }
            let cost = try self.arrayCost(component: component, values: values)
            try self.validateArrayQuota(owner: owner, replacing: nil, with: cost)
            cachedArrayCost = cost
        }
        let handle = UUID().uuidString
        self.objects[handle] = Remote(owner: owner, className: className, kind: kind, fields: fields,
                                     arrayCost: cachedArrayCost)
        return self.reference(handle, className: className)
    }
    private func reference(_ handle: String, className: String) -> AyuBridgeValue { return .object(["$handle": .string(handle), "$class": .string(className)]) }
    private func remote(_ handle: String, owner: String) throws -> Remote {
        guard let value = self.objects[handle], value.owner == owner else { throw AyuBridgeFailure("invalid_handle", "Unknown handle for this plugin") }
        return value
    }
    private func handle(_ value: AyuBridgeValue) throws -> String {
        guard let handle = value["$handle"].string ?? value.string else { throw AyuBridgeFailure("invalid_arguments", "Expected remote handle") }; return handle
    }
    private func target(_ arguments: [String: AyuBridgeValue]) throws -> String { return try self.handle(arguments["target"] ?? .null) }
    private func targetRemote(_ arguments: [String: AyuBridgeValue], owner: String) throws -> Remote {
        if let name = arguments["target"]?["class_name"].string {
            guard self.knownClass(name) else { throw AyuBridgeFailure.unsupported(name) }
            return Remote(owner: owner, className: name, kind: "class", fields: [:])
        }
        return try self.remote(self.target(arguments), owner: owner)
    }
    private func className(_ arguments: [String: AyuBridgeValue]) throws -> String {
        guard let name = arguments["class_name"]?.string ?? arguments["class"]?.string ?? arguments["name"]?.string else { throw AyuBridgeFailure("invalid_arguments", "Expected class name") }; return name
    }
    private func text(_ arguments: [String: AyuBridgeValue], _ key: String) throws -> String {
        guard let text = arguments[key]?.string, !text.isEmpty else { throw AyuBridgeFailure("invalid_arguments", "Expected " + key) }; return text
    }
    /// Materialize only the documented plain-text view of an owned Java
    /// CharSequence. Android span metadata remains a value model and is not
    /// rendered by UIKit; arbitrary host objects never become text.
    private func textValue(_ value: AyuBridgeValue, owner: String) throws -> String {
        if let text = value.string {
            guard text.utf8.count <= 65_536 else { throw AyuBridgeFailure("resource_limit", "Text input exceeds quota") }
            return text
        }
        guard let handle = value.object?["$handle"]?.string else {
            throw AyuBridgeFailure("invalid_arguments", "Expected bounded text")
        }
        let remote = try self.remote(handle, owner: owner)
        guard remote.kind == "adapter" else { throw AyuBridgeFailure.unsupported("CharSequence value") }
        let text: String?
        switch remote.className {
        case "java.lang.String": text = remote.fields["value"]?.string
        case "android.text.SpannableString", "android.text.SpannableStringBuilder":
            text = remote.fields["text"]?.string
        default: throw AyuBridgeFailure.unsupported("CharSequence " + remote.className)
        }
        guard let text else { throw AyuBridgeFailure("invalid_arguments", "Invalid CharSequence value") }
        guard text.utf8.count <= 65_536 else { throw AyuBridgeFailure("resource_limit", "Text input exceeds quota") }
        return text
    }
    private func number(_ value: AyuBridgeValue) throws -> Double {
        guard let number = value.number, number.isFinite, abs(number) <= 4_294_967_295 else { throw AyuBridgeFailure("invalid_arguments", "Expected finite bounded number") }; return number
    }
    private func callbackID(_ value: AyuBridgeValue, owner: String, method: String) throws -> String {
        let id: String?
        if let direct = value["$callback"].string { id = direct }
        else { let remote = try self.remote(self.handle(value), owner: owner); id = remote.kind == "proxy" ? remote.fields[method]?["$callback"].string : nil }
        guard let id, !id.isEmpty, id.utf8.count <= 128 else { throw AyuBridgeFailure("invalid_arguments", "Expected callback token") }
        guard let session = self.sessions[owner], session.callbackIDs.contains(id) || session.callbackIDs.count < self.limits.callbacksPerPlugin else { throw AyuBridgeFailure("resource_limit", "Callback registry quota exceeded") }
        self.sessions[owner]?.callbackIDs.insert(id)
        return id
    }
    private func validateArrayValue(_ value: AyuBridgeValue, component: String, owner: String) throws {
        switch component {
        case "byte": guard let value = value.integer, (Int64(Int8.min)...Int64(Int8.max)).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Expected int8 array item") }
        case "short": guard let value = value.integer, (Int64(Int16.min)...Int64(Int16.max)).contains(value) else { throw AyuBridgeFailure("invalid_arguments", "Expected int16 array item") }
        case "char": guard let value = value.string, value.utf16.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Expected one UTF-16 array item") }
        case "int": guard let value = value.integer, value >= Int64(Int32.min), value <= Int64(Int32.max) else { throw AyuBridgeFailure("invalid_arguments", "Expected int32 array item") }
        case "long": guard value.integer != nil else { throw AyuBridgeFailure("invalid_arguments", "Expected int64 array item") }
        case "boolean": guard case .bool = value else { throw AyuBridgeFailure("invalid_arguments", "Expected bool array item") }
        case "float", "double": guard let number = value.number, number.isFinite else { throw AyuBridgeFailure("invalid_arguments", "Expected finite array item") }
        default:
            if value == .null { return }
            if value.string != nil {
                guard component == "java.lang.Object" || component == "java.lang.CharSequence" || component == "java.lang.String" else {
                    throw AyuBridgeFailure("invalid_arguments", "Expected owned reference for object array item")
                }
                return
            }
            let remote = try self.remote(self.handle(value), owner: owner)
            let actualClass: String
            switch remote.kind {
            case "class": actualClass = "java.lang.Class"
            case "method": actualClass = "java.lang.reflect.Method"
            default: actualClass = remote.className
            }
            guard self.isAssignable(actualClass, to: component) else {
                throw AyuBridgeFailure("invalid_arguments", "Object array item has an incompatible class")
            }
        }
    }
    private func reflectArray(_ method: String, arguments: [AyuBridgeValue], owner: String) throws -> AyuBridgeValue {
        if method == "newInstance" {
            guard arguments.count == 2, let length = arguments[1].integer, length >= 0 else {
                throw AyuBridgeFailure("invalid_arguments", "Array.newInstance requires a supported component and bounded length")
            }
            guard length <= Int64(self.limits.arrayElementsPerPlugin) else {
                throw AyuBridgeFailure("resource_limit", "Array element quota exceeded")
            }
            let component: String
            if let className = arguments[0].object?["$java_class"]?.string {
                component = className
            } else if let handle = arguments[0].object?["$handle"]?.string {
                let remote = try self.remote(handle, owner: owner)
                guard remote.kind == "class" else { throw AyuBridgeFailure("invalid_arguments", "Array component must be a declared class") }
                component = remote.className
            } else {
                throw AyuBridgeFailure("invalid_arguments", "Array component must be a declared class")
            }
            guard component != "void", !component.hasPrefix("["), self.knownClass(component) else {
                throw AyuBridgeFailure.unsupported("Array component type")
            }
            let defaultValue: AyuBridgeValue
            switch component {
            case "byte", "short", "int", "long": defaultValue = .integer(0)
            case "float", "double": defaultValue = .number(0)
            case "char": defaultValue = .string("\0")
            case "boolean": defaultValue = .bool(false)
            default: defaultValue = .null
            }
            let values = Array(repeating: defaultValue, count: Int(length))
            let arrayClass = Self.arrayClasses[component] ?? "[L" + component + ";"
            return try self.store(owner: owner, className: arrayClass, kind: "array", fields: [
                "component": .string(component), "values": .array(values),
            ])
        }

        guard !arguments.isEmpty, let handle = arguments[0].object?["$handle"]?.string else {
            throw AyuBridgeFailure("invalid_arguments", "Array operation requires an owned array")
        }
        let remote = try self.remote(handle, owner: owner)
        guard remote.kind == "array", let component = remote.fields["component"]?.string,
              let values = remote.fields["values"]?.array else {
            throw AyuBridgeFailure.unsupported("Array operation target")
        }
        if method == "getLength" {
            try AyuBridgeJavaValues.arity(arguments, 1)
            return .integer(Int64(values.count))
        }

        let typedComponents: [String: String] = [
            "getBoolean": "boolean", "getByte": "byte", "getChar": "char", "getShort": "short",
            "getInt": "int", "getLong": "long", "getFloat": "float", "getDouble": "double",
            "setBoolean": "boolean", "setByte": "byte", "setChar": "char", "setShort": "short",
            "setInt": "int", "setLong": "long", "setFloat": "float", "setDouble": "double",
        ]
        let isSet = method == "set" || method.hasPrefix("set")
        guard method == "get" || method == "set" || typedComponents[method] != nil else {
            throw AyuBridgeFailure.unsupported("java.lang.reflect.Array." + method)
        }
        try AyuBridgeJavaValues.arity(arguments, isSet ? 3 : 2)
        guard let index = arguments[1].integer, index >= 0, index < Int64(values.count) else {
            throw AyuBridgeFailure("invalid_arguments", "Array index out of range")
        }
        if let expectedComponent = typedComponents[method], expectedComponent != component {
            throw AyuBridgeFailure("invalid_arguments", "Typed array operation requires a matching primitive array")
        }
        if !isSet { return values[Int(index)] }

        let value = arguments[2]
        try self.validateArrayValue(value, component: component, owner: owner)
        var updatedValues = values
        updatedValues[Int(index)] = value
        let cost = try self.replacingArrayElement(owner: owner, handle: handle,
            oldValue: values[Int(index)], with: value)
        var updatedRemote = remote
        updatedRemote.fields["values"] = .array(updatedValues)
        updatedRemote.arrayCost = cost
        self.objects[handle] = updatedRemote
        return .null
    }
    private func arrayCost(component: String, values: [AyuBridgeValue]) throws -> ArrayCost {
        let state = AyuBridgeValue.object(["component": .string(component), "values": .array(values)])
        return ArrayCost(elements: values.count, encodedBytes: try JSONEncoder().encode(state).count)
    }
    private func validateArrayQuota(owner: String, replacing handle: String?, with replacement: ArrayCost) throws {
        var totalElements = 0
        var totalBytes = 0
        for (candidateHandle, remote) in self.objects where remote.owner == owner && remote.kind == "array" && candidateHandle != handle {
            guard let cost = remote.arrayCost,
                  totalElements <= self.limits.arrayElementsPerPlugin,
                  cost.elements <= self.limits.arrayElementsPerPlugin - totalElements,
                  totalBytes <= self.limits.arrayBytesPerPlugin,
                  cost.encodedBytes <= self.limits.arrayBytesPerPlugin - totalBytes else {
                throw AyuBridgeFailure("invalid_state", "Invalid owned array state")
            }
            totalElements += cost.elements
            totalBytes += cost.encodedBytes
        }
        guard totalElements <= self.limits.arrayElementsPerPlugin,
              replacement.elements <= self.limits.arrayElementsPerPlugin - totalElements else {
            throw AyuBridgeFailure("resource_limit", "Owned array element quota exceeded")
        }
        guard totalBytes <= self.limits.arrayBytesPerPlugin,
              replacement.encodedBytes <= self.limits.arrayBytesPerPlugin - totalBytes else {
            throw AyuBridgeFailure("resource_limit", "Owned array byte quota exceeded")
        }
    }
    private func replacingArrayElement(owner: String, handle: String, oldValue: AyuBridgeValue,
                                       with newValue: AyuBridgeValue) throws -> ArrayCost {
        guard let remote = self.objects[handle], remote.owner == owner,
              remote.kind == "array", let previous = remote.arrayCost else {
            throw AyuBridgeFailure("invalid_state", "Invalid owned array state")
        }
        let encoder = JSONEncoder()
        let oldBytes = try encoder.encode(oldValue).count
        let newBytes = try encoder.encode(newValue).count
        let (withoutOldValue, subtractionOverflow) = previous.encodedBytes.subtractingReportingOverflow(oldBytes)
        let (updatedBytes, additionOverflow) = withoutOldValue.addingReportingOverflow(newBytes)
        guard !subtractionOverflow, !additionOverflow, updatedBytes >= 0 else {
            throw AyuBridgeFailure("invalid_state", "Invalid owned array byte count")
        }
        let updatedCost = ArrayCost(elements: previous.elements, encodedBytes: updatedBytes)
        try self.validateArrayQuota(owner: owner, replacing: handle, with: updatedCost)
        return updatedCost
    }
    private func validateReferences(_ value: AyuBridgeValue, owner: String, depth: Int = 0, registerCallbacks: Bool = true) throws {
        guard depth < 32 else { throw AyuBridgeFailure("resource_limit", "JSON nesting limit exceeded") }
        if case let .number(number) = value, !number.isFinite { throw AyuBridgeFailure("invalid_arguments", "Non-finite bridge value") }
        if let values = value.object {
            if let handle = values["$handle"]?.string {
                let remote = try self.remote(handle, owner: owner)
                guard values.count == 2, values["$class"]?.string == remote.className else { throw AyuBridgeFailure("invalid_arguments", "Malformed remote reference") }
            } else if values["$callback"] != nil {
                guard values.count == 1 else { throw AyuBridgeFailure("invalid_arguments", "Malformed callback reference") }
                if registerCallbacks { _ = try self.callbackID(value, owner: owner, method: "") }
                else {
                    guard let id = values["$callback"]?.string, self.sessions[owner]?.callbackIDs.contains(id) == true else {
                        throw AyuBridgeFailure("invalid_arguments", "Adapter cannot create callback tokens")
                    }
                }
            } else if let name = values["$java_class"]?.string {
                guard values.count == 1, self.knownClass(name) else { throw AyuBridgeFailure.unsupported("class reference") }
            } else if values.keys.contains(where: { $0.hasPrefix("$") }) { throw AyuBridgeFailure("invalid_arguments", "Unknown reserved wire tag") }
            for item in values.values { try self.validateReferences(item, owner: owner, depth: depth + 1, registerCallbacks: registerCallbacks) }
        } else if let values = value.array { for item in values { try self.validateReferences(item, owner: owner, depth: depth + 1, registerCallbacks: registerCallbacks) } }
    }
    private func validatePersistentValue(_ value: AyuBridgeValue) throws {
        if let object = value.object {
            guard !object.keys.contains(where: { $0.hasPrefix("$") }) else { throw AyuBridgeFailure("invalid_arguments", "Settings cannot persist remote handles or callbacks") }
            for child in object.values { try self.validatePersistentValue(child) }
        } else if let values = value.array { for child in values { try self.validatePersistentValue(child) } }
    }
    private func isAssignable(_ actual: String, to requested: String) -> Bool {
        if actual == requested || requested == "java.lang.Object" { return true }
        if requested == "android.view.View" { return Self.viewClasses.contains(actual) }
        if requested == "android.widget.ImageView" { return Self.isImageViewClass(actual) }
        if requested == "android.view.ViewGroup" || requested == "android.view.ViewParent" { return Self.viewGroupClasses.contains(actual) }
        if requested == "android.widget.TextView" {
            return ["android.widget.TextView", "android.widget.EditText", "android.widget.CheckBox"].contains(actual)
        }
        if requested == "android.widget.CompoundButton" {
            return actual == "android.widget.CheckBox"
        }
        if requested == "java.lang.CharSequence" {
            return ["java.lang.String", "android.text.SpannableString", "android.text.SpannableStringBuilder"].contains(actual)
        }
        if requested == "android.text.Spanned" {
            return ["android.text.SpannableString", "android.text.SpannableStringBuilder"].contains(actual)
        }
        if requested == "android.text.style.CharacterStyle" || requested == "android.text.style.UpdateAppearance" {
            return Self.characterSpanClassNames.contains(actual)
        }
        if requested == "android.text.style.MetricAffectingSpan" || requested == "android.text.style.UpdateLayout" {
            return Self.metricAffectingSpanClassNames.contains(actual)
        }
        return false
    }
    private func knownClass(_ name: String) -> Bool {
        if Self.classes[name] != nil || self.classRegistry.adapters[name] != nil { return true }
        guard let component = Self.arrayComponentName(for: name) else { return false }
        return self.knownClass(component)
    }
    private func staticMethods(for name: String) -> Set<String> {
        let adapterMethods = Set(self.classRegistry.adapters[name]?.staticMethods.keys.map { $0 } ?? [])
        if name == "java.lang.Class" { return adapterMethods.union(Self.classFactoryMethods) }
        if name == "android.text.TextUtils" { return adapterMethods.union(["isEmpty"]) }
        if name == "java.lang.reflect.Array" { return adapterMethods.union(Self.arrayMethods) }
        return adapterMethods
    }
    private func constants(for name: String) -> [String: AyuBridgeValue] { self.classRegistry.adapters[name]?.constants ?? Self.classes[name] ?? [:] }
    private func methods(for name: String) -> Set<String> {
        if let adapter = self.classRegistry.adapters[name] { return Set(adapter.methods.keys).union(["getClass"]) }
        return Self.methods(for: name)
    }
    private func adapterContext(owner: String, generation: UUID) -> AyuBridgeAdapterContext {
        AyuBridgeAdapterContext(pluginID: owner, resolveCallback: { [weak self] reference in
            guard let self, DispatchQueue.getSpecific(key: self.workerKey) == true else { throw AyuBridgeFailure("wrong_queue", "Callback resolution is worker-only") }
            guard self.sessions[owner]?.generation == generation else { throw AyuBridgeFailure("callback_expired", "Callback context generation expired") }
            try self.validateReferences(reference, owner: owner, registerCallbacks: false)
            let id: String
            if let direct = reference["$callback"].string {
                id = direct
            } else {
                let handle = try self.handle(reference)
                let remote = try self.remote(handle, owner: owner)
                guard remote.kind == "proxy", remote.className == "java.lang.Runnable",
                      let run = remote.fields["run"], let proxyCallback = run["$callback"].string else {
                    throw AyuBridgeFailure("invalid_arguments", "Expected a declared callback reference")
                }
                id = proxyCallback
            }
            guard self.sessions[owner]?.callbackIDs.contains(id) == true else {
                throw AyuBridgeFailure("invalid_arguments", "Expected a declared callback reference")
            }
            return AyuBridgeNativeCallback(id: id) { [weak self] arguments in
                self?.enqueueCallback(owner: owner, generation: generation, callbackID: id, arguments: arguments)
            }
        }, resolve: { [weak self] reference in
            guard let self, DispatchQueue.getSpecific(key: self.workerKey) == true else { throw AyuBridgeFailure("wrong_queue", "Adapter context is worker-only") }
            guard self.sessions[owner]?.generation == generation else { throw AyuBridgeFailure("invalid_handle", "Adapter context generation expired") }
            try self.validateReferences(reference, owner: owner, registerCallbacks: false)
            guard reference.object?["$handle"]?.string != nil else { throw AyuBridgeFailure("invalid_arguments", "Snapshot requires a typed owned reference") }
            let remote = try self.remote(self.handle(reference), owner: owner)
            guard remote.kind == "adapter" || remote.kind == "array" || remote.kind == "proxy" || remote.kind == "view" || remote.kind == "layout" else {
                throw AyuBridgeFailure.unsupported("adapter state for " + remote.className)
            }
            return AyuBridgeAdapterSnapshot(className: remote.className, state: remote.fields)
        }, schedule: { [weak self] callback, delayMilliseconds in
            guard let self, DispatchQueue.getSpecific(key: self.workerKey) == true else { throw AyuBridgeFailure("wrong_queue", "Callback scheduling is worker-only") }
            return try self.prepareScheduledCallback(owner: owner, generation: generation, callbackID: callback.id, delayMilliseconds: delayMilliseconds)
        }, readAnimationPreference: {
            DispatchQueue.main.sync { !UIAccessibility.isReduceMotionEnabled }
        })
    }
    private func validateAdapterState(_ fields: [String: AyuBridgeValue], className: String, owner: String, replacing: String? = nil) throws {
        guard let adapter = self.classRegistry.adapters[className] else { throw AyuBridgeFailure.unsupported("adapter state class") }
        try self.validateReferences(.object(fields), owner: owner, registerCallbacks: false)
        try adapter.validateState(fields)
        let size = try JSONEncoder().encode(fields).count
        let other = try self.objects.filter { $0.key != replacing && $0.value.owner == owner && $0.value.kind == "adapter" }.values.reduce(0) { size, remote in
            size + (try JSONEncoder().encode(remote.fields).count)
        }
        guard size <= self.limits.adapterStateBytesPerPlugin, other <= self.limits.adapterStateBytesPerPlugin - size else {
            throw AyuBridgeFailure("resource_limit", "Owned adapter state quota exceeded")
        }
    }
    private func adapterResult(_ result: AyuBridgeAdapterResult, owner: String) throws -> AyuBridgeValue {
        switch result {
        case let .prepared(prepared):
            do {
                let value = try self.adapterResult(prepared.result, owner: owner)
                prepared.commit(value); return value
            } catch { prepared.rollback(); throw error }
        case let .value(value):
            try self.validateReferences(value, owner: owner, registerCallbacks: false)
            try self.validateAdapterResponse(value); return value
        case let .instance(className, fields):
            guard self.classRegistry.adapters[className] != nil else { throw AyuBridgeFailure.unsupported("adapter result class") }
            try self.validateAdapterState(fields, className: className, owner: owner)
            try self.validateAdapterResponse(self.reference(String(repeating: "0", count: 36), className: className))
            return try self.store(owner: owner, className: className, kind: "adapter", fields: fields)
        }
    }

    /// A prepared result has not reached `adapterResult` when enclosing state
    /// validation fails. Roll back every nested reservation exactly once in
    /// that pre-commit path; `adapterResult` owns rollback after it starts.
    private func rollbackPreparedResult(_ result: AyuBridgeAdapterResult) {
        guard case let .prepared(prepared) = result else { return }
        prepared.rollback()
        self.rollbackPreparedResult(prepared.result)
    }

    private func validateAdapterResponse(_ value: AyuBridgeValue) throws {
        // Reserve the largest request id; never commit an unencodable mutation.
        let response = AyuBridgeResponse(id: .string(String(repeating: "9", count: 128)), result: value, error: nil)
        guard try JSONEncoder().encode(response).count <= self.limits.responseBytes else {
            throw AyuBridgeFailure("resource_limit", "Adapter response exceeds quota")
        }
    }
    private func validateJavaArguments(_ arguments: [String: AyuBridgeValue]) throws {
        if let args = arguments["args"], args.array == nil { throw AyuBridgeFailure("invalid_arguments", "Java arguments must be an array") }
        if let kwargs = arguments["kwargs"] {
            guard let values = kwargs.object else { throw AyuBridgeFailure("invalid_arguments", "Java keyword arguments must be an object") }
            guard values.isEmpty else { throw AyuBridgeFailure.unsupported("Java keyword arguments") }
        }
    }

    private func settingsKey(_ owner: String) -> String { return "AyuPluginBridge.v1." + owner }
    private func notifySettingsChanged(owner: String) {
        guard let generation = self.sessions[owner]?.sdkGeneration else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.settingsDidChange, object: self,
                userInfo: ["pluginID": owner, "generation": generation])
        }
    }
    private func settings(_ owner: String) throws -> [String: AyuBridgeValue] {
        guard let data = self.defaults.data(forKey: self.settingsKey(owner)) else { return [:] }
        guard data.count <= self.limits.settingsBytesPerPlugin else { throw AyuBridgeFailure("resource_limit", "Saved settings exceed quota") }
        return try JSONDecoder().decode([String: AyuBridgeValue].self, from: data)
    }
    private func validID(_ value: String) -> Bool {
        guard (2...64).contains(value.utf8.count), let first = value.utf8.first, (65...90).contains(first) || (97...122).contains(first) else { return false }
        return value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }
    private func encode(id: AyuBridgeValue, result: AyuBridgeValue? = nil, error: AyuBridgeFailure? = nil) -> String {
        let response = AyuBridgeResponse(id: id, result: result, error: error)
        if let data = try? JSONEncoder().encode(response), data.count <= self.limits.responseBytes, let text = String(data: data, encoding: .utf8) { return text }
        let fallback = AyuBridgeResponse(id: id, result: nil, error: AyuBridgeFailure("resource_limit", "Response cannot be encoded within quota"))
        return String(data: (try? JSONEncoder().encode(fallback)) ?? Data(), encoding: .utf8) ?? "{}"
    }
    // Decode only bounded image headers here. UIKit decoding still occurs on main.
    private func imageCost(_ data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source), type == "public.png" as CFString || type == "public.jpeg" as CFString,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber, let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        guard width.intValue > 0 && height.intValue > 0 && width.intValue <= 1024 && height.intValue <= 1024 else { return nil }
        return width.intValue * height.intValue * 4
    }

    private let operations = ["runtime.capabilities", "plugin.authorize", "plugin.activate", "plugin.deactivate", "settings.get", "settings.set", "settings.all", "settings.replace", "state.get", "state.set", "log.write", "java.member", "java.construct", "java.invoke", "java.get_field", "java.set_field", "java.get_private_field", "java.set_private_field", "java.array", "java.length", "java.get_item", "java.set_item", "java.cast", "java.proxy", "java.release", "scheduler.schedule", "scheduler.cancel", "ui.mount", "ui.transaction", "ui.animate", "host.metrics"]
    private static let modules = [
        "base_plugin", "client_utils", "android_utils", "hook_utils", "java", "jarray", "tlrpc",
        "ui", "ui.settings", "ui.alert", "ui.bulletin", "plugin_settings", "requests", "requests.exceptions", "zwylib",
        "log_utils", "markdown_utils", "file_utils", "intents", "extera_utils", "extera_utils.classes",
        "extera_utils.lifecycle", "extera_utils.text_formatting", "extera_utils.get_caller", "extera_utils.metadata_parser",
    ]
    private static let proxyInterfaces: [String: [String]] = ["java.lang.Runnable": ["run"], "android.view.View$OnClickListener": ["onClick"], "android.view.View$OnTouchListener": ["onTouch"], "android.text.TextWatcher": ["beforeTextChanged", "onTextChanged", "afterTextChanged"], "android.widget.CompoundButton$OnCheckedChangeListener": ["onCheckedChanged"], "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate": ["didReceivedNotification"]]
    private static let arrayClasses = ["byte": "[B", "short": "[S", "char": "[C", "int": "[I", "long": "[J", "float": "[F", "double": "[D", "boolean": "[Z"]
    private static let arrayComponentNames = ["[B": "byte", "[S": "short", "[C": "char", "[I": "int",
        "[J": "long", "[F": "float", "[D": "double", "[Z": "boolean"]
    private static let characterSpanClassNames: Set<String> = ["android.text.style.StyleSpan", "android.text.style.UnderlineSpan",
        "android.text.style.StrikethroughSpan", "android.text.style.TypefaceSpan", "android.text.style.ForegroundColorSpan"]
    private static let metricAffectingSpanClassNames: Set<String> = ["android.text.style.StyleSpan", "android.text.style.TypefaceSpan"]
    private static let primitiveClassNames: Set<String> = ["byte", "short", "char", "int", "long", "float", "double", "boolean", "void"]
    private static let interfaceClassNames: Set<String> = Set(Self.proxyInterfaces.keys).union([
        "java.lang.CharSequence", "android.text.Spanned", "android.view.ViewParent", "android.text.style.UpdateAppearance", "android.text.style.UpdateLayout",
    ])
    private static let enumClassNames: Set<String> = [
        "android.graphics.Paint$Cap", "android.graphics.Paint$Join", "android.graphics.Paint$Style",
        "android.graphics.PorterDuff$Mode", "android.text.TextUtils$TruncateAt", "android.widget.ImageView$ScaleType",
        "android.view.ViewOutlineProvider",
    ]
    static var primitiveArrayClassNames: Set<String> { Set(self.arrayClasses.values) }
    private static let schedulerQueues: Set<String> = ["main", "pluginsQueue", "globalQueue", "stageQueue", "cacheClearQueue", "searchQueue", "phoneBookQueue", "themeQueue", "externalNetworkQueue"]
    static var reservedClassNames: Set<String> { Set(self.classes.keys) }
    private static let reflectionMethods: Set<String> = ["getName", "getSimpleName", "getPackageName", "isPrimitive", "isArray", "isInterface", "isEnum", "getComponentType", "getDeclaredMethod", "getDeclaredMethods"]
    private static let classFactoryMethods: Set<String> = ["forName"]
    private static let arrayMethods: Set<String> = ["newInstance", "getLength", "get", "set", "getBoolean", "getByte", "getChar", "getShort", "getInt", "getLong", "getFloat", "getDouble", "setBoolean", "setByte", "setChar", "setShort", "setInt", "setLong", "setFloat", "setDouble"]
    private func capabilities() -> AyuBridgeValue {
        return .object([
            "operations": .array(Array(Set(self.operations + self.provider.capabilities)).sorted().map(AyuBridgeValue.string)),
            "classes": .array((Array(Self.classes.keys) + Array(self.classRegistry.adapters.keys)).sorted().map(AyuBridgeValue.string)),
            "modules": .array(Self.modules.map(AyuBridgeValue.string)),
            "proxy_interfaces": .object(Self.proxyInterfaces.mapValues { .array($0.map(AyuBridgeValue.string)) })
        ])
    }

    /// Inspector inventory generated from the same native registry. Runtime embedding provenance
    /// and Python symbol inventory are intentionally left to the embedding/SDK modules.
    public func compatibilityManifestJSON() -> String {
        let implementation = "submodules/AyuPluginBridge/Sources/AyuPluginNativeHost.swift"
        var classes: [String: AyuBridgeValue] = [:]
        for name in (Array(Self.classes.keys) + Array(self.classRegistry.adapters.keys)).sorted() {
            let classImplementation = self.classRegistry.adapters[name] != nil ? "submodules/AyuPluginBridge/Sources/AyuBridgeClassRegistry.swift" : implementation
            var members: [String: AyuBridgeValue] = [:]
            for method in self.methods(for: name).union(self.staticMethods(for: name)).sorted() {
                members[method] = .object(["status": .string("partial"), "implementation": .string(classImplementation)])
            }
            for constant in self.constants(for: name).keys {
                members[constant] = .object(["status": .string("supported"), "implementation": .string(classImplementation)])
            }
            for field in self.classRegistry.adapters[name]?.readableFields ?? [] {
                members[field] = .object(["status": .string("partial"), "implementation": .string(classImplementation)])
            }
            for field in self.classRegistry.adapters[name]?.staticFields.keys.map({ $0 }) ?? [] {
                members[field] = .object(["status": .string("partial"), "implementation": .string(classImplementation)])
            }
            if name == "android.view.ViewOutlineProvider" {
                members["BACKGROUND"] = .object(["status": .string("supported"), "implementation": .string(implementation)])
            }
            classes[name] = .object(["status": .string("partial"), "implementation": .string(classImplementation), "members": .object(members)])
        }
        let manifest: AyuBridgeValue = .object([
            "schema_version": .integer(1),
            "python": .object(["version": .null, "implementation": .null, "stdlib": .array([])]),
            "modules": .object([:]), "dependencies": .object([:]),
            "java_classes": .object(classes),
            "features": .object([
                "reflection": .object(["status": .string("partial"), "implementation": .string(implementation)]),
                "dynamic_proxy": .object(["status": .string("partial"), "implementation": .string(implementation)]),
                "method_hooks": .object(["status": .string("unsupported")]),
                "native_ffi": .object(["status": .string("unsupported")])
            ])
        ])
        return String(data: (try? JSONEncoder().encode(manifest)) ?? Data(), encoding: .utf8) ?? "{}"
    }

    private static let viewClasses: Set<String> = ["android.view.View", "android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.TextView", "android.widget.ImageView", "android.widget.ImageButton", "android.widget.EditText", "android.widget.ScrollView", "android.widget.HorizontalScrollView", "android.widget.ProgressBar", "android.widget.CheckBox"]
    private static let viewGroupClasses: Set<String> = ["android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.ScrollView", "android.widget.HorizontalScrollView"]
    private static let backgroundDrawableClasses: Set<String> = ["android.graphics.drawable.ColorDrawable", "android.graphics.drawable.GradientDrawable"]
    private static let layoutFields: Set<String> = ["width", "height", "x", "y"]
    private static let classes: [String: [String: AyuBridgeValue]] = [
        "android.view.View": ["VISIBLE": .number(0), "INVISIBLE": .number(4), "GONE": .number(8)],
        "android.view.ViewOutlineProvider": [:],
        "android.view.HapticFeedbackConstants": ["LONG_PRESS": .integer(0), "CLOCK_TICK": .integer(4)],
        "android.view.Gravity": [
            "NO_GRAVITY": .integer(0), "CENTER_HORIZONTAL": .integer(1), "LEFT": .integer(3), "RIGHT": .integer(5),
            "CENTER_VERTICAL": .integer(16), "TOP": .integer(48), "BOTTOM": .integer(80), "CENTER": .integer(17),
            "START": .integer(8_388_611), "END": .integer(8_388_613),
        ],
        "android.view.ViewGroup": [:], "android.view.ViewParent": [:],
        "android.view.ViewGroup$LayoutParams": ["MATCH_PARENT": .number(-1), "WRAP_CONTENT": .number(-2)],
        "android.widget.FrameLayout": [:], "android.widget.LinearLayout": ["HORIZONTAL": .number(0), "VERTICAL": .number(1)],
        "android.widget.TextView": [:], "android.widget.ImageView": [:], "android.widget.ImageButton": [:], "android.widget.EditText": [:], "android.widget.ScrollView": [:], "android.widget.HorizontalScrollView": [:], "android.widget.ProgressBar": [:], "android.widget.CheckBox": [:], "android.widget.CompoundButton": [:], "android.widget.CompoundButton$OnCheckedChangeListener": [:],
        "android.view.ViewPropertyAnimator": [:], "android.animation.ValueAnimator": [:],
        "android.view.animation.LinearInterpolator": [:], "android.view.animation.DecelerateInterpolator": [:], "android.view.animation.OvershootInterpolator": [:],
        "android.text.TextUtils": [:], "android.text.TextWatcher": [:],
        "android.text.InputType": ["TYPE_CLASS_TEXT": .integer(1), "TYPE_TEXT_VARIATION_PASSWORD": .integer(0x80), "TYPE_TEXT_FLAG_MULTI_LINE": .integer(0x2_0000), "TYPE_TEXT_FLAG_NO_SUGGESTIONS": .integer(0x8_0000)],
        "android.widget.FrameLayout$LayoutParams": ["MATCH_PARENT": .number(-1), "WRAP_CONTENT": .number(-2)],
        "android.widget.LinearLayout$LayoutParams": ["MATCH_PARENT": .number(-1), "WRAP_CONTENT": .number(-2)],
        "java.lang.Class": [:], "java.lang.reflect.Method": [:], "java.lang.reflect.Array": [:], "[B": [:], "[S": [:], "[C": [:], "[I": [:], "[J": [:], "[F": [:], "[D": [:], "[Z": [:],
        "java.lang.Runnable": [:], "android.view.View$OnClickListener": [:], "android.view.View$OnTouchListener": [:]
    ]
    private static let scrollReadMethods: Set<String> = ["getScrollX", "getScrollY", "isFillViewport"]
    private static let progressReadMethods: Set<String> = ["getMax", "getProgress"]
    private static let scrollWriteMethods: [String: Int] = ["setFillViewport": 1, "setVerticalScrollBarEnabled": 1, "setHorizontalScrollBarEnabled": 1,
        "setClipToPadding": 1, "setOverScrollMode": 1, "scrollTo": 2, "scrollBy": 2, "smoothScrollTo": 2]
    private static let otherWriteMethods: [String: Int] = ["setBackgroundDrawable": 1, "setMax": 1, "setProgress": 1, "setProgressTintList": 1, "setChecked": 1, "setButtonTintList": 1, "setOnCheckedChangeListener": 1]
    /// Commands accepted by `AyuBridgeUI.apply`. Keep transaction input narrower
    /// than the general View method registry: direct-only methods such as
    /// requestFocus, setSelection, findViewById, post/postDelayed and setTag
    /// must never reach the UI command applier's fail-closed default branch.
    private static let transactionCommandMethods: Set<String> = [
        "setAlpha", "setTranslationX", "setTranslationY", "setRotation", "setRotationX", "setRotationY",
        "setPivotX", "setPivotY", "setCameraDistance", "setScaleX", "setScaleY", "setVisibility", "setId",
        "setEnabled", "setClickable", "setFocusable", "setSelected", "setMinimumWidth", "setMinimumHeight",
        "setElevation", "setClipChildren", "setClipToOutline", "setOutlineProvider", "requestLayout", "invalidate",
        "clearFocus", "setBackgroundColor", "setBackground", "setBackgroundDrawable", "setFillViewport",
        "setVerticalScrollBarEnabled", "setHorizontalScrollBarEnabled", "setClipToPadding", "setOverScrollMode",
        "scrollTo", "scrollBy", "smoothScrollTo", "setMax", "setProgress", "setProgressTintList", "setChecked",
        "setButtonTintList", "setOnCheckedChangeListener", "setText", "setContentDescription", "setTextColor",
        "setTextSize", "setTypeface", "setInputType", "setScaleType", "setHint", "setHintTextColor",
        "setSingleLine", "setMinLines", "setMaxLines", "setEllipsize", "setTextAlignment", "setGravity",
        "setOrientation", "setPadding", "setLayoutParams", "setFrame", "addView", "removeView", "removeAllViews",
        "bringToFront", "setOnClickListener", "setOnTouchListener", "addTextChangedListener", "removeTextChangedListener",
        "setImageBase64", "setImageDrawable", "setImageResource", "setColorFilter", "clearColorFilter", "unmount", "animate",
    ]
    private static let readMethods: Set<String> = ["getWidth", "getHeight", "getMeasuredWidth", "getMeasuredHeight", "getX", "getY", "getId", "getMinimumWidth", "getMinimumHeight", "getElevation", "getAlpha", "getRotation", "getRotationX", "getRotationY", "getPivotX", "getPivotY", "getCameraDistance", "getScaleX", "getScaleY", "getTranslationX", "getTranslationY", "getVisibility", "getOrientation", "getGravity", "getClipChildren", "getClipToOutline", "getOutlineProvider", "getBackground", "getContext", "getResources", "isEnabled", "isClickable", "isFocusable", "isSelected", "isShown", "hasFocus", "getSelectionStart", "getSelectionEnd", "getColorFilter", "isAttachedToWindow", "getText", "getContentDescription", "getPaddingLeft", "getPaddingTop", "getPaddingRight", "getPaddingBottom", "getParent", "getRootView", "getTag", "getChildCount", "getChildAt", "getLayoutParams"]
    private static let writeMethods: [String: Int] = ["setAlpha": 1, "setTranslationX": 1, "setTranslationY": 1, "setRotation": 1, "setRotationX": 1, "setRotationY": 1, "setPivotX": 1, "setPivotY": 1, "setCameraDistance": 1, "setScaleX": 1, "setScaleY": 1, "setVisibility": 1, "setId": 1, "findViewById": 1, "setTag": 1, "setEnabled": 1, "setClickable": 1, "setFocusable": 1, "setSelected": 1, "setMinimumWidth": 1, "setMinimumHeight": 1, "setElevation": 1, "setClipChildren": 1, "setClipToOutline": 1, "setOutlineProvider": 1, "requestLayout": 0, "invalidate": 0, "post": 1, "postDelayed": 2, "performHapticFeedback": 1, "setBackgroundColor": 1, "setBackground": 1, "setText": 1, "setTextColor": 1, "setTextSize": 1, "setTypeface": 1, "setMaxLines": 1, "setEllipsize": 1, "setTextAlignment": 1, "setHint": 1, "setHintTextColor": 1, "setInputType": 1, "setScaleType": 1, "setSingleLine": 1, "setMinLines": 1, "setSelection": 1, "setColorFilter": 1, "clearColorFilter": 0, "setGravity": 1, "setOrientation": 1, "setPadding": 4, "setLayoutParams": 1, "setFrame": 4, "addView": 1, "removeView": 1, "removeAllViews": 0, "bringToFront": 0, "setOnClickListener": 1, "setOnTouchListener": 1, "addTextChangedListener": 1, "removeTextChangedListener": 1, "clearFocus": 0, "requestFocus": 0, "setContentDescription": 1, "setImageBase64": 1, "setImageDrawable": 1, "setImageResource": 1, "unmount": 0, "animate": 1]
    private static func methods(for name: String) -> Set<String> {
        if name == "android.view.ViewPropertyAnimator" {
            return ["alpha", "translationX", "translationY", "scaleX", "scaleY", "rotation", "rotationX", "rotationY",
                    "setDuration", "setStartDelay", "setInterpolator", "withEndAction", "start", "cancel", "getClass"]
        }
        if name == "java.lang.reflect.Method" { return ["getName"] }
        if name.hasSuffix("$LayoutParams") { return ["getClass"] }
        guard self.viewClasses.contains(name) else { return [] }
        var result = self.readMethods.union(self.writeMethods.keys).union(["getClass"])
        result.formUnion(Self.otherWriteMethods.keys)
        if name == "android.widget.ProgressBar" { result.formUnion(Self.progressReadMethods) }
        else { result.subtract(Self.progressReadMethods); result.subtract(["setMax", "setProgress", "setProgressTintList"]) }
        if name == "android.widget.CheckBox" { result.formUnion(["getText", "setText", "setTextSize", "setTextColor", "isChecked", "setChecked", "setButtonTintList", "setOnCheckedChangeListener"]) }
        else { result.subtract(["isChecked", "setChecked", "setButtonTintList", "setOnCheckedChangeListener"]) }
        if !["android.widget.TextView", "android.widget.EditText", "android.widget.CheckBox"].contains(name) { result.subtract(["getText", "setText", "setTextSize", "setTextColor", "setHint", "setHintTextColor", "setSingleLine", "setMinLines", "addTextChangedListener", "removeTextChangedListener"]) }
        if !["android.widget.TextView", "android.widget.EditText"].contains(name) { result.remove("setTypeface") }
        if name == "android.widget.EditText" { result.formUnion(["setInputType", "setSelection", "getSelectionStart", "getSelectionEnd"]) }
        if Self.isImageViewClass(name) { result.formUnion(["setColorFilter", "clearColorFilter", "getColorFilter", "setScaleType", "setImageBase64", "setImageDrawable", "setImageResource"]) }
        if !Self.isImageViewClass(name) { result.subtract(["setColorFilter", "clearColorFilter", "getColorFilter", "setScaleType", "setImageBase64", "setImageDrawable", "setImageResource"]) }
        if !self.viewGroupClasses.contains(name) { result.subtract(["setClipChildren", "getClipChildren"]) }
        if Self.isScrollViewClass(name) { result.subtract(["setClipChildren", "getClipChildren"]) }
        if name != "android.widget.TextView" { result.subtract(["setMaxLines", "setEllipsize"]) }
        if name != "android.widget.TextView" { result.remove("setTextAlignment") }
        if name != "android.widget.EditText" { result.subtract(["hasFocus", "clearFocus", "requestFocus", "setSelection", "getSelectionStart", "getSelectionEnd"]) }
        if !self.viewGroupClasses.contains(name) { result.subtract(["getChildCount", "getChildAt"]) }
        if name != "android.widget.LinearLayout" { result.remove("setOrientation") }
        if name != "android.widget.LinearLayout" { result.remove("getOrientation") }
        if !["android.widget.TextView", "android.widget.EditText", "android.widget.LinearLayout"].contains(name) { result.remove("setGravity") }
        if !["android.widget.TextView", "android.widget.EditText", "android.widget.LinearLayout"].contains(name) { result.remove("getGravity") }
        if !self.viewGroupClasses.contains(name) { result.subtract(["addView", "removeView", "removeAllViews", "getChildCount"]) }
        if Self.isScrollViewClass(name) {
            result.formUnion(Self.scrollReadMethods)
            result.formUnion(Self.scrollWriteMethods.keys)
            if name == "android.widget.ScrollView" { result.remove("setHorizontalScrollBarEnabled") }
            if name == "android.widget.HorizontalScrollView" { result.remove("setVerticalScrollBarEnabled") }
        }
        return result
    }

    private static func isImageViewClass(_ name: String) -> Bool {
        name == "android.widget.ImageView" || name == "android.widget.ImageButton"
    }

    private static func isScrollViewClass(_ name: String) -> Bool {
        name == "android.widget.ScrollView" || name == "android.widget.HorizontalScrollView"
    }

    private static func arrayComponentName(for name: String) -> String? {
        if let component = Self.arrayComponentNames[name] { return component }
        guard name.hasPrefix("[L"), name.hasSuffix(";"), name.utf8.count <= 258 else { return nil }
        let component = String(name.dropFirst(2).dropLast())
        guard component.range(of: "^[A-Za-z][A-Za-z0-9_.$]*$", options: .regularExpression) != nil else { return nil }
        return component
    }

    private static func simpleClassName(_ name: String) -> String {
        if let component = Self.arrayComponentName(for: name) { return Self.simpleClassName(component) + "[]" }
        let packageAndClass = name.split(separator: ".", omittingEmptySubsequences: false).last.map(String.init) ?? name
        return packageAndClass.split(separator: "$", omittingEmptySubsequences: false).last.map(String.init) ?? packageAndClass
    }

    private func declaredMethods(for name: String) -> Set<String> {
        var result = self.methods(for: name).union(self.staticMethods(for: name))
        result.remove("getClass")
        if name == "java.lang.Class" {
            result.formUnion(["getName", "getSimpleName", "getPackageName", "isPrimitive", "isArray", "isInterface", "isEnum",
                              "getComponentType", "getDeclaredMethod", "getDeclaredMethods"])
        }
        return result
    }

    private static func packageName(for name: String) -> String {
        if let component = Self.arrayComponentName(for: name) { return Self.packageName(for: component) }
        guard !Self.primitiveClassNames.contains(name), let separator = name.lastIndex(of: ".") else { return "" }
        return String(name[..<separator])
    }

    private static func standardStaticMethods(for name: String) -> Set<String> {
        if name == "java.lang.Class" { return ["forName"] }
        if name == "android.text.TextUtils" { return ["isEmpty"] }
        if name == "java.lang.reflect.Array" { return Self.arrayMethods }
        return []
    }
}

private final class AyuBridgeContainerBox: @unchecked Sendable {
    let value: UIView?
    init(_ value: UIView?) { self.value = value }
}
