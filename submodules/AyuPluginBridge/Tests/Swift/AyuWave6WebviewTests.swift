import XCTest
import WebKit
@testable import AyuPluginBridge

@MainActor final class AyuWave6WebviewTests: XCTestCase {
    func testSettingsStartWithAndroidDefaults() {
        let view = AyuBridgeWebView()
        XCTAssertEqual(view.settings, AyuBridgeWebSettings(javaScriptEnabled: false, domStorageEnabled: false, userAgent: nil))
        XCTAssertFalse(view.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        view.setJavaScriptEnabled(true); view.setDomStorageEnabled(true); view.setUserAgentString("Agent/1")
        XCTAssertEqual(view.settings, AyuBridgeWebSettings(javaScriptEnabled: true, domStorageEnabled: true, userAgent: "Agent/1"))
        XCTAssertEqual(view.webView.customUserAgent, "Agent/1")
        view.setUserAgentString(nil)
        XCTAssertNil(view.settings.userAgent)
    }

    func testScriptIsWrappedAsOneEscapedLiteralAndResultsAreJSONText() {
        XCTAssertEqual(AyuBridgeWebView.wrappedScript("a\"b\n"), "(function(){var r=(0,eval)(\"a\\\"b\\n\");var t=JSON.stringify(r);return t===undefined?'null':t})()")
        XCTAssertEqual(AyuBridgeWebView.resultText(nil), "null")
        XCTAssertEqual(AyuBridgeWebView.resultText(NSNull()), "null")
        XCTAssertEqual(AyuBridgeWebView.resultText("\"x\""), "\"x\"")
        XCTAssertEqual(AyuBridgeWebView.resultText("{\"a\":1}"), "{\"a\":1}")
    }

    func testEvaluateWithJavaScriptDisabledDeliversNullAndDestroyedViewStaysSilent() {
        let view = AyuBridgeWebView()
        let delivered = self.expectation(description: "null")
        view.evaluateJavascript("1+1") { value in XCTAssertEqual(value, "null"); delivered.fulfill() }
        self.wait(for: [delivered], timeout: 5)
        XCTAssertThrowsError(try view.loadUrl("javascript:alert(1)"))
        view.destroy()
        XCTAssertTrue(view.destroyed)
        view.evaluateJavascript("1") { _ in XCTFail("delivered after destroy") }
        XCTAssertNoThrow(try view.loadUrl("https://example.invalid/"))
        XCTAssertNil(view.getUrl())
    }
}
