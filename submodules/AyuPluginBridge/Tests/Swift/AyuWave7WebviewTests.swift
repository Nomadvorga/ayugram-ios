import XCTest
import WebKit
@testable import AyuPluginBridge

@MainActor final class AyuWave7WebviewTests: XCTestCase {
    func testRouterServesExactlyTheDeclaredMethodsAndChecksArguments() throws {
        let view = AyuBridgeWebView()
        XCTAssertEqual(try view.invokeSettings("getJavaScriptEnabled", []), .bool(false))
        XCTAssertEqual(try view.invokeSettings("setJavaScriptEnabled", [.bool(true)]), .null)
        XCTAssertEqual(try view.invokeSettings("getJavaScriptEnabled", []), .bool(true))
        XCTAssertEqual(try view.invokeSettings("setDomStorageEnabled", [.bool(true)]), .null)
        XCTAssertEqual(try view.invokeSettings("getDomStorageEnabled", []), .bool(true))
        XCTAssertEqual(try view.invokeSettings("setUserAgentString", [.string("Agent/7")]), .null)
        XCTAssertEqual(view.webView.customUserAgent, "Agent/7")
        XCTAssertThrowsError(try view.invokeSettings("setJavaScriptEnabled", [.integer(1)]))
        for name in ["setAllowFileAccess", "setMixedContentMode", "setMediaPlaybackRequiresUserGesture"] {
            XCTAssertFalse(AyuBridgeWebView.settingsMethods.contains(name))
            XCTAssertThrowsError(try view.invokeSettings(name, [.bool(true)])) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "UNSUPPORTED_API") }
        }
        XCTAssertEqual(try view.invoke("getUrl", []), .null)
        XCTAssertThrowsError(try view.invoke("loadUrl", [.null]))
        XCTAssertThrowsError(try view.invoke("loadDataWithBaseURL", [.null, .string("x")]))
        XCTAssertThrowsError(try view.invoke("loadUrl", [.string("javascript:void(0)")])) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "UNSUPPORTED_API") }
        XCTAssertThrowsError(try view.invoke("addJavascriptInterface", [.null, .string("x")])) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "UNSUPPORTED_API") }
        for name in AyuBridgeWebView.hostMethods where !["getUrl", "stopLoading", "destroy"].contains(name) {
            XCTAssertThrowsError(try view.invoke(name, [])) { XCTAssertEqual(($0 as? AyuBridgeFailure)?.code, "INVALID_ARGUMENTS", name) }
        }
        XCTAssertEqual(try view.invoke("stopLoading", []), .null)
        XCTAssertEqual(try view.invoke("destroy", []), .null)
        XCTAssertTrue(view.destroyed)
    }

    func testDataLoadReportsHistoryUrlAndEvaluatesInThePage() throws {
        let view = AyuBridgeWebView()
        _ = try view.invokeSettings("setJavaScriptEnabled", [.bool(true)])
        let finished = self.expectation(description: "onPageFinished")
        view.onPageFinished = { _ in finished.fulfill() }
        let page = "<html><body><script>var answer = 40 + 2;</script></body></html>"
        XCTAssertEqual(try view.invoke("loadDataWithBaseURL", [.string("https://example.invalid/"), .string(page), .string("text/html"), .string("UTF-8"), .null]), .null)
        XCTAssertEqual(try view.invoke("getUrl", []), .string("about:blank"))
        self.wait(for: [finished], timeout: 20)
        XCTAssertEqual(try view.invoke("getUrl", []), .string("about:blank"))
        let number = self.expectation(description: "number"), text = self.expectation(description: "text"), nothing = self.expectation(description: "undefined")
        XCTAssertEqual(try view.invoke("evaluateJavascript", [.string("answer"), .object([:])]) { XCTAssertEqual($0, "42"); number.fulfill() }, .null)
        _ = try view.invoke("evaluateJavascript", [.string("location.host + '!'"), .object([:])]) { XCTAssertEqual($0, "\"example.invalid!\""); text.fulfill() }
        _ = try view.invoke("evaluateJavascript", [.string("void 0"), .object([:])]) { XCTAssertEqual($0, "null"); nothing.fulfill() }
        _ = try view.invoke("evaluateJavascript", [.string("answer = 1"), .null])
        self.wait(for: [number, text, nothing], timeout: 20)
        view.destroy()
    }
}
