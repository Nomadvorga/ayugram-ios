import Foundation
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// One file a picker returned. Its content is readable only inside `copy`: a document is
/// security-scoped and may still have to be downloaded, a photo exists only while it is exported.
public struct AyuPluginPickedSource: Sendable {
    public let name: String
    public let mimeType: String?
    /// Writes the content to `destination`, which does not exist yet, and returns its size.
    /// Throws `resource_limit` without leaving a file when it is larger than `maximumBytes`.
    public let copy: @Sendable (_ destination: URL, _ maximumBytes: Int64) throws -> Int64

    public init(name: String, mimeType: String?, copy: @escaping @Sendable (URL, Int64) throws -> Int64) {
        self.name = name; self.mimeType = mimeType; self.copy = copy
    }

    /// A file URL as a document picker reports it.
    public static func file(_ url: URL, securityScoped: Bool) -> AyuPluginPickedSource {
        AyuPluginPickedSource(name: url.lastPathComponent, mimeType: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType) { destination, maximumBytes in
            let accessed = securityScoped && url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            var coordination: NSError?
            var outcome: Result<Int64, Error> = .failure(AyuBridgeFailure("io_error", "The picked document cannot be read"))
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordination) { readable in
                outcome = Result { try AyuPluginIntentBridge.boundedCopy(from: readable, to: destination, maximumBytes: maximumBytes) }
            }
            if coordination != nil { throw AyuBridgeFailure("io_error", "The picked document cannot be read") }
            return try outcome.get()
        }
    }
}

public struct AyuPluginPickRequest: Sendable, Equatable {
    /// Lowercase MIME types, `type/*` and `*/*` included.
    public let types: [String]
    public let multiple: Bool
    /// How many documents one pick may return.
    public let limit: Int
}

public enum AyuPluginShareItem: Sendable, Equatable {
    case text(String)
    case file(URL)
}

/// The UIKit step of `intents.launch`. Everything else (validation, quotas, copying, delivery)
/// is `AyuPluginIntentBridge`; tests replace this value to stand in for the user.
public struct AyuPluginIntentPresentation: Sendable {
    public typealias Dismissal = @MainActor @Sendable () -> Void
    /// Whether the bound presenter can show a picker or a sheet now.
    public var canPresent: @MainActor @Sendable (UIViewController?) -> Bool
    /// Shows a picker. `completion` is called once, on any queue, with what the user chose
    /// (nothing when cancelled); the returned closure closes the picker without calling it.
    public var pick: @MainActor @Sendable (UIViewController?, AyuPluginPickRequest, @escaping @Sendable ([AyuPluginPickedSource]) -> Void) -> Dismissal
    /// Shows the share sheet. `completion` is called once when it closes.
    public var share: @MainActor @Sendable (UIViewController?, [AyuPluginShareItem], @escaping @Sendable () -> Void) -> Dismissal

    public init(canPresent: @escaping @MainActor @Sendable (UIViewController?) -> Bool,
                pick: @escaping @MainActor @Sendable (UIViewController?, AyuPluginPickRequest, @escaping @Sendable ([AyuPluginPickedSource]) -> Void) -> Dismissal,
                share: @escaping @MainActor @Sendable (UIViewController?, [AyuPluginShareItem], @escaping @Sendable () -> Void) -> Dismissal) {
        self.canPresent = canPresent; self.pick = pick; self.share = share
    }
}

/// `intents.launch`: a document or photo picker, the share sheet, or the application's link
/// route, started from the visible screen for one plugin. Calls arrive on the host worker; UIKit
/// runs on main after the call returned, files are copied on a utility queue, and the result of
/// a picker reaches Python through its callback. Main never waits for Python.
public final class AyuPluginIntentBridge: @unchecked Sendable {
    public static let operation = "intents.launch"

    /// What the bridge reads of the bound application.
    public struct Environment: Sendable {
        /// Worker: the screen a context handle names when it is the visible one with an active account.
        public let screen: @Sendable ([String: AyuBridgeValue]) throws -> AyuPluginScreenSnapshot
        /// Main: the visible screen and the presenter the application registered.
        public let visible: @MainActor @Sendable () -> (screen: AyuPluginScreenSnapshot?, presenter: UIViewController?)
        /// Worker: whether the application bound a link route.
        public let hasURLRoute: @Sendable () -> Bool
        /// Main: opens a link through the application's route.
        public let openURL: @MainActor @Sendable (AyuPluginScreenSnapshot, URL) -> Void
        /// Main: tells the user why a pick returned nothing.
        public let notify: @MainActor @Sendable (String) -> Void

        public init(screen: @escaping @Sendable ([String: AyuBridgeValue]) throws -> AyuPluginScreenSnapshot,
                    visible: @escaping @MainActor @Sendable () -> (screen: AyuPluginScreenSnapshot?, presenter: UIViewController?),
                    hasURLRoute: @escaping @Sendable () -> Bool,
                    openURL: @escaping @MainActor @Sendable (AyuPluginScreenSnapshot, URL) -> Void,
                    notify: @escaping @MainActor @Sendable (String) -> Void) {
            self.screen = screen; self.visible = visible; self.hasURLRoute = hasURLRoute; self.openURL = openURL; self.notify = notify
        }
    }

    public struct Limits: Sendable {
        public var types = 16
        public var documentsPerPick = 32
        public var documentBytes: Int64 = 67_108_864
        public var heldBytesPerPlugin: Int64 = 268_435_456
        public var heldDocumentsPerPlugin = 64
        public var shareFiles = 16
        public var textBytes = 65_536
        public var urlBytes = 8_192
        public var linksPerPlugin = 4
        public init() {}
    }

    private enum Kind {
        case pick(AyuPluginPickRequest, AyuBridgeNativeCallback)
        case share([AyuPluginShareItem])
        case view(URL)
        var isPresentation: Bool { if case .view = self { return false }; return true }
    }
    private struct Request {
        let owner: String
        let epoch: UInt64
        let screen: AyuPluginScreenSnapshot
        let kind: Kind
    }
    private struct Held { var bytes: Int64 = 0; var documents = 0 }

    private static let contextClasses: Set<String> = ["android.content.Context", "org.telegram.ui.ActionBar.BaseFragment"]
    private let lock = NSLock()
    private var requests: [String: Request] = [:]
    private var epochs: [String: UInt64] = [:]
    private var held: [String: Held] = [:]
    private var purged = false
    @MainActor private var dismissals: [String: AyuPluginIntentPresentation.Dismissal] = [:]
    /// Replaced by tests; the application always uses the UIKit pickers.
    @MainActor var presentation = AyuPluginIntentPresentation.uiKit
    let limits: Limits
    /// `Library/Caches/AyuPluginFiles/picked`: one directory per plugin, removed when it unloads.
    let root: URL
    private let files = DispatchQueue(label: "ayu.plugin.intents.files", qos: .userInitiated)

    public init(limits: Limits = Limits(), root: URL? = nil) {
        self.limits = limits
        self.root = root ?? Self.storage(.cachesDirectory).appendingPathComponent("picked", isDirectory: true)
    }

    // MARK: Worker

    func prepareLaunch(_ arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext, environment: Environment) throws -> AyuBridgeProviderResult {
        guard !Thread.isMainThread else { throw AyuBridgeFailure("wrong_thread", "Bridge dispatch cannot run on main") }
        guard let kind = arguments["kind"]?.string, let reference = arguments["context"] else { throw Self.invalid("intents.launch needs a kind and a context") }
        let owner = context.pluginID
        guard owner.range(of: "^[A-Za-z][A-Za-z0-9_-]{1,31}$", options: .regularExpression) != nil else { throw Self.invalid("Invalid plugin id") }
        let snapshot = try context.snapshot(of: reference)
        guard Self.contextClasses.contains(snapshot.className) else { throw Self.invalid("intents.launch needs an activity context") }
        let screen = try environment.screen(snapshot.state)
        let request: Kind
        switch kind {
        case "pick":
            guard Set(arguments.keys) == ["kind", "context", "types", "multiple", "callback"],
                  let values = arguments["types"]?.array, (1...self.limits.types).contains(values.count),
                  let multiple = arguments["multiple"]?.bool, let callbackValue = arguments["callback"] else { throw Self.invalid("Invalid picker arguments") }
            let types = try values.map { value -> String in
                guard let type = value.string, Self.isMIMEType(type) else { throw Self.invalid("Invalid MIME type") }
                return type
            }
            guard Set(types).count == types.count else { throw Self.invalid("Duplicate MIME type") }
            let callback = try context.callback(callbackValue)
            request = .pick(AyuPluginPickRequest(types: types, multiple: multiple, limit: multiple ? self.limits.documentsPerPick : 1), callback)
        case "share":
            guard Set(arguments.keys).isSubset(of: ["kind", "context", "text", "files"]) else { throw Self.invalid("Invalid share arguments") }
            var items: [AyuPluginShareItem] = []
            if let value = arguments["text"] {
                guard let text = value.string, !text.isEmpty, text.utf8.count <= self.limits.textBytes else { throw Self.invalid("Invalid share text") }
                items.append(.text(text))
            }
            if let value = arguments["files"] {
                guard let paths = value.array, (1...self.limits.shareFiles).contains(paths.count) else { throw Self.invalid("Invalid share files") }
                for path in paths { items.append(.file(try Self.sharedFile(path))) }
            }
            guard !items.isEmpty else { throw Self.invalid("Nothing to share") }
            request = .share(items)
        case "view":
            guard Set(arguments.keys) == ["kind", "context", "url"], let text = arguments["url"]?.string else { throw Self.invalid("Invalid link arguments") }
            let url = try self.viewURL(text)
            guard environment.hasURLRoute() else { throw AyuBridgeFailure("screen_unavailable", "The application's link route is not bound") }
            request = .view(url)
        default:
            throw AyuBridgeFailure.unsupported("intent kind " + String(kind.prefix(32)))
        }
        if request.isPresentation {
            let ready = DispatchQueue.main.sync { self.presentation.canPresent(environment.visible().presenter) }
            guard ready else { throw AyuBridgeFailure("screen_unavailable", "Presentation root is not visible") }
        }
        let token = UUID().uuidString
        self.lock.lock()
        let owned = self.requests.values.filter { $0.owner == owner }
        let allowed = request.isPresentation
            ? !self.requests.values.contains(where: { $0.kind.isPresentation })
            : owned.filter({ !$0.kind.isPresentation }).count < self.limits.linksPerPlugin
        guard allowed else {
            self.lock.unlock()
            throw AyuBridgeFailure("resource_limit", request.isPresentation ? "Another picker or share sheet is open" : "Too many links are being opened")
        }
        self.requests[token] = Request(owner: owner, epoch: self.epochs[owner] ?? 0, screen: screen, kind: request)
        let purge = !self.purged
        self.purged = true
        self.lock.unlock()
        // Copies of an earlier process have no owner left: no plugin generation outlives the process.
        if purge { self.files.async { try? FileManager.default.removeItem(at: self.root) } }
        return AyuBridgeProviderResult(.value(.string(token)), rollback: { _ = self.take(token) }, commit: { _ in
            DispatchQueue.main.async { self.present(token, environment: environment) }
        })
    }

    /// Unload: revokes the plugin's requests, closes its picker and removes every copy it holds.
    func detach(pluginID: String) {
        self.lock.lock()
        let tokens = self.requests.filter { $0.value.owner == pluginID }.map(\.key)
        for token in tokens { self.requests.removeValue(forKey: token) }
        self.epochs[pluginID, default: 0] &+= 1
        self.held.removeValue(forKey: pluginID)
        self.lock.unlock()
        DispatchQueue.main.async { for token in tokens { self.dismissals.removeValue(forKey: token)?() } }
        // Queued behind a copy that is still running for this plugin.
        let directory = self.root.appendingPathComponent(pluginID, isDirectory: true)
        self.files.async { try? FileManager.default.removeItem(at: directory) }
    }

    /// Lock, background and account transitions close bridge-owned pickers and sheets. A plugin
    /// waiting for a picker gets the result Android reports for an activity that returned nothing.
    @MainActor func invalidate() {
        self.lock.lock()
        let revoked = self.requests
        self.requests.removeAll()
        self.lock.unlock()
        for (token, request) in revoked {
            self.dismissals.removeValue(forKey: token)?()
            if case let .pick(_, callback) = request.kind { Self.deliver(callback, token: token, documents: [], error: "SCREEN_UNAVAILABLE") }
        }
    }

    // MARK: Main

    @MainActor private func present(_ token: String, environment: Environment) {
        guard let request = self.request(token) else { return }
        let visible = environment.visible()
        guard let screen = visible.screen, screen.identity == request.screen.identity, screen.accountIndex == request.screen.accountIndex,
              !request.kind.isPresentation || self.presentation.canPresent(visible.presenter) else {
            guard self.take(token) != nil else { return }
            if case let .pick(_, callback) = request.kind { Self.deliver(callback, token: token, documents: [], error: "SCREEN_UNAVAILABLE") }
            return
        }
        switch request.kind {
        case let .view(url):
            guard self.take(token) != nil else { return }
            environment.openURL(request.screen, url)
        case let .share(items):
            self.dismissals[token] = self.presentation.share(visible.presenter, items) { [weak self] in
                guard let self else { return }
                _ = self.take(token)
                DispatchQueue.main.async { self.dismissals.removeValue(forKey: token) }
            }
        case let .pick(pick, _):
            self.dismissals[token] = self.presentation.pick(visible.presenter, pick) { [weak self] sources in
                guard let self else { return }
                DispatchQueue.main.async { self.dismissals.removeValue(forKey: token) }
                self.files.async { self.finish(token, sources: sources, environment: environment) }
            }
        }
    }

    // MARK: Files

    private func finish(_ token: String, sources: [AyuPluginPickedSource], environment: Environment) {
        guard let request = self.take(token), case let .pick(pick, callback) = request.kind else { return }
        guard !sources.isEmpty else { Self.deliver(callback, token: token, documents: [], error: nil); return }
        let directory = self.root.appendingPathComponent(request.owner, isDirectory: true).appendingPathComponent(token, isDirectory: true)
        do {
            self.lock.lock(); let held = self.held[request.owner] ?? Held(); self.lock.unlock()
            guard sources.count <= pick.limit, held.documents + sources.count <= self.limits.heldDocumentsPerPlugin else {
                throw AyuBridgeFailure("resource_limit", "Too many picked documents")
            }
            var documents: [AyuBridgeValue] = []
            var total: Int64 = 0
            for (index, source) in sources.enumerated() {
                let folder = directory.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let name = Self.fileName(source.name)
                let destination = folder.appendingPathComponent(name, isDirectory: false)
                let budget = min(self.limits.documentBytes, self.limits.heldBytesPerPlugin - held.bytes - total)
                guard budget > 0 else { throw AyuBridgeFailure("resource_limit", "The plugin holds too many picked bytes") }
                let size = try source.copy(destination, budget)
                guard size >= 0, size <= budget else { throw AyuBridgeFailure("resource_limit", "The picked document is too large") }
                total += size
                let type = source.mimeType.flatMap { Self.isMIMEType($0) && !$0.hasSuffix("*") ? $0 : nil }
                    ?? UTType(filenameExtension: destination.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                documents.append(.object(["path": .string(destination.path), "name": .string(name), "size": .integer(size),
                                          "mime_type": .string(Self.isMIMEType(type) ? type : "application/octet-stream")]))
            }
            self.lock.lock()
            let current = self.epochs[request.owner] ?? 0 == request.epoch
            if current { self.held[request.owner, default: Held()].bytes += total; self.held[request.owner]?.documents += sources.count }
            self.lock.unlock()
            // Unloaded while copying: the copies have no owner and the callback is gone.
            guard current else { try? FileManager.default.removeItem(at: directory); return }
            Self.deliver(callback, token: token, documents: documents, error: nil)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            let code = (error as? AyuBridgeFailure)?.code ?? "IO_ERROR"
            Self.deliver(callback, token: token, documents: [], error: code)
            let message = code == "RESOURCE_LIMIT" ? "Файл слишком большой для плагина" : "Не удалось передать файл плагину"
            DispatchQueue.main.async { environment.notify(message) }
        }
    }

    /// `RESULT_OK` (-1) with the copies, or `RESULT_CANCELED` (0). The callback is one-shot.
    private static func deliver(_ callback: AyuBridgeNativeCallback, token: String, documents: [AyuBridgeValue], error: String?) {
        var cancelled: [String: AyuBridgeValue] = ["token": .string(token), "result_code": .integer(0), "documents": .array([])]
        var result = cancelled
        if let error { result["error"] = .string(error) }
        if !documents.isEmpty { result["result_code"] = .integer(-1); result["documents"] = .array(documents) }
        cancelled["error"] = .string("RESPONSE_TOO_LARGE")
        callback.send([.object(result)], orOnOverflow: [.object(cancelled)])
        callback.release()
    }

    private func request(_ token: String) -> Request? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.requests[token]
    }

    private func take(_ token: String) -> Request? {
        self.lock.lock(); defer { self.lock.unlock() }
        return self.requests.removeValue(forKey: token)
    }

    /// What the plugin currently holds, for tests and diagnostics.
    func heldDocuments(pluginID: String) -> (bytes: Int64, documents: Int) {
        self.lock.lock(); defer { self.lock.unlock() }
        let held = self.held[pluginID] ?? Held()
        return (held.bytes, held.documents)
    }

    /// Runs after every file operation queued so far.
    func afterFileWork(_ body: @escaping @Sendable () -> Void) { self.files.async(execute: body) }

    // MARK: Validation

    static func isMIMEType(_ value: String) -> Bool {
        value.utf8.count <= 127 && value.range(of: "^(\\*/\\*|[a-z0-9!#$&^_.+-]{1,63}/(\\*|[a-z0-9!#$&^_.+-]{1,63}))$", options: .regularExpression) != nil
    }

    private func viewURL(_ text: String) throws -> URL {
        guard text.utf8.count <= self.limits.urlBytes, text == text.trimmingCharacters(in: .whitespacesAndNewlines),
              let components = URLComponents(string: text), let scheme = components.scheme?.lowercased(),
              let url = components.url, url.baseURL == nil else { throw Self.invalid("Invalid link") }
        switch scheme {
        case "http", "https":
            guard let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { throw Self.invalid("Invalid link") }
            if let port = components.port, !(1...65_535).contains(port) { throw Self.invalid("Invalid link") }
        case "tg":
            break
        default:
            throw AyuBridgeFailure.unsupported("link scheme " + String(scheme.prefix(32)))
        }
        return url
    }

    private static func storage(_ directory: FileManager.SearchPathDirectory) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask)[0].appendingPathComponent("AyuPluginFiles", isDirectory: true)
    }

    private static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// A regular file of the plugin storage (`Application Support/AyuPluginFiles` or
    /// `Caches/AyuPluginFiles`), which is all a plugin may hand to another application.
    static func sharedFile(_ value: AyuBridgeValue) throws -> URL {
        guard let path = value.string, path.hasPrefix("/"), path.utf8.count <= 4096, let real = self.resolved(path) else { throw self.invalid("Invalid shared file") }
        let roots = [self.storage(.applicationSupportDirectory), self.storage(.cachesDirectory)].compactMap { self.resolved($0.path) }
        guard roots.contains(where: { real.hasPrefix($0 + "/") }) else {
            throw AyuBridgeFailure.unsupported("sharing a file outside the plugin storage")
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: real)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else { throw self.invalid("Invalid shared file") }
        return URL(fileURLWithPath: real, isDirectory: false)
    }

    /// The last path component as a file name of at most 255 bytes.
    static func fileName(_ name: String) -> String {
        var result = name.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
        result = String(result.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        if result.isEmpty || result == "." || result == ".." { result = "document" }
        while result.utf8.count > 255 { result.removeFirst() }
        return result
    }

    /// Streams a regular file into a new file, failing without a leftover beyond `maximumBytes`.
    static func boundedCopy(from source: URL, to destination: URL, maximumBytes: Int64) throws -> Int64 {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw AyuBridgeFailure("io_error", "The picked item is not a file") }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else { throw AyuBridgeFailure("io_error", "The copy cannot be created") }
        var written: Int64 = 0
        do {
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            while let chunk = try input.read(upToCount: 65_536), !chunk.isEmpty {
                written += Int64(chunk.count)
                guard written <= maximumBytes else { throw AyuBridgeFailure("resource_limit", "The picked document is too large") }
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return written
    }

    private static func invalid(_ message: String) -> AyuBridgeFailure { AyuBridgeFailure("invalid_arguments", message) }
}

// MARK: UIKit presentation

extension AyuPluginIntentPresentation {
    /// `PHPickerViewController` when only images or videos are asked for (the photo library is
    /// not reachable from the document picker), `UIDocumentPickerViewController` otherwise, and
    /// `UIActivityViewController` for sharing.
    public static let uiKit = AyuPluginIntentPresentation(canPresent: { presenter in
        guard let presenter else { return false }
        return presenter.viewIfLoaded?.window != nil && presenter.presentedViewController == nil
    }, pick: { presenter, request, completion in
        guard let presenter else { completion([]); return {} }
        let session = AyuPluginPickerSession(completion: completion)
        let controller: UIViewController
        if request.types.allSatisfy({ $0.hasPrefix("image/") || $0.hasPrefix("video/") }) {
            var configuration = PHPickerConfiguration()
            let images = request.types.contains { $0.hasPrefix("image/") }, videos = request.types.contains { $0.hasPrefix("video/") }
            configuration.filter = images && videos ? .any(of: [.images, .videos]) : images ? .images : .videos
            configuration.selectionLimit = request.limit
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = session
            controller = picker
        } else {
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: AyuPluginPickerSession.contentTypes(request.types), asCopy: false)
            picker.allowsMultipleSelection = request.multiple
            picker.delegate = session
            controller = picker
        }
        session.retain(controller)
        presenter.present(controller, animated: true)
        return { session.dismiss() }
    }, share: { presenter, items, completion in
        guard let presenter else { completion(); return {} }
        let values: [Any] = items.map { item in
            switch item {
            case let .text(text): return text
            case let .file(url): return url
            }
        }
        let controller = UIActivityViewController(activityItems: values, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in completion() }
        if let popover = controller.popoverPresentationController, let view = presenter.viewIfLoaded {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(controller, animated: true)
        return { [weak controller] in
            controller?.completionWithItemsHandler = nil
            controller?.dismiss(animated: false)
        }
    })
}

/// Delegate of one picker. It keeps itself and the picker alive until the user is done.
@MainActor private final class AyuPluginPickerSession: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
    private var completion: (@Sendable ([AyuPluginPickedSource]) -> Void)?
    private var controller: UIViewController?
    private var retained: AyuPluginPickerSession?

    init(completion: @escaping @Sendable ([AyuPluginPickedSource]) -> Void) { self.completion = completion }

    func retain(_ controller: UIViewController) { self.controller = controller; self.retained = self }

    /// Closes the picker without reporting anything.
    func dismiss() {
        self.completion = nil
        self.controller?.dismiss(animated: false)
        self.controller = nil; self.retained = nil
    }

    private func finish(_ sources: [AyuPluginPickedSource]) {
        let completion = self.completion
        self.completion = nil; self.controller = nil; self.retained = nil
        completion?(sources)
    }

    /// A concrete MIME type the system does not know would make every file unselectable, so it
    /// widens to any file; the plugin learns the real type of what was picked from `getType`.
    static func contentTypes(_ types: [String]) -> [UTType] {
        var result: [UTType] = []
        for type in types {
            let found: UTType
            switch type {
            case "*/*": found = .item
            case "image/*": found = .image
            case "video/*": found = .movie
            case "audio/*": found = .audio
            case "text/*": found = .text
            default:
                if !type.hasSuffix("/*"), let known = UTType(mimeType: type), !known.isDynamic { found = known } else { found = .data }
            }
            if !result.contains(found) { result.append(found) }
        }
        return result
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { self.finish([]) }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        self.finish(urls.map { AyuPluginPickedSource.file($0, securityScoped: true) })
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        self.finish(results.compactMap { result in
            let provider = result.itemProvider
            guard let identifier = provider.registeredTypeIdentifiers.first(where: { UTType($0).map { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? false }),
                  let type = UTType(identifier) else { return nil }
            let name = (provider.suggestedName ?? "media") + "." + (type.preferredFilenameExtension ?? "dat")
            let export = AyuPluginPickerOutcome(provider: provider)
            return AyuPluginPickedSource(name: name, mimeType: type.preferredMIMEType) { destination, maximumBytes in
                // The exported file exists only inside the handler; the caller is a utility queue.
                let done = DispatchSemaphore(value: 0)
                export.provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, _ in
                    export.set(Result {
                        guard let url else { throw AyuBridgeFailure("io_error", "The picked photo cannot be exported") }
                        return try AyuPluginIntentBridge.boundedCopy(from: url, to: destination, maximumBytes: maximumBytes)
                    })
                    done.signal()
                }
                done.wait()
                return try export.get()
            }
        })
    }
}

/// The item provider of one picked photo and the result of exporting it; the provider is used on one queue at a time.
private final class AyuPluginPickerOutcome: @unchecked Sendable {
    let provider: NSItemProvider
    init(provider: NSItemProvider) { self.provider = provider }
    private let lock = NSLock()
    private var value: Result<Int64, Error> = .failure(AyuBridgeFailure("io_error", "The picked photo cannot be exported"))
    func set(_ value: Result<Int64, Error>) { self.lock.lock(); self.value = value; self.lock.unlock() }
    func get() throws -> Int64 { self.lock.lock(); defer { self.lock.unlock() }; return try self.value.get() }
}
