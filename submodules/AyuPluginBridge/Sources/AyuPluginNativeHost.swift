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
    }
    private struct Session: @unchecked Sendable {
        let generation: UUID
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
            let methods = remote.kind == "class" ? Self.reflectionMethods.union(self.classRegistry.adapters[remote.className]?.staticMethods.keys.map { $0 } ?? []) : remote.kind == "method" ? Set(["getName"]) : self.methods(for: remote.className)
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
            self.objects[target]?.fields[name] = .number(number); return .null
        case "java.release":
            let target = try self.target(arguments); let remote = try self.remote(target, owner: owner)
            guard !self.objects.values.contains(where: { $0.owner == owner && $0.fields["parent"]?.string == target }) else { throw AyuBridgeFailure("invalid_state", "Remove children before releasing their parent") }
            if remote.kind == "view" { DispatchQueue.main.sync { self.ui.release(owner: owner, handle: target) } }
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
            guard name == remote.className || (name == "android.view.View" && remote.kind == "view") else { throw AyuBridgeFailure.unsupported("cast to " + name) }
            return self.reference(target, className: remote.className)
        case "java.array":
            let component = try self.text(arguments, "component")
            guard let arrayClass = Self.arrayClasses[component], let values = arguments["values"]?.array, values.count <= self.limits.commandsPerTransaction else { throw AyuBridgeFailure("invalid_arguments", "Array requires a supported component and bounded values") }
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
            try self.validateArrayValue(value, component: remote.fields["component"]?.string ?? "", owner: owner)
            values[Int(index)] = value; self.objects[handle]?.fields["values"] = .array(values); return .null
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
            // Validate all before applying anything. Transactions support setters only.
            let snapshot = self.objects
            var batch: [AyuBridgeUI.Command] = []
            do {
                for call in calls {
                    guard let args = call.object else { throw AyuBridgeFailure("invalid_arguments", "Invalid UI command") }
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
        let contextArgument = args.isEmpty || (args.count == 1 && (args[0] == .null || args[0].object?["$handle"] != nil))
        guard Self.viewClasses.contains(name), contextArgument else { throw AyuBridgeFailure.unsupported("constructor " + name) }
        let value = try self.store(owner: owner, className: name, kind: "view")
        let handle = value["$handle"].string!
        DispatchQueue.main.sync { self.ui.create(owner: owner, generation: generation, handle: handle, className: name) }
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
            if method == "getName" { return .string(remote.className) }
            if method == "getDeclaredMethod" {
                guard let name = arguments["args"]?.array?.first?.string, self.methods(for: remote.className).union(self.classRegistry.adapters[remote.className]?.staticMethods.keys.map { $0 } ?? []).contains(name) else { throw AyuBridgeFailure.unsupported("reflection target") }
                return try self.store(owner: owner, className: "java.lang.reflect.Method", kind: "method", fields: ["name": .string(name), "declaring_class": .string(remote.className)])
            }
            if method == "getDeclaredMethods" { return .array(try self.methods(for: remote.className).union(self.classRegistry.adapters[remote.className]?.staticMethods.keys.map { $0 } ?? []).sorted().map { try self.store(owner: owner, className: "java.lang.reflect.Method", kind: "method", fields: ["name": .string($0), "declaring_class": .string(remote.className)]) }) }
            throw AyuBridgeFailure.unsupported(remote.className + "." + method)
        }
        if remote.kind == "method", method == "getName" { return remote.fields["name"] ?? .null }
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
                    self.objects[handle]?.fields = returnedFields
                    return reference
                }
                return try self.adapterResult(result, owner: owner)
            } catch { self.objects = snapshot; throw error }
        }
        if remote.kind == "layout", method == "setMargins" {
            let values = try (arguments["args"]?.array ?? []).map(self.number)
            guard values.count == 4, values.allSatisfy({ abs($0) <= 100_000 }) else { throw AyuBridgeFailure("invalid_arguments", "Invalid layout margins") }
            let layoutHandle = try self.target(arguments)
            self.objects[layoutHandle]?.fields["margins"] = .array(values.map { .number($0) })
            return .null
        }
        guard remote.kind == "view", Self.methods(for: remote.className).contains(method) else { throw AyuBridgeFailure.unsupported(remote.className + "." + method) }
        let handle = try self.target(arguments)
        if method == "getText", remote.className == "android.widget.EditText" {
            let text = try DispatchQueue.main.sync { try self.ui.readText(owner: owner, handle: handle) }
            return try self.store(owner: owner, className: "java.lang.String", kind: "adapter", fields: ["value": .string(text)])
        }
        if Self.readMethods.contains(method) {
            guard method != "getText" || remote.className == "android.widget.TextView" else { throw AyuBridgeFailure.unsupported(method) }
            return try DispatchQueue.main.sync { try self.ui.read(owner: owner, handle: handle, method: method) }
        }
        let snapshot = self.objects
        do {
            let command = try self.uiCommand(owner: owner, arguments: arguments, generation: generation)
            try self.ui.enqueue([command])
            self.track(command)
        } catch { self.objects = snapshot; throw error }
        return .null
    }

    private func track(_ command: AyuBridgeUI.Command) {
        if command.method == "addView", let child = command.arguments.first?["$handle"].string { self.objects[child]?.fields["parent"] = .string(command.handle) }
        if command.method == "removeView", let child = command.arguments.first?["$handle"].string { self.objects[child]?.fields.removeValue(forKey: "parent") }
        if command.method == "unmount" { self.objects[command.handle]?.fields.removeValue(forKey: "parent") }
        if command.method == "removeAllViews" {
            let children = self.objects.filter { $0.value.owner == command.owner && $0.value.fields["parent"]?.string == command.handle }.map(\.key)
            for child in children { self.objects[child]?.fields.removeValue(forKey: "parent") }
        }
    }

    private func uiCommand(owner: String, arguments: [String: AyuBridgeValue], generation: UUID) throws -> AyuBridgeUI.Command {
        let handle = try self.target(arguments); let remote = try self.remote(handle, owner: owner)
        let method = arguments["method"]?.string ?? arguments["name"]?.string ?? ""
        guard remote.kind == "view", Self.methods(for: remote.className).contains(method), let arity = Self.writeMethods[method] else { throw AyuBridgeFailure.unsupported(remote.className + "." + method) }
        var args = arguments["args"]?.array ?? []
        var nativeMethod = method
        let validArity = args.count == arity || (method == "addView" && args.count == 2)
        guard validArity else { throw AyuBridgeFailure("invalid_arguments", "Wrong argument count for " + method) }
        try self.validateReferences(.array(args), owner: owner)
        if ["setText", "setTextColor", "setTextSize", "setHint", "setHintTextColor", "setSingleLine", "setMinLines"].contains(method), remote.className != "android.widget.TextView" && remote.className != "android.widget.EditText" { throw AyuBridgeFailure.unsupported(method) }
        if method == "setOrientation", remote.className != "android.widget.LinearLayout" { throw AyuBridgeFailure.unsupported(method) }
        if method == "setImageBase64", remote.className != "android.widget.ImageView" { throw AyuBridgeFailure.unsupported(method) }
        if method == "addView" || method == "removeView" {
            guard ["android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.ScrollView"].contains(remote.className) else { throw AyuBridgeFailure.unsupported(method) }
            let child = try self.handle(args[0]); let childRemote = try self.remote(child, owner: owner)
            guard childRemote.kind == "view", child != handle else { throw AyuBridgeFailure("invalid_arguments", "Expected a distinct child view") }
            if method == "addView" {
                guard childRemote.fields["parent"] == nil else { throw AyuBridgeFailure("invalid_state", "Child already has a parent") }
                var ancestor: String? = handle
                while let current = ancestor { guard current != child else { throw AyuBridgeFailure("invalid_arguments", "View hierarchy cycle") }; ancestor = self.objects[current]?.fields["parent"]?.string }
                if remote.className == "android.widget.ScrollView" {
                    let childCount = self.objects.values.filter { $0.owner == owner && $0.fields["parent"]?.string == handle }.count
                    guard childCount == 0 else { throw AyuBridgeFailure("invalid_state", "ScrollView accepts only one direct child") }
                }
                if args.count == 2 {
                    let layout = try self.remote(self.handle(args[1]), owner: owner)
                    guard layout.kind == "layout" else { throw AyuBridgeFailure("invalid_arguments", "Expected LayoutParams") }
                    let accepted = remote.className == "android.widget.LinearLayout"
                        ? ["android.view.ViewGroup$LayoutParams", "android.widget.LinearLayout$LayoutParams"].contains(layout.className)
                        : ["android.view.ViewGroup$LayoutParams", "android.widget.FrameLayout$LayoutParams"].contains(layout.className)
                    guard accepted else { throw AyuBridgeFailure("invalid_arguments", "LayoutParams do not match the parent") }
                    args[1] = .object(layout.fields)
                }
            } else if childRemote.fields["parent"]?.string != handle { throw AyuBridgeFailure("invalid_state", "View is not a child of this parent") }
        }
        if method == "setLayoutParams" {
            let layout = try self.remote(self.handle(args[0]), owner: owner)
            guard layout.kind == "layout" else { throw AyuBridgeFailure("invalid_arguments", "Expected LayoutParams") }
            guard ["android.view.ViewGroup$LayoutParams", "android.widget.LinearLayout$LayoutParams", "android.widget.FrameLayout$LayoutParams"].contains(layout.className) else {
                throw AyuBridgeFailure("invalid_arguments", "Unsupported LayoutParams class")
            }
            args[0] = .object(layout.fields)
        } else if method == "setBackground" {
            if args[0] == .null {
                args[0] = .integer(0)
            } else {
                let drawable = try self.remote(self.handle(args[0]), owner: owner)
                guard drawable.kind == "adapter", drawable.className == "android.graphics.drawable.ColorDrawable",
                      let color = drawable.fields["color"]?.integer else {
                    throw AyuBridgeFailure.unsupported("View.setBackground drawable")
                }
                args[0] = .integer(color)
            }
            nativeMethod = "setBackgroundColor"
        } else if method == "setOnClickListener" || method == "setOnTouchListener" {
            if args[0] != .null { args[0] = .object(["$callback": .string(try self.callbackID(args[0], owner: owner, method: method == "setOnClickListener" ? "onClick" : "onTouch"))]) }
        } else if method == "setText" {
            guard args[0].string != nil else { throw AyuBridgeFailure("invalid_arguments", "Text must be a string") }
        } else if method == "setHint" {
            guard args[0].string != nil else { throw AyuBridgeFailure("invalid_arguments", "Hint must be a string") }
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
        } else if method == "animate" {
            guard let properties = args[0].object, !properties.isEmpty, Set(properties.keys).isSubset(of: ["duration_ms", "alpha", "translation_x", "translation_y"]) else { throw AyuBridgeFailure("invalid_arguments", "Unsupported animation property") }
            for (key, value) in properties {
                let number = try self.number(value)
                if key == "duration_ms" && !(0...10_000).contains(number) { throw AyuBridgeFailure("invalid_arguments", "Animation exceeds duration limit") }
                if key == "alpha" && !(0...1).contains(number) { throw AyuBridgeFailure("invalid_arguments", "Invalid alpha") }
            }
        } else if !["addView", "removeView", "removeAllViews", "bringToFront", "unmount"].contains(method) {
            let numbers = try args.map(self.number)
            if method == "setVisibility", ![0, 4, 8].contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid visibility") }
            if method == "setOrientation", ![0, 1].contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid orientation") }
            if method == "setAlpha", !(0...1).contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid alpha") }
            if method == "setTextSize", !(1...256).contains(numbers[0]) { throw AyuBridgeFailure("invalid_arguments", "Invalid font size") }
            if method == "setFrame", numbers[2] < 0 || numbers[3] < 0 { throw AyuBridgeFailure("invalid_arguments", "Negative frame size") }
        }
        return AyuBridgeUI.Command(owner: owner, generation: generation, handle: handle, method: nativeMethod, arguments: args)
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

    /// Handler adapters use the same bounded worker-owned timer table as the
    /// scheduler API. The queued main hop retains no adapter context and is
    /// harmless after generation revocation.
    private func prepareAdapterCallback(owner: String, generation: UUID, callbackID: String, delayMilliseconds: Int64) throws -> AyuBridgeProviderResult {
        guard let session = self.sessions[owner], session.active, session.generation == generation,
              session.callbackIDs.contains(callbackID) else {
            throw AyuBridgeFailure("callback_expired", "Callback is unavailable")
        }
        guard (0...60_000).contains(delayMilliseconds), session.timers.count < self.limits.callbacksPerPlugin else {
            throw AyuBridgeFailure("resource_limit", "Handler pending callback limit exceeded")
        }
        return AyuBridgeProviderResult(.value(.bool(true)), commit: { [weak self] _ in
            self?.scheduleAdapterCallback(owner: owner, generation: generation, callbackID: callbackID, delayMilliseconds: delayMilliseconds)
        })
    }

    private func scheduleAdapterCallback(owner: String, generation: UUID, callbackID: String, delayMilliseconds: Int64) {
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
        let handle = UUID().uuidString
        self.objects[handle] = Remote(owner: owner, className: className, kind: kind, fields: fields)
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
        default: throw AyuBridgeFailure.unsupported("array component " + component)
        }
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
    private func knownClass(_ name: String) -> Bool { Self.classes[name] != nil || self.classRegistry.adapters[name] != nil }
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
            guard remote.kind == "adapter" || remote.kind == "array" || remote.kind == "proxy" else { throw AyuBridgeFailure.unsupported("adapter state for " + remote.className) }
            return AyuBridgeAdapterSnapshot(className: remote.className, state: remote.fields)
        }, schedule: { [weak self] callback, delayMilliseconds in
            guard let self, DispatchQueue.getSpecific(key: self.workerKey) == true else { throw AyuBridgeFailure("wrong_queue", "Callback scheduling is worker-only") }
            return try self.prepareAdapterCallback(owner: owner, generation: generation, callbackID: callback.id, delayMilliseconds: delayMilliseconds)
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
    private static let proxyInterfaces: [String: [String]] = ["java.lang.Runnable": ["run"], "android.view.View$OnClickListener": ["onClick"], "android.view.View$OnTouchListener": ["onTouch"], "org.telegram.messenger.NotificationCenter$NotificationCenterDelegate": ["didReceivedNotification"]]
    private static let arrayClasses = ["byte": "[B", "short": "[S", "char": "[C", "int": "[I", "long": "[J", "float": "[F", "double": "[D", "boolean": "[Z"]
    static var primitiveArrayClassNames: Set<String> { Set(self.arrayClasses.values) }
    private static let schedulerQueues: Set<String> = ["main", "pluginsQueue", "globalQueue", "stageQueue", "cacheClearQueue", "searchQueue", "phoneBookQueue", "themeQueue", "externalNetworkQueue"]
    static var reservedClassNames: Set<String> { Set(self.classes.keys) }
    private static let reflectionMethods: Set<String> = ["getName", "getDeclaredMethod", "getDeclaredMethods"]
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
            for method in self.methods(for: name).union(self.classRegistry.adapters[name]?.staticMethods.keys.map { $0 } ?? []).sorted() {
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

    private static let viewClasses: Set<String> = ["android.view.View", "android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.TextView", "android.widget.ImageView", "android.widget.EditText", "android.widget.ScrollView"]
    private static let layoutFields: Set<String> = ["width", "height", "x", "y"]
    private static let classes: [String: [String: AyuBridgeValue]] = [
        "android.view.View": ["VISIBLE": .number(0), "INVISIBLE": .number(4), "GONE": .number(8)],
        "android.view.Gravity": [
            "NO_GRAVITY": .integer(0), "CENTER_HORIZONTAL": .integer(1), "LEFT": .integer(3), "RIGHT": .integer(5),
            "CENTER_VERTICAL": .integer(16), "TOP": .integer(48), "BOTTOM": .integer(80), "CENTER": .integer(17),
            "START": .integer(8_388_611), "END": .integer(8_388_613),
        ],
        "android.view.ViewGroup": [:],
        "android.view.ViewGroup$LayoutParams": ["MATCH_PARENT": .number(-1), "WRAP_CONTENT": .number(-2)],
        "android.widget.FrameLayout": [:], "android.widget.LinearLayout": ["HORIZONTAL": .number(0), "VERTICAL": .number(1)],
        "android.widget.TextView": [:], "android.widget.ImageView": [:], "android.widget.EditText": [:], "android.widget.ScrollView": [:],
        "android.widget.FrameLayout$LayoutParams": ["MATCH_PARENT": .number(-1), "WRAP_CONTENT": .number(-2)],
        "android.widget.LinearLayout$LayoutParams": ["MATCH_PARENT": .number(-1), "WRAP_CONTENT": .number(-2)],
        "java.lang.reflect.Method": [:], "[B": [:], "[S": [:], "[C": [:], "[I": [:], "[J": [:], "[F": [:], "[D": [:], "[Z": [:],
        "java.lang.Runnable": [:], "android.view.View$OnClickListener": [:], "android.view.View$OnTouchListener": [:]
    ]
    private static let readMethods: Set<String> = ["getWidth", "getHeight", "getMeasuredWidth", "getMeasuredHeight", "getX", "getY", "getAlpha", "getTranslationX", "getTranslationY", "getVisibility", "getText", "getChildCount"]
    private static let writeMethods: [String: Int] = ["setAlpha": 1, "setTranslationX": 1, "setTranslationY": 1, "setScaleX": 1, "setScaleY": 1, "setVisibility": 1, "setBackgroundColor": 1, "setBackground": 1, "setText": 1, "setTextColor": 1, "setTextSize": 1, "setHint": 1, "setHintTextColor": 1, "setSingleLine": 1, "setMinLines": 1, "setGravity": 1, "setOrientation": 1, "setPadding": 4, "setLayoutParams": 1, "setFrame": 4, "addView": 1, "removeView": 1, "removeAllViews": 0, "bringToFront": 0, "setOnClickListener": 1, "setOnTouchListener": 1, "setImageBase64": 1, "unmount": 0, "animate": 1]
    private static func methods(for name: String) -> Set<String> {
        if name == "java.lang.reflect.Method" { return ["getName"] }
        if name.hasSuffix("$LayoutParams") { return ["getClass"] }
        guard self.viewClasses.contains(name) else { return [] }
        var result = self.readMethods.union(self.writeMethods.keys).union(["getClass"])
        if name != "android.widget.TextView" && name != "android.widget.EditText" { result.subtract(["getText", "setText", "setTextSize", "setTextColor", "setHint", "setHintTextColor", "setSingleLine", "setMinLines"]) }
        if name != "android.widget.LinearLayout" { result.remove("setOrientation") }
        if !["android.widget.TextView", "android.widget.EditText", "android.widget.LinearLayout"].contains(name) { result.remove("setGravity") }
        if name != "android.widget.ImageView" { result.remove("setImageBase64") }
        if !["android.widget.FrameLayout", "android.widget.LinearLayout", "android.widget.ScrollView"].contains(name) { result.subtract(["addView", "removeView", "removeAllViews", "getChildCount"]) }
        return result
    }
}

private final class AyuBridgeContainerBox: @unchecked Sendable {
    let value: UIView?
    init(_ value: UIView?) { self.value = value }
}
