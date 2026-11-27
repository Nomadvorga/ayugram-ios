import Foundation
import UIKit
@preconcurrency import XCTest
@testable import AyuPluginBridge

/// Synthetic native regressions, no account login, interpreter or network.
/// Source-only until executed with the iOS test runner; a build is not a test run.
@MainActor final class AyuPluginApplicationBridgeTests: XCTestCase {
    private final class ClipboardBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: String) { self.lock.lock(); self.storage.append(value); self.lock.unlock() }
        func values() -> [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
    }
    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []
        func append(_ value: URL) { self.lock.lock(); self.storage.append(value.absoluteString); self.lock.unlock() }
        func values() -> [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
    }
    private final class ScreenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: AyuPluginScreenSnapshot
        init(_ screen: AyuPluginScreenSnapshot) { self.storage = screen }
        func set(_ screen: AyuPluginScreenSnapshot) { self.lock.lock(); self.storage = screen; self.lock.unlock() }
        func get() -> AyuPluginScreenSnapshot { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
    }
    private final class ScreenProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        func read() -> Int { self.lock.lock(); defer { self.lock.unlock() }; self.reads += 1; return self.reads }
        var count: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.reads }
    }
    private final class LocaleBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String
        init(_ value: String) { self.value = value }
        func set(_ value: String) { self.lock.lock(); self.value = value; self.lock.unlock() }
        func get() -> String { self.lock.lock(); defer { self.lock.unlock() }; return self.value }
    }

    private func host(_ provider: AyuPluginHostProvider, registry: AyuBridgeClassRegistry = .standard, limits: AyuPluginBridgeLimits = AyuPluginBridgeLimits(), callback: @escaping AyuPluginNativeHost.CallbackSink = { _, _, _ in }) -> AyuPluginNativeHost {
        AyuPluginNativeHost(defaults: UserDefaults(suiteName: "AyuApplicationBridgeTests." + UUID().uuidString)!, provider: provider, classRegistry: registry, limits: limits, trustedOwner: { "alpha" }, callback: callback)
    }
    private func call(_ host: AyuPluginNativeHost, _ operation: String, owner: String = "alpha", _ arguments: [String: AyuBridgeValue] = [:]) async throws -> AyuBridgeValue {
        let body: AyuBridgeValue = .object(["version": .integer(1), "id": .string("23"), "plugin_id": .string(owner), "operation": .string(operation), "arguments": .object(arguments)])
        let text = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        let result = await Task.detached { host.dispatch(text, owner: owner) }.value
        return try JSONDecoder().decode(AyuBridgeValue.self, from: Data(result.utf8))
    }
    private func authorize(_ host: AyuPluginNativeHost, owner: String = "alpha") async throws {
        let response = try await self.call(host, "plugin.authorize", owner: owner)
        XCTAssertEqual(response["result"], .bool(true))
    }
    private func client(_ host: AyuPluginNativeHost, _ name: String, kwargs: [String: AyuBridgeValue] = [:], owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "client.call", owner: owner, ["name": .string(name), "args": .array([]), "kwargs": .object(kwargs)])
    }
    private func invoke(_ host: AyuPluginNativeHost, _ target: AyuBridgeValue, _ method: String, args: [AyuBridgeValue] = [], owner: String = "alpha") async throws -> AyuBridgeValue {
        try await self.call(host, "java.invoke", owner: owner, ["target": target, "name": .string(method), "args": .array(args)])
    }

    private func presentationWindow(_ presenter: UIViewController) throws -> UIWindow {
        // A screen-based UIWindow traps during hostless runner shutdown. Reuse
        // an application-owned scene only; pure provider tests need no window.
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw XCTSkip("Presentation integration requires an application-owned UIWindowScene")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 640)
        window.rootViewController = presenter
        window.isHidden = false
        return window
    }

    private func flushMain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func preparedBrowserURL(_ provider: AyuPluginApplicationBridge, url: String,
                                   screen: AyuPluginScreenSnapshot, owner: String = "alpha") async throws -> AyuBridgeProviderResult {
        let registry = try provider.classRegistry()
        let openURL = try XCTUnwrap(registry.adapters["org.telegram.messenger.browser.Browser"]?.staticMethods["openUrl"])
        let context = AyuBridgeAdapterContext(pluginID: owner, resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("Synthetic Browser callback")
        }, resolve: { reference in
            guard reference == .string("context") else { throw AyuBridgeFailure("invalid_handle", "Unknown synthetic context") }
            return AyuBridgeAdapterSnapshot(className: "android.content.Context", state: screen.state)
        })
        return try await Task.detached {
            guard case let .prepared(result) = try openURL([.string("context"), .string(url)], context) else {
                throw AyuBridgeFailure("test_failure", "Browser.openUrl did not prepare its native effect")
            }
            return result
        }.value
    }

    func testBrowserOpenURLStringAndUriOverloadsUseQueuedAppRoute() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let opened = URLBox()
        provider.bindScreen(screen: { screen }, presenter: { nil }, openURL: { _, url in opened.append(url) })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)

        let fragment = try await self.client(host, "get_last_fragment")
        let context = try await self.invoke(host, fragment["result"], "getContext")
        let browser: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.browser.Browser")])
        let stringURL = "https://example.org/path?q=bridge"
        let stringResult = try await self.invoke(host, browser, "openUrl", args: [context["result"], .string(stringURL)])
        XCTAssertEqual(stringResult["result"], .null)
        await self.flushMain()
        XCTAssertEqual(opened.values(), [stringURL])

        let uriClass: AyuBridgeValue = .object(["class_name": .string("android.net.Uri")])
        let uri = try await self.invoke(host, uriClass, "parse", args: [.string("https://example.net/uri")])
        let uriResult = try await self.invoke(host, browser, "openUrl", args: [context["result"], uri["result"]])
        XCTAssertEqual(uriResult["result"], .null)
        await self.flushMain()
        XCTAssertEqual(opened.values(), [stringURL, "https://example.net/uri"])

        let wrongTarget = try await self.invoke(host, browser, "openUrl", args: [uri["result"], .string(stringURL)])
        XCTAssertEqual(wrongTarget["error"]["code"], .string("INVALID_ARGUMENTS"))
        let extraOptions = try await self.invoke(host, browser, "openUrl", args: [context["result"], .string(stringURL), .bool(true)])
        XCTAssertEqual(extraOptions["error"]["code"], .string("INVALID_ARGUMENTS"))
        let relative = try await self.invoke(host, browser, "openUrl", args: [context["result"], .string("/relative/path")])
        XCTAssertEqual(relative["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedScheme = try await self.invoke(host, browser, "openUrl", args: [context["result"], .string("tg://resolve?domain=example")])
        XCTAssertEqual(unsupportedScheme["error"]["code"], .string("UNSUPPORTED_API"))
        let userInfo = try await self.invoke(host, browser, "openUrl", args: [context["result"], .string("https://user:secret@example.org")])
        XCTAssertEqual(userInfo["error"]["code"], .string("INVALID_ARGUMENTS"))
        let oversized = try await self.invoke(host, browser, "openUrl", args: [context["result"], .string("https://example.org/" + String(repeating: "x", count: 8_200))])
        XCTAssertEqual(oversized["error"]["code"], .string("INVALID_ARGUMENTS"))
        XCTAssertEqual(opened.values(), [stringURL, "https://example.net/uri"])
    }

    func testLocaleControllerUsesBoundedTelegramPresentationLocaleSnapshot() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.bindScreen(screen: { nil }, presenter: { nil }, localeIdentifier: { "ar" })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)

        let localeController: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.LocaleController")])
        let localeResult = try await self.invoke(host, localeController, "getInstance")
        XCTAssertEqual(localeResult["error"], .null)
        let currentLocale = try await self.invoke(host, localeResult["result"], "getCurrentLocale")
        XCTAssertEqual(currentLocale["error"], .null)
        let language = try await self.invoke(host, currentLocale["result"], "getLanguage")
        XCTAssertEqual(language["error"], .null)
        XCTAssertEqual(language["result"], .string("ar"))
        let isRTL = try await self.invoke(host, localeResult["result"], "isRTL")
        XCTAssertEqual(isRTL["error"], .null)
        XCTAssertEqual(isRTL["result"], .bool(true))

        let wrongArity = try await self.invoke(host, localeController, "getInstance", args: [.integer(0)])
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unsupportedStringLookup = try await self.invoke(host, localeResult["result"], "getString", args: [.string("hello")])
        XCTAssertEqual(unsupportedStringLookup["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testLocaleControllerCurrentLocaleInfoMapsRegionalIdentifiersAndExpires() async throws {
        let provider = AyuPluginApplicationBridge()
        let locale = LocaleBox("ru_RU")
        provider.bindScreen(screen: { nil }, presenter: { nil }, localeIdentifier: { locale.get() })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let controller: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.LocaleController")])

        let expected: [(String, String)] = [("ru_RU", "ru"), ("uk-UA", "uk"), ("be_BY", "be"), ("en_GB", "en")]
        for (identifier, code) in expected {
            locale.set(identifier)
            let instance = try await self.invoke(host, controller, "getInstance")
            let info = try await self.invoke(host, instance["result"], "getCurrentLocaleInfo")
            XCTAssertEqual(info["error"], .null)
            let plural = try await self.call(host, "java.get_field", ["target": info["result"], "name": .string("pluralLangCode")])
            XCTAssertEqual(plural["result"], .string(code))
            let wrongArity = try await self.invoke(host, instance["result"], "getCurrentLocaleInfo", args: [.integer(0)])
            XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
            let write = try await self.call(host, "java.set_field", ["target": info["result"], "name": .string("pluralLangCode"), "value": .string("en")])
            XCTAssertEqual(write["error"]["code"], .string("UNSUPPORTED_API"))
        }

        let instance = try await self.invoke(host, controller, "getInstance")
        let info = try await self.invoke(host, instance["result"], "getCurrentLocaleInfo")
        _ = try await self.call(host, "plugin.deactivate")
        let expired = try await self.call(host, "java.get_field", ["target": info["result"], "name": .string("pluralLangCode")])
        XCTAssertEqual(expired["error"]["code"], .string("UNAUTHORIZED"))
    }

    func testBrowserOpenURLRequiresBoundApplicationRoute() async throws {
        let provider = AyuPluginApplicationBridge()
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let probe = ScreenProbe()
        provider.bindScreen(screen: { _ = probe.read(); return screen }, presenter: { nil })
        let registry = try provider.classRegistry()
        let openURL = try XCTUnwrap(registry.adapters["org.telegram.messenger.browser.Browser"]?.staticMethods["openUrl"])
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("Synthetic Browser callback")
        }, resolve: { reference in
            guard reference == .string("context") else { throw AyuBridgeFailure("invalid_handle", "Unknown synthetic context") }
            return AyuBridgeAdapterSnapshot(className: "android.content.Context", state: screen.state)
        })
        let error = await Task.detached { () -> AyuBridgeFailure? in
            do {
                _ = try openURL([.string("context"), .string("https://example.org")], context)
                return nil
            } catch let caught { return caught as? AyuBridgeFailure }
        }.value
        XCTAssertEqual(error?.code, "SCREEN_UNAVAILABLE")
        XCTAssertEqual(error?.message, "Telegram URL route is not bound")
        XCTAssertEqual(probe.count, 0, "Missing-route detection must not synchronously query the main-thread screen source")
    }

    func testBrowserOpenURLPreparationDoesNotReadMainAndCommitQueuesEffect() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let probe = ScreenProbe()
        let opened = URLBox()
        provider.bindScreen(screen: { _ = probe.read(); return screen }, presenter: { nil }, openURL: { _, url in opened.append(url) })
        let prepared = try await self.preparedBrowserURL(provider, url: "https://example.org/queued", screen: screen)
        XCTAssertEqual(probe.count, 0, "Preparation must not synchronously query the main-thread screen source")
        XCTAssertTrue(opened.values().isEmpty)
        prepared.commit(.null)
        XCTAssertEqual(probe.count, 0)
        XCTAssertTrue(opened.values().isEmpty, "Commit must enqueue the route even when called on main")
        await self.flushMain()
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(opened.values(), ["https://example.org/queued"])

        let invalidated = try await self.preparedBrowserURL(provider, url: "https://example.org/invalidated", screen: screen)
        invalidated.commit(.null)
        provider.invalidatePresentations()
        await self.flushMain()
        XCTAssertEqual(opened.values(), ["https://example.org/queued"])

        provider.bindScreen(screen: { screen }, presenter: { nil })
        do {
            _ = try await self.preparedBrowserURL(provider, url: "https://example.org/unbound", screen: screen)
            XCTFail("Rebinding without a route must revoke route availability")
        } catch let failure as AyuBridgeFailure {
            XCTAssertEqual(failure.code, "SCREEN_UNAVAILABLE")
        }
    }

    func testPreparedBrowserOpenURLRollsBackAndRevokesOnOwnerScreenAndAccountChanges() async throws {
        let provider = AyuPluginApplicationBridge()
        let originalAccount = AyuPluginAccountSnapshot(index: 3, identity: UUID(), userID: 42)
        provider.updateAccounts([originalAccount], selected: 3)
        let originalScreen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 3)
        let opened = URLBox()
        let currentScreen = ScreenBox(originalScreen)
        provider.bindScreen(screen: { currentScreen.get() }, presenter: { nil }, openURL: { _, url in opened.append(url) })

        let rolledBack = try await self.preparedBrowserURL(provider, url: "https://example.org/rollback", screen: originalScreen)
        rolledBack.rollback()
        rolledBack.commit(.null)
        await self.flushMain()
        XCTAssertTrue(opened.values().isEmpty)

        let detached = try await self.preparedBrowserURL(provider, url: "https://example.org/detached", screen: originalScreen)
        provider.detach(pluginID: "alpha")
        detached.commit(.null)
        await self.flushMain()
        XCTAssertTrue(opened.values().isEmpty)

        let oldGeneration = try await self.preparedBrowserURL(provider, url: "https://example.org/old-generation", screen: originalScreen)
        provider.detach(pluginID: "alpha")
        let newGeneration = try await self.preparedBrowserURL(provider, url: "https://example.org/new-generation", screen: originalScreen)
        oldGeneration.commit(.null)
        newGeneration.commit(.null)
        await self.flushMain()
        XCTAssertEqual(opened.values(), ["https://example.org/new-generation"])

        let staleScreen = try await self.preparedBrowserURL(provider, url: "https://example.org/stale-screen", screen: originalScreen)
        let nextScreen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 3)
        staleScreen.commit(.null)
        currentScreen.set(nextScreen)
        await self.flushMain()
        XCTAssertEqual(opened.values(), ["https://example.org/new-generation"])

        let staleAccount = try await self.preparedBrowserURL(provider, url: "https://example.org/stale-account", screen: nextScreen)
        let replacement = AyuPluginAccountSnapshot(index: 3, identity: UUID(), userID: 42)
        provider.updateAccounts([replacement], selected: 3)
        staleAccount.commit(.null)
        await self.flushMain()
        XCTAssertEqual(opened.values(), ["https://example.org/new-generation"])
    }

    func testAndroidUtilitiesRunOnUIThreadSchedulesOwnedRunnable() async throws {
        let provider = AyuPluginApplicationBridge()
        let delivered = XCTestExpectation(description: "AndroidUtilities runnable callbacks")
        delivered.expectedFulfillmentCount = 2
        delivered.assertForOverFulfill = true
        let host = self.host(provider, registry: try provider.classRegistry(), callback: { owner, callbackID, arguments in
            XCTAssertEqual(owner, "alpha")
            XCTAssertEqual(callbackID, "android-utilities-run")
            XCTAssertTrue(arguments.isEmpty)
            delivered.fulfill()
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", ["generation": .string("android-utilities-generation")])

        let runnable = try await self.call(host, "java.proxy", [
            "interfaces": .array([.string("java.lang.Runnable")]),
            "callbacks": .object(["run": .object(["$callback": .string("android-utilities-run")])])
        ])
        let utilities: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.AndroidUtilities")])

        let invalidDelay = try await self.invoke(host, utilities, "runOnUIThread", args: [runnable["result"], .integer(-1)])
        XCTAssertEqual(invalidDelay["error"]["code"], .string("INVALID_ARGUMENTS"))
        let excessiveDelay = try await self.invoke(host, utilities, "runOnUIThread", args: [runnable["result"], .integer(60_001)])
        XCTAssertEqual(excessiveDelay["error"]["code"], .string("INVALID_ARGUMENTS"))
        let badCallback = try await self.invoke(host, utilities, "runOnUIThread", args: [.integer(1)])
        XCTAssertEqual(badCallback["error"]["code"], .string("INVALID_ARGUMENTS"))

        let immediate = try await self.invoke(host, utilities, "runOnUIThread", args: [runnable["result"]])
        XCTAssertEqual(immediate["result"], .null)
        let delayed = try await self.invoke(host, utilities, "runOnUIThread", args: [runnable["result"], .integer(5)])
        XCTAssertEqual(delayed["result"], .null)
        let waitResult = await XCTWaiter.fulfillment(of: [delivered], timeout: 1.0)
        XCTAssertEqual(waitResult, .completed)

        let unsupportedCancellation = try await self.invoke(host, utilities, "cancelRunOnUIThread", args: [runnable["result"]])
        XCTAssertEqual(unsupportedCancellation["error"]["code"], .string("UNSUPPORTED_API"))
        _ = try await self.call(host, "plugin.deactivate", ["generation": .string("android-utilities-generation")])
    }

    func testFeedbackFactoriesRejectWrongTypesAndPreserveCreationScreen() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        provider.bindScreen(screen: { screen }, presenter: { nil })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let factoryClass: AyuBridgeValue = .object(["class_name": .string("org.telegram.ui.Components.BulletinFactory")])
        let toastClass: AyuBridgeValue = .object(["class_name": .string("android.widget.Toast")])
        let fragment = try await self.client(host, "get_last_fragment")
        let context = try await self.invoke(host, fragment["result"], "getContext")
        let factory = try await self.invoke(host, factoryClass, "of", args: [fragment["result"]])
        let success = try await self.invoke(host, factory["result"], "createSuccessBulletin", args: [.string("Success")])
        let unseen = try await self.invoke(host, success["result"], "isShowing")
        XCTAssertEqual(unseen["result"], .bool(false))
        let wrong = try await self.invoke(host, factoryClass, "of", args: [.integer(7)])
        XCTAssertNotNil(wrong["error"]["code"].string)
        let toast = try await self.invoke(host, toastClass, "makeText", args: [context["result"], .string("Toast"), .integer(1)])
        XCTAssertEqual(toast["result"]["$class"], .string("android.widget.Toast"))
        let next = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        provider.bindScreen(screen: { next }, presenter: { nil })
        for target in [success["result"], toast["result"]] {
            let stale = try await self.invoke(host, target, "show")
            XCTAssertEqual(stale["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        }
        let staleFactory = try await self.invoke(host, factory["result"], "createErrorBulletin", args: [.string("Stale")])
        XCTAssertEqual(staleFactory["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        let staleToast = try await self.invoke(host, toastClass, "makeText", args: [context["result"], .string("Stale")])
        XCTAssertEqual(staleToast["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        let photo: AyuBridgeValue = .object(["class_name": .string("org.telegram.ui.PhotoViewer")])
        let unsupported = try await self.invoke(host, photo, "getInstance")
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testTrackedBulletinStyleDurationActualVisibilityAndInvalidation() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true; provider.invalidatePresentations() }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let factoryClass: AyuBridgeValue = .object(["class_name": .string("org.telegram.ui.Components.BulletinFactory")])
        let factory = try await self.invoke(host, factoryClass, "global")
        let bulletin = try await self.invoke(host, factory["result"], "createSuccessBulletin", args: [.string("Success")])
        for duration in [AyuBridgeValue.integer(0), .integer(10_001), .bool(true), .number(1.5)] {
            let bad = try await self.invoke(host, bulletin["result"], "setDuration", args: [duration])
            XCTAssertEqual(bad["error"]["code"], .string("INVALID_ARGUMENTS"))
        }
        _ = try await self.invoke(host, bulletin["result"], "setDuration", args: [.integer(10_000)])
        let shown = try await self.invoke(host, bulletin["result"], "show")
        XCTAssertEqual(shown["result"], .null)
        await self.flushMain()
        let visible = try await self.invoke(host, bulletin["result"], "isShowing")
        XCTAssertEqual(visible["result"], .bool(true))
        XCTAssertTrue(presenter.view.subviews.contains { $0.backgroundColor == .systemGreen })
        let duplicate = try await self.invoke(host, bulletin["result"], "show")
        XCTAssertEqual(duplicate["error"]["code"], .string("INVALID_STATE"))
        let runningDuration = try await self.invoke(host, bulletin["result"], "setDuration", args: [.integer(1)])
        XCTAssertEqual(runningDuration["error"]["code"], .string("INVALID_STATE"))
        provider.invalidatePresentations()
        let hidden = try await self.invoke(host, bulletin["result"], "isShowing")
        XCTAssertEqual(hidden["result"], .bool(false))
        XCTAssertFalse(presenter.view.subviews.contains { $0.backgroundColor == .systemGreen })
        _ = try await self.invoke(host, bulletin["result"], "setDuration", args: [.integer(1)])
        _ = try await self.invoke(host, bulletin["result"], "show")
        let expired = XCTestExpectation(description: "native expiry deadline")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { expired.fulfill() }
        _ = await XCTWaiter.fulfillment(of: [expired], timeout: 1)
        let noLongerVisible = try await self.invoke(host, bulletin["result"], "isShowing")
        XCTAssertEqual(noLongerVisible["result"], .bool(false))
    }

    func testBulletinButtonCallbackIsOneShotAndRevokedOnUnload() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true; provider.invalidatePresentations() }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let delivered = XCTestExpectation(description: "one callback")
        delivered.expectedFulfillmentCount = 1
        delivered.assertForOverFulfill = true
        var limits = AyuPluginBridgeLimits()
        limits.callbacksPerPlugin = 1
        let host = self.host(provider, registry: try provider.classRegistry(), limits: limits, callback: { _, callback, args in
            XCTAssertEqual(callback, "button:1")
            XCTAssertEqual(args, [])
            delivered.fulfill()
        })
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", ["generation": .string("button")])
        let config: [String: AyuBridgeValue] = ["style": .string("simple"), "text": .string("Action"), "duration_ms": .integer(10_000),
            "button": .object(["text": .string("Run"), "on_click": .object(["$callback": .string("button:1")])])]
        let result = try await self.call(host, "ui.present", ["kind": .string("bulletin"), "config": .object(config)])
        XCTAssertEqual(result["result"], .null)
        await self.flushMain()
        let button = try XCTUnwrap(presenter.view.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }.first)
        button.sendActions(for: .touchUpInside)
        button.sendActions(for: .touchUpInside)
        _ = await XCTWaiter.fulfillment(of: [delivered], timeout: 1)
        XCTAssertNil(button.window)
        var nextConfig = config
        nextConfig["button"] = .object(["text": .string("New"), "on_click": .object(["$callback": .string("new:1")])])
        let quota = try await self.call(host, "ui.present", ["kind": .string("bulletin"), "config": .object(nextConfig)])
        XCTAssertEqual(quota["error"]["code"], .string("RESOURCE_LIMIT"))
        XCTAssertTrue(presenter.view.subviews.isEmpty)
        _ = try await self.call(host, "ui.present", ["kind": .string("bulletin"), "config": .object(config)])
        await self.flushMain()
        let revokedButton = try XCTUnwrap(presenter.view.subviews.flatMap(\.subviews).compactMap { $0 as? UIButton }.first)
        _ = try await self.call(host, "plugin.deactivate", ["generation": .string("button")])
        await self.flushMain()
        XCTAssertNil(revokedButton.window)
        revokedButton.sendActions(for: .touchUpInside)
        await self.flushMain()
        try await self.authorize(host)
        _ = try await self.call(host, "plugin.activate", ["generation": .string("new")])
        let fresh = try await self.call(host, "ui.present", ["kind": .string("bulletin"), "config": .object(nextConfig)])
        XCTAssertEqual(fresh["result"], .null, "Unloading must release the old callback quota")
        _ = try await self.call(host, "plugin.deactivate", ["generation": .string("new")])
        await self.flushMain()
    }

    func testBulletinButtonAndDurationSchemaRejectBeforeReservation() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in
            throw AyuBridgeFailure("resource_limit", "Synthetic callback quota")
        }, resolve: { _ in throw AyuBridgeFailure.unsupported("synthetic") })
        let codes = await Task.detached { () -> [String] in
            var results: [String] = []
            let variants: [[String: AyuBridgeValue]] = [
                ["duration_ms": .integer(0)], ["duration_ms": .integer(10_001)], ["duration_ms": .bool(true)],
                ["button": .object(["text": .string("Missing callback")])],
                ["button": .object(["text": .string(""), "on_click": .null])],
                ["button": .object(["text": .string("Extra"), "on_click": .null, "icon": .integer(1)])],
                ["button": .object(["text": .string("Quota"), "on_click": .object(["$callback": .string("button:1")])])]
            ]
            for extra in variants {
                var config: [String: AyuBridgeValue] = ["style": .string("simple"), "text": .string("Synthetic")]
                config.merge(extra) { _, new in new }
                do {
                    let pending = try provider.prepareCall(pluginID: "alpha", operation: "ui.present", arguments: ["kind": .string("bulletin"), "config": .object(config)], context: context)
                    pending.rollback(); results.append("SUCCESS")
                } catch { results.append((error as? AyuBridgeFailure)?.code ?? "UNEXPECTED_ERROR") }
            }
            return results
        }.value
        XCTAssertEqual(codes, Array(repeating: "INVALID_ARGUMENTS", count: 6) + ["RESOURCE_LIMIT"])
    }

    func testCustomDialogBulletinRejectsFragmentAndUnimplementedOptions() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true; provider.invalidatePresentations() }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let fragment = try await self.client(host, "get_last_fragment")
        let content = try await self.call(host, "java.construct", ["class_name": .string("android.widget.LinearLayout"), "args": .array([]), "kwargs": .object([:])])
        let customViewDialog = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object([
            "title": .string("Synthetic"), "view": content["result"],
            "positive_button": .object(["text": .string("Close"), "on_click": .null])
        ])])
        XCTAssertEqual(customViewDialog["error"]["code"], .string("UNSUPPORTED_API"))
        await self.flushMain()
        let extras: [[String: AyuBridgeValue]] = [["fragment": fragment["result"]], ["duration_ms": .integer(5000)],
                      ["button": .object(["text": .string("Run"), "on_click": .null])], ["icon": .integer(7)]]
        for extra in extras {
            var config: [String: AyuBridgeValue] = ["style": .string("simple"), "text": .string("Synthetic")]
            config.merge(extra) { _, new in new }
            let rejected = try await self.call(host, "ui.present", ["kind": .string("bulletin"), "config": .object(config)])
            XCTAssertEqual(rejected["error"]["code"], .string("UNSUPPORTED_API"))
        }
        let plain = try await self.call(host, "ui.present", ["kind": .string("bulletin"), "config": .object([
            "style": .string("simple"), "text": .string("Dialog feedback"), "fragment": .null
        ])])
        XCTAssertEqual(plain["result"], .null)
        _ = try await self.call(host, "plugin.deactivate")
        await self.flushMain()
    }

    func testPreparedFeedbackCannotAppearAfterDetach() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let registry = try provider.classRegistry()
        let factory = try XCTUnwrap(registry.adapters["org.telegram.ui.Components.BulletinFactory"])
        let bulletin = try XCTUnwrap(registry.adapters["org.telegram.ui.Components.Bulletin"])
        let global = try XCTUnwrap(factory.staticMethods["global"])
        let create = try XCTUnwrap(factory.methods["createSuccessBulletin"])
        let show = try XCTUnwrap(bulletin.methods["show"])
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in throw AyuBridgeFailure.unsupported("synthetic") }, resolve: { _ in throw AyuBridgeFailure.unsupported("synthetic") })
        let pending = try await Task.detached { () throws -> AyuBridgeProviderResult in
            guard case let .instance(_, factoryState) = try global([], context) else {
                throw AyuBridgeFailure("test_failure", "Expected native descriptors")
            }
            var factoryFields = factoryState
            guard case let .instance(_, descriptor) = try create(&factoryFields, [.string("Must not appear")], context) else {
                throw AyuBridgeFailure("test_failure", "Expected bulletin descriptor")
            }
            var state = descriptor
            guard case let .prepared(prepared) = try show(&state, [], context) else {
                throw AyuBridgeFailure("test_failure", "Expected prepared feedback")
            }
            guard state == descriptor else {
                prepared.rollback()
                throw AyuBridgeFailure("test_failure", "Showing feedback must not grow host adapter state")
            }
            return prepared
        }.value
        provider.detach(pluginID: "alpha")
        pending.commit(.null)
        await self.flushMain()
        XCTAssertTrue(presenter.view.subviews.isEmpty)
    }

    func testUnboundApplicationFailsClosedAndDoesNotInventClients() async throws {
        let provider = AyuPluginApplicationBridge()
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let missing = try await self.client(host, "get_selected_account")
        XCTAssertEqual(missing["error"]["code"], .string("ACCOUNT_UNAVAILABLE"))
        let noScreen = try await self.client(host, "get_last_fragment")
        XCTAssertEqual(noScreen["result"], .null)
        let unavailable = try await self.client(host, "get_messages_controller")
        XCTAssertEqual(unavailable["error"]["code"], .string("ACCOUNT_UNAVAILABLE"))
        let unsupported = try await self.client(host, "get_send_messages_helper")
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))
        let noPresentation = try await self.call(host, "ui.present", ["kind": .string("alert"), "config": .object(["title": .string("Synthetic")])])
        XCTAssertEqual(noPresentation["error"]["code"], .string("SCREEN_UNAVAILABLE"))
    }

    func testClipboardAdapterIsBoundedAndRequiresVisibleScreen() async throws {
        let provider = AyuPluginApplicationBridge()
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let oversized = try await self.call(host, "client.call", [
            "name": .string("copy_to_clipboard"),
            "args": .array([.string(String(repeating: "x", count: 65_537))]),
            "kwargs": .object([:])
        ])
        XCTAssertEqual(oversized["error"]["code"], .string("INVALID_ARGUMENTS"))
        let unavailable = try await self.call(host, "client.call", [
            "name": .string("copy_to_clipboard"),
            "args": .array([.string("synthetic clipboard value")]),
            "kwargs": .object([:])
        ])
        XCTAssertEqual(unavailable["error"]["code"], .string("SCREEN_UNAVAILABLE"))
    }

    func testClipboardDeferredEffectIsOneShotAndRevokedOnDetach() async throws {
        let captured = ClipboardBox()
        let provider = AyuPluginApplicationBridge(clipboardWriter: { captured.append($0) })
        let account = AyuPluginAccountSnapshot(index: 2, identity: UUID(), userID: 42)
        provider.updateAccounts([account], selected: 2)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 2, dialogID: 42)
        provider.bindScreen(screen: { screen }, presenter: { nil })
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("synthetic")
        }, resolve: { _ in throw AyuBridgeFailure.unsupported("synthetic") })
        let arguments: [String: AyuBridgeValue] = ["name": .string("copy_to_clipboard"),
            "args": .array([.string("safe text")]), "kwargs": .object([:])]
        let prepared = try await Task.detached {
            try provider.prepareCall(pluginID: "alpha", operation: "client.call", arguments: arguments, context: context)
        }.value
        prepared.commit(.null)
        prepared.commit(.null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["safe text"], "A prepared effect must be consumed only once")

        let stale = try await Task.detached {
            try provider.prepareCall(pluginID: "alpha", operation: "client.call", arguments: arguments, context: context)
        }.value
        provider.detach(pluginID: "alpha")
        stale.commit(.null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["safe text"], "Unload must revoke prepared clipboard work")

        let replacedAccount = AyuPluginAccountSnapshot(index: 2, identity: UUID(), userID: 42)
        provider.updateAccounts([replacedAccount], selected: 2)
        let replacementScreen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 2, dialogID: 42)
        provider.bindScreen(screen: { replacementScreen }, presenter: { nil })
        let afterScreenReplacement = try await Task.detached {
            try provider.prepareCall(pluginID: "alpha", operation: "client.call", arguments: arguments, context: context)
        }.value
        let nextScreen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 2, dialogID: 42)
        provider.bindScreen(screen: { nextScreen }, presenter: { nil })
        afterScreenReplacement.commit(.null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["safe text"], "A replacement screen must invalidate captured actions")

        provider.bindScreen(screen: { replacementScreen }, presenter: { nil })
        let afterAccountReplacement = try await Task.detached {
            try provider.prepareCall(pluginID: "alpha", operation: "client.call", arguments: arguments, context: context)
        }.value
        provider.updateAccounts([], selected: nil)
        afterAccountReplacement.commit(.null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["safe text"], "Removed accounts must invalidate captured actions")
    }

    func testAndroidUtilitiesAddToClipboardAliasUsesBoundedDeferredClipboard() async throws {
        let captured = ClipboardBox()
        let provider = AyuPluginApplicationBridge(clipboardWriter: { captured.append($0) })
        let account = AyuPluginAccountSnapshot(index: 1, identity: UUID(), userID: 42)
        provider.updateAccounts([account], selected: 1)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 1)
        provider.bindScreen(screen: { screen }, presenter: { nil })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let utilities: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.AndroidUtilities")])

        let copied = try await self.invoke(host, utilities, "addToClipboard", args: [.string("exact alias text")])
        XCTAssertEqual(copied["result"], .null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["exact alias text"])

        let wrongArity = try await self.invoke(host, utilities, "addToClipboard")
        XCTAssertEqual(wrongArity["error"]["code"], .string("INVALID_ARGUMENTS"))
        let wrongType = try await self.invoke(host, utilities, "addToClipboard", args: [.integer(1)])
        XCTAssertEqual(wrongType["error"]["code"], .string("INVALID_ARGUMENTS"))
        let oversized = try await self.invoke(host, utilities, "addToClipboard", args: [.string(String(repeating: "x", count: 65_537))])
        XCTAssertEqual(oversized["error"]["code"], .string("INVALID_ARGUMENTS"))
        XCTAssertEqual(captured.values(), ["exact alias text"])

        let registry = try provider.classRegistry()
        let addToClipboard = try XCTUnwrap(registry.adapters["org.telegram.messenger.AndroidUtilities"]?.staticMethods["addToClipboard"])
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in
            throw AyuBridgeFailure.unsupported("synthetic clipboard callback")
        }, resolve: { _ in
            throw AyuBridgeFailure.unsupported("synthetic clipboard reference")
        })
        let rolledBack = try await Task.detached {
            guard case let .prepared(result) = try addToClipboard([.string("rolled back")], context) else {
                throw AyuBridgeFailure("test_failure", "Expected prepared clipboard result")
            }
            return result
        }.value
        rolledBack.rollback()
        rolledBack.commit(.null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["exact alias text"])

        let stale = try await Task.detached {
            guard case let .prepared(result) = try addToClipboard([.string("stale generation")], context) else {
                throw AyuBridgeFailure("test_failure", "Expected prepared clipboard result")
            }
            return result
        }.value
        provider.detach(pluginID: "alpha")
        let current = try await Task.detached {
            guard case let .prepared(result) = try addToClipboard([.string("current generation")], context) else {
                throw AyuBridgeFailure("test_failure", "Expected prepared clipboard result")
            }
            return result
        }.value
        stale.commit(.null)
        current.commit(.null)
        await self.flushMain()
        XCTAssertEqual(captured.values(), ["exact alias text", "current generation"])
    }

    func testSelectedAccountStaticFieldIsLiveAndOwnedConfigHasExactInt64UserID() async throws {
        let provider = AyuPluginApplicationBridge()
        let first = AyuPluginAccountSnapshot(index: 7, identity: UUID(), userID: Int64.max - 7, firstName: "Synthetic")
        let second = AyuPluginAccountSnapshot(index: 9, identity: UUID(), userID: 42)
        provider.updateAccounts([first, second], selected: 7)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let target: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger.UserConfig")])
        let initial = try await self.call(host, "java.member", ["target": target, "name": .string("selectedAccount")])
        XCTAssertEqual(initial["result"]["value"], .integer(7))
        let config = try await self.client(host, "get_user_config")
        XCTAssertNotNil(config["result"]["$handle"].string)
        let userID = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(userID["result"], .integer(Int64.max - 7))
        provider.updateAccounts([first, second], selected: 9)
        let updated = try await self.call(host, "java.get_private_field", ["target": target, "name": .string("selectedAccount")])
        XCTAssertEqual(updated["result"], .integer(9))
        let stillFirst = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(stillFirst["result"], .integer(first.userID))
    }

    func testLogoutSlotIdentityAndPluginOwnershipRejectOldConfig() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 3, identity: UUID(), userID: 11)], selected: 3)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host); try await self.authorize(host, owner: "bravo")
        let config = try await self.client(host, "get_user_config")
        let foreign = try await self.invoke(host, config["result"], "getClientUserId", owner: "bravo")
        XCTAssertEqual(foreign["error"]["code"], .string("INVALID_HANDLE"))
        provider.updateAccounts([], selected: nil)
        let removed = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(removed["error"]["code"], .string("ACCOUNT_UNAVAILABLE"))
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 3, identity: UUID(), userID: 12)], selected: 3)
        let replaced = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(replaced["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testProfileIsNarrowReadOnlyAndClientOptionsAreStrict() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 13, firstName: "A", lastName: "B", username: "synthetic")], selected: 0)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let config = try await self.client(host, "get_user_config")
        let profile = try await self.invoke(host, config["result"], "getCurrentUser")
        let first = try await self.call(host, "java.get_field", ["target": profile["result"], "name": .string("first_name")])
        XCTAssertEqual(first["result"], .string("A"))
        for field in ["phone", "access_hash", "accountIdentity"] {
            let rejected = try await self.call(host, "java.get_private_field", ["target": profile["result"], "name": .string(field)])
            XCTAssertEqual(rejected["error"]["code"], .string("UNSUPPORTED_API"))
        }
        let write = try await self.call(host, "java.set_field", ["target": profile["result"], "name": .string("id"), "value": .integer(99)])
        XCTAssertEqual(write["error"]["code"], .string("UNSUPPORTED_API"))
        let malformed = try await self.client(host, "get_user_config", kwargs: ["account": .bool(true)])
        XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
    }

    func testDynamicStaticFieldsRejectAmbiguityAndMalformedResults() async throws {
        let name = "example.Dynamic"
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: name, constants: ["value": .integer(1)], staticFields: ["value": { _ in .value(.null) }])]))
        XCTAssertThrowsError(try AyuBridgeClassRegistry([AyuBridgeClassAdapter(name: name, staticMethods: ["value": { _, _ in .value(.null) }], staticFields: ["value": { _ in .value(.null) }])]))
        let registry = try AyuBridgeClassRegistry.standard.adding([AyuBridgeClassAdapter(name: name, staticFields: ["bad": { _ in .value(.object(["$handle": .string("forged"), "$class": .string(name)])) }])])
        let host = self.host(AyuUnsupportedPluginHostProvider(), registry: registry)
        try await self.authorize(host)
        for operation in ["java.member", "java.get_field"] {
            let rejected = try await self.call(host, operation, ["target": .object(["class_name": .string(name)]), "name": .string("bad")])
            XCTAssertEqual(rejected["error"]["code"], .string("INVALID_HANDLE"))
        }
    }

    func testAccountInstanceChildrenStayOnTheirAccountAndExpireWithIt() async throws {
        let provider = AyuPluginApplicationBridge()
        let first = AyuPluginAccountSnapshot(index: 4, identity: UUID(), userID: Int64.max - 3, firstName: "First")
        let second = AyuPluginAccountSnapshot(index: 8, identity: UUID(), userID: 88, firstName: "Second")
        provider.updateAccounts([first, second], selected: 8)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let instance = try await self.client(host, "get_account_instance", kwargs: ["account": .integer(4)])
        XCTAssertEqual(instance["result"]["$class"], .string("org.telegram.messenger.AccountInstance"))
        let slot = try await self.invoke(host, instance["result"], "getCurrentAccount")
        XCTAssertEqual(slot["result"], .integer(4))
        let config = try await self.invoke(host, instance["result"], "getUserConfig")
        let userID = try await self.invoke(host, config["result"], "getClientUserId")
        XCTAssertEqual(userID["result"], .integer(first.userID))
        let controller = try await self.invoke(host, instance["result"], "getMessagesController")
        let user = try await self.invoke(host, controller["result"], "getUser", args: [.integer(first.userID)])
        let id = try await self.call(host, "java.get_field", ["target": user["result"], "name": .string("id")])
        XCTAssertEqual(id["result"], .integer(first.userID))
        let other = try await self.invoke(host, controller["result"], "getUser", args: [.integer(second.userID)])
        XCTAssertEqual(other["result"], .null)
        let request = try await self.invoke(host, instance["result"], "getConnectionsManager")
        XCTAssertEqual(request["error"]["code"], .string("UNSUPPORTED_API"))
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 4, identity: UUID(), userID: 99), second], selected: 8)
        for (target, method) in [(instance["result"], "getCurrentAccount"), (config["result"], "getClientUserId")] {
            let expired = try await self.invoke(host, target, method)
            XCTAssertEqual(expired["error"]["code"], .string("INVALID_HANDLE"))
        }
        let expiredController = try await self.invoke(host, controller["result"], "getUser", args: [.integer(first.userID)])
        XCTAssertEqual(expiredController["error"]["code"], .string("INVALID_HANDLE"))
    }

    func testVisibleChatLookupPreservesInt64AndRevokesFragmentOnRebinding() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let chatID = Int64.max - 2
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0, dialogID: -chatID, isGroup: true)
        provider.bindScreen(screen: { screen }, presenter: { nil })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let fragment = try await self.client(host, "get_last_fragment")
        let dialog = try await self.invoke(host, fragment["result"], "getDialogId")
        XCTAssertEqual(dialog["result"], .integer(-chatID))
        let controller = try await self.invoke(host, fragment["result"], "getMessagesController")
        let chat = try await self.invoke(host, controller["result"], "getChat", args: [.integer(chatID)])
        let id = try await self.call(host, "java.get_field", ["target": chat["result"], "name": .string("id")])
        XCTAssertEqual(id["result"], .integer(chatID))
        let absent = try await self.invoke(host, controller["result"], "getChat", args: [.integer(1)])
        XCTAssertEqual(absent["result"], .null)
        let account = try await self.invoke(host, fragment["result"], "getAccountInstance")
        let slot = try await self.invoke(host, account["result"], "getCurrentAccount")
        XCTAssertEqual(slot["result"], .integer(0))
        provider.bindScreen(screen: { nil }, presenter: { nil })
        let stale = try await self.invoke(host, fragment["result"], "getMessagesController")
        XCTAssertEqual(stale["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        let noVisibleChat = try await self.invoke(host, controller["result"], "getChat", args: [.integer(chatID)])
        XCTAssertEqual(noVisibleChat["result"], .null)
        let invalidScreen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0, dialogID: Int64.min)
        provider.bindScreen(screen: { invalidScreen }, presenter: { nil })
        let invalidChat = try await self.invoke(host, controller["result"], "getChat", args: [.integer(chatID)])
        XCTAssertEqual(invalidChat["result"], .null)
    }

    func testStaticFactoriesAndNotificationHelperMatchSDKArguments() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 2, identity: UUID(), userID: 13)], selected: 2)
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        for name in ["AccountInstance", "MessagesController"] {
            let target: AyuBridgeValue = .object(["class_name": .string("org.telegram.messenger." + name)])
            let instance = try await self.invoke(host, target, "getInstance", args: [.integer(2)])
            XCTAssertEqual(instance["result"]["$class"], .string("org.telegram.messenger." + name))
            let malformed = try await self.invoke(host, target, "getInstance", args: [.bool(true)])
            XCTAssertEqual(malformed["error"]["code"], .string("INVALID_ARGUMENTS"))
        }
        let missingProfile = try await self.client(host, "get_user_config")
        let user = try await self.invoke(host, missingProfile["result"], "getCurrentUser")
        XCTAssertEqual(user["error"]["code"], .string("DATA_UNAVAILABLE"))
        let global = try await self.client(host, "get_notification_center", kwargs: ["account": .null])
        XCTAssertEqual(global["result"]["$class"], .string("org.telegram.messenger.NotificationCenter"))
        let scoped = try await self.client(host, "get_notification_center", kwargs: ["account": .integer(2)])
        XCTAssertEqual(scoped["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testThemeColorsFailClosedWithoutABoundPresentationTheme() async throws {
        let provider = AyuPluginApplicationBridge()
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let theme: AyuBridgeValue = .object(["class_name": .string("org.telegram.ui.ActionBar.Theme")])
        for key in [Int64(0), -1, 1, 49, Int64.max] {
            let unavailable = try await self.invoke(host, theme, "getColor", args: [.integer(key)])
            XCTAssertEqual(unavailable["error"]["code"], .string("UNSUPPORTED_API"))
        }
        let unavailable = try await self.invoke(host, theme, "isCurrentThemeDark")
        XCTAssertEqual(unavailable["error"]["code"], .string("UNSUPPORTED_API"))
    }

    func testDisplayMetricsAndThemeUseTheExplicitPresentationWindow() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        presenter.overrideUserInterfaceStyle = .dark
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        let fragment = try await self.client(host, "get_last_fragment")
        let context = try await self.invoke(host, fragment["result"], "getContext")
        let resources = try await self.invoke(host, context["result"], "getResources")
        let metrics = try await self.invoke(host, resources["result"], "getDisplayMetrics")
        let configuration = try await self.invoke(host, resources["result"], "getConfiguration")
        XCTAssertEqual(configuration["result"]["$class"], .string("android.content.res.Configuration"))
        let orientation = try await self.call(host, "java.get_field", ["target": configuration["result"], "name": .string("orientation")])
        let expectedOrientation: Int64
        switch window.windowScene?.interfaceOrientation ?? .unknown {
        case .portrait, .portraitUpsideDown: expectedOrientation = 1
        case .landscapeLeft, .landscapeRight: expectedOrientation = 2
        case .unknown: expectedOrientation = 0
        @unknown default: expectedOrientation = 0
        }
        XCTAssertEqual(orientation["result"], .integer(expectedOrientation))
        let configurationClass: AyuBridgeValue = .object(["class_name": .string("android.content.res.Configuration")])
        for (name, value) in [("ORIENTATION_UNDEFINED", Int64(0)), ("ORIENTATION_PORTRAIT", 1), ("ORIENTATION_LANDSCAPE", 2)] {
            let constant = try await self.call(host, "java.member", ["target": configurationClass, "name": .string(name)])
            XCTAssertEqual(constant["result"]["value"], .integer(value))
        }
        let orientationWrite = try await self.call(host, "java.set_field", ["target": configuration["result"], "name": .string("orientation"), "value": .integer(2)])
        XCTAssertEqual(orientationWrite["error"]["code"], .string("UNSUPPORTED_API"))
        let density = try await self.call(host, "java.get_field", ["target": metrics["result"], "name": .string("density")])
        XCTAssertEqual(density["result"].number, Double(window.screen.scale))
        let typedValue: AyuBridgeValue = .object(["class_name": .string("android.util.TypedValue")])
        let pixels = try await self.invoke(host, typedValue, "applyDimension", args: [.integer(1), .number(12), metrics["result"]])
        XCTAssertEqual(pixels["result"].number, 12 * Double(window.screen.scale))
        let densityIndependentPixels = try await self.invoke(host, typedValue, "applyDimension", args: [.integer(0), .number(12), metrics["result"]])
        XCTAssertEqual(densityIndependentPixels["result"].number, 12)
        let scaledPixels = try await self.invoke(host, typedValue, "applyDimension", args: [.integer(2), .number(12), metrics["result"]])
        XCTAssertEqual(scaledPixels["result"].number, 12 * Double(window.screen.scale))
        let unsupportedUnit = try await self.invoke(host, typedValue, "applyDimension", args: [.integer(3), .number(12), metrics["result"]])
        XCTAssertEqual(unsupportedUnit["error"]["code"], .string("UNSUPPORTED_API"))
        let invalidMetrics = try await self.invoke(host, typedValue, "applyDimension", args: [.integer(1), .number(12), .null])
        XCTAssertNotNil(invalidMetrics["error"]["code"].string)
        // Theme colours come from the bound presentation theme, not from the window's traits.
        provider.presentation.bind(palette: { AyuPluginThemePalette(isDark: true, isNight: false, colors: [.listItemBackground: 0xFFFF_FFFF]) }, language: nil)
        let theme: AyuBridgeValue = .object(["class_name": .string("org.telegram.ui.ActionBar.Theme")])
        let dark = try await self.invoke(host, theme, "isCurrentThemeDark")
        XCTAssertEqual(dark["result"], .bool(true))
        let white = try await self.invoke(host, theme, "getColor", args: [.integer(49)])
        XCTAssertEqual(white["result"], .integer(-1))
        provider.bindScreen(screen: { nil }, presenter: { nil })
        let staleConfiguration = try await self.invoke(host, resources["result"], "getConfiguration")
        XCTAssertEqual(staleConfiguration["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        let expiredConfiguration = try await self.call(host, "java.get_field", ["target": configuration["result"], "name": .string("orientation")])
        XCTAssertEqual(expiredConfiguration["error"]["code"], .string("SCREEN_UNAVAILABLE"))
        let staleMetrics = try await self.invoke(host, typedValue, "applyDimension", args: [.integer(1), .number(12), metrics["result"]])
        XCTAssertEqual(staleMetrics["error"]["code"], .string("SCREEN_UNAVAILABLE"))
    }

    func testSendHookQuotaOrderOwnershipAndUnload() async throws {
        let provider = AyuPluginApplicationBridge()
        let host = self.host(provider, registry: try provider.classRegistry())
        try await self.authorize(host)
        try await self.authorize(host, owner: "bravo")
        var tokens: [AyuBridgeValue] = []
        for index in 0..<16 {
            let result = try await self.call(host, "hooks.register", ["kind": .string("send_message"), "priority": .integer(Int64(index % 2)), "callback": .object(["$callback": .string("hook-\(index)")])])
            XCTAssertNotNil(result["result"].string)
            tokens.append(result["result"])
        }
        XCTAssertEqual(provider.sendHooks().map(\.callbackID), (stride(from: 1, to: 16, by: 2).map { "hook-\($0)" }) + (stride(from: 0, to: 16, by: 2).map { "hook-\($0)" }))
        let overflow = try await self.call(host, "hooks.register", ["kind": .string("send_message"), "priority": .integer(0), "callback": .object(["$callback": .string("overflow")])])
        XCTAssertEqual(overflow["error"]["code"], .string("RESOURCE_LIMIT"))
        let foreign = try await self.call(host, "hooks.unregister", owner: "bravo", ["token": tokens[0]])
        XCTAssertEqual(foreign["error"]["code"], .string("INVALID_HANDLE"))
        XCTAssertEqual(provider.sendHooks().count, 16)
        let unsupported = try await self.call(host, "hooks.register", ["kind": .string("request"), "priority": .integer(0), "callback": .object(["$callback": .string("request")])])
        XCTAssertEqual(unsupported["error"]["code"], .string("UNSUPPORTED_API"))
        _ = try await self.call(host, "hooks.unregister", ["token": tokens[0]])
        XCTAssertEqual(provider.sendHooks().count, 15)
        _ = try await self.call(host, "plugin.deactivate")
        XCTAssertTrue(provider.sendHooks().isEmpty)
    }

    func testPreparedSendHookRollbackAndDetachCannotLeakReservations() async throws {
        let provider = AyuPluginApplicationBridge()
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in AyuBridgeNativeCallback(id: "test", sink: { _ in }) }, resolve: { _ in throw AyuBridgeFailure.unsupported("synthetic") })
        let args: [String: AyuBridgeValue] = ["kind": .string("send_message"), "priority": .integer(0), "callback": .object(["$callback": .string("test")])]
        try await Task.detached {
            for _ in 0..<20 {
                let pending = try provider.prepareCall(pluginID: "alpha", operation: "hooks.register", arguments: args, context: context)
                pending.rollback()
            }
            let pending = try provider.prepareCall(pluginID: "alpha", operation: "hooks.register", arguments: args, context: context)
            provider.detach(pluginID: "alpha")
            pending.commit(.null)
        }.value
        XCTAssertTrue(provider.sendHooks().isEmpty)
    }

    func testPreparedOldGenerationHookCannotReplaceNewGenerationHook() async throws {
        let provider = AyuPluginApplicationBridge()
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { reference in
            AyuBridgeNativeCallback(id: reference["$callback"].string ?? "", sink: { _ in })
        }, resolve: { _ in throw AyuBridgeFailure.unsupported("synthetic") })
        try await Task.detached {
            let oldArguments: [String: AyuBridgeValue] = ["kind": .string("send_message"), "priority": .integer(0), "callback": .object(["$callback": .string("old:1")])]
            let old = try provider.prepareCall(pluginID: "alpha", operation: "hooks.register", arguments: oldArguments, context: context)
            provider.detach(pluginID: "alpha")
            let newArguments: [String: AyuBridgeValue] = ["kind": .string("send_message"), "priority": .integer(0), "callback": .object(["$callback": .string("new:1")])]
            let new = try provider.prepareCall(pluginID: "alpha", operation: "hooks.register", arguments: newArguments, context: context)
            old.commit(.null)
            old.rollback()
            new.commit(.null)
        }.value
        XCTAssertEqual(provider.sendHooks().map(\.callbackID), ["new:1"])
        provider.detach(pluginID: "alpha")
    }

    func testAlertItemsMayOmitCallbackAndBulletinsValidateFragmentBeforeReserving() async throws {
        let provider = AyuPluginApplicationBridge()
        provider.updateAccounts([AyuPluginAccountSnapshot(index: 0, identity: UUID(), userID: 12)], selected: 0)
        let screen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        let presenter = UIViewController()
        let window = try self.presentationWindow(presenter)
        defer { window.isHidden = true }
        provider.bindScreen(screen: { screen }, presenter: { presenter })
        let context = AyuBridgeAdapterContext(pluginID: "alpha", resolveCallback: { _ in
            // A null listener must never be resolved as a Python callback.
            throw AyuBridgeFailure("unexpected_callback", "Synthetic callback resolver must not run")
        }, resolve: { reference in
            switch reference {
            case .string("fragment"):
                return AyuBridgeAdapterSnapshot(className: "org.telegram.ui.ActionBar.BaseFragment", state: screen.state)
            case .string("context"):
                return AyuBridgeAdapterSnapshot(className: "android.content.Context", state: screen.state)
            default:
                throw AyuBridgeFailure("invalid_handle", "Unknown synthetic reference")
            }
        })
        try await Task.detached {
            let alert: [String: AyuBridgeValue] = ["kind": .string("alert"), "config": .object([
                "items": .object(["labels": .array([.string("Synthetic item")]), "on_click": .null]), "cancelable": .bool(false)
            ])]
            let prepared = try provider.prepareCall(pluginID: "alpha", operation: "ui.present", arguments: alert, context: context)
            prepared.rollback()
            // Repeated preparation/rollback verifies that validation-only tests
            // never consume the four presentation reservations or show UIKit UI.
            for _ in 0..<8 {
                let bulletin: [String: AyuBridgeValue] = ["kind": .string("bulletin"), "config": .object([
                    "style": .string("simple"), "text": .string("Synthetic"), "fragment": .string("fragment")
                ])]
                let pending = try provider.prepareCall(pluginID: "alpha", operation: "ui.present", arguments: bulletin, context: context)
                pending.rollback()
            }
        }.value
        let wrongClassCode = await Task.detached { () -> String? in
            do {
                let arguments: [String: AyuBridgeValue] = ["kind": .string("bulletin"), "config": .object([
                    "style": .string("simple"), "text": .string("Synthetic"), "fragment": .string("context")
                ])]
                let pending = try provider.prepareCall(pluginID: "alpha", operation: "ui.present", arguments: arguments, context: context)
                pending.rollback()
                return nil
            } catch { return (error as? AyuBridgeFailure)?.code ?? "UNEXPECTED_ERROR" }
        }.value
        XCTAssertEqual(wrongClassCode, "INVALID_ARGUMENTS")
        let nextScreen = AyuPluginScreenSnapshot(identity: UUID(), accountIndex: 0)
        provider.bindScreen(screen: { nextScreen }, presenter: { presenter })
        let staleCode = await Task.detached { () -> String? in
            do {
                let arguments: [String: AyuBridgeValue] = ["kind": .string("bulletin"), "config": .object([
                    "style": .string("simple"), "text": .string("Synthetic"), "fragment": .string("fragment")
                ])]
                let pending = try provider.prepareCall(pluginID: "alpha", operation: "ui.present", arguments: arguments, context: context)
                pending.rollback()
                return nil
            } catch { return (error as? AyuBridgeFailure)?.code ?? "UNEXPECTED_ERROR" }
        }.value
        XCTAssertEqual(staleCode, "SCREEN_UNAVAILABLE")
    }

    func testProviderCannotForgeHandlesAndEffectsCommitOnlyAfterResultValidation() async throws {
        let effects = AyuTestProviderEffects()
        let provider = AyuPreparedTestProvider(effects: effects)
        let host = self.host(provider)
        try await self.authorize(host)
        let bad = try await self.client(host, "bad")
        XCTAssertEqual(bad["error"]["code"], .string("INVALID_HANDLE"))
        XCTAssertEqual(effects.counts, [0, 1])
        let good = try await self.client(host, "good")
        XCTAssertEqual(good["result"]["$class"], .string("java.lang.Long"))
        XCTAssertNotNil(good["result"]["$handle"].string)
        XCTAssertEqual(effects.counts, [1, 1])
        let value = try await self.invoke(host, good["result"], "longValue")
        XCTAssertEqual(value["result"], .integer(Int64.max))
    }
}

private final class AyuTestProviderEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var values = [0, 0]
    var counts: [Int] { self.lock.lock(); defer { self.lock.unlock() }; return self.values }
    func add(_ index: Int) { self.lock.lock(); self.values[index] += 1; self.lock.unlock() }
}
private final class AyuPreparedTestProvider: AyuPluginHostProvider, Sendable {
    let capabilities = ["client.call"]
    let effects: AyuTestProviderEffects
    init(effects: AyuTestProviderEffects) { self.effects = effects }
    func call(pluginID: String, operation: String, arguments: [String: AyuBridgeValue]) throws -> AyuBridgeValue { throw AyuBridgeFailure.unsupported(operation) }
    func prepareCall(pluginID: String, operation: String, arguments: [String: AyuBridgeValue], context: AyuBridgeAdapterContext) throws -> AyuBridgeProviderResult {
        let result: AyuBridgeAdapterResult = arguments["name"]?.string == "good" ? .instance(className: "java.lang.Long", state: ["value": .integer(Int64.max)]) : .value(.object(["$handle": .string("invented"), "$class": .string("java.lang.Long")]))
        return AyuBridgeProviderResult(result, rollback: { self.effects.add(1) }, commit: { _ in self.effects.add(0) })
    }
    func detach(pluginID: String) {}
}
