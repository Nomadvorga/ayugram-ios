import XCTest

#if canImport(SGSimpleSettings)
import SGSimpleSettings
#endif

final class ExteraOtherSettingsModelTests: XCTestCase {
    private typealias Model = ExteraOtherSettingsModel
    private let address = "0:" + String(repeating: "0", count: 64)

    func testReferenceSectionsAndAccountActionsStayInExactOrder() {
        XCTAssertEqual(Model.Section.allCases, [.exteraSupport, .ayuSupport, .google, .account, .additional])
        XCTAssertEqual(Model.AccountRow.allCases, [.exportSettings, .resetSettings, .deleteAccount])
        XCTAssertEqual(Model.Telemetry.allCases, [.crashlytics, .analytics])
    }

    func testAbsentGoogleCollectorsCannotBecomeOptIns() {
        for service in Model.Telemetry.allCases { XCTAssertFalse(service.canCollect) }
    }

    func testBothProjectsParseTheirOwnSupportCatalogOnly() throws {
        let message = "remote_config\ndonates=[Universal#https://t.me/exteraBotApp/donate, Boosty#https://boosty.to/exteragram/about]\ndonates_ayu=[Tonkeeper#\(self.address), Boosty#https://boosty.to/example]"
        let extera = try XCTUnwrap(Model.parseSupport(messages: [message], project: .extera))
        let ayu = try XCTUnwrap(Model.parseSupport(messages: [message], project: .ayu))
        XCTAssertEqual(extera.entries.map(\.name), ["Boosty", "Universal"])
        XCTAssertEqual(ayu.entries.map(\.name), ["Boosty", "Tonkeeper"])
        XCTAssertTrue(extera.entries.allSatisfy { $0.project == .extera })
        XCTAssertTrue(ayu.entries.allSatisfy { $0.project == .ayu })
    }

    func testLatestConfigWinsAndExplicitEmptyRemovesPaymentDetails() throws {
        let old = "remote_config\ndonates=[Boosty#https://boosty.to/example]"
        let new = "remote_config\ndonates=[]"
        XCTAssertTrue(try XCTUnwrap(Model.parseSupport(messages: [old, new], project: .extera)).entries.isEmpty)
        let missing = try XCTUnwrap(Model.parseSupport(messages: ["remote_config\nhide_ads=true"], project: .extera))
        XCTAssertTrue(missing.entries.isEmpty)
        XCTAssertNil(Model.parseSupport(messages: ["supporters\ndonates=[Fake#https://example.org]"], project: .extera))
    }

    func testMalformedAndDuplicateSupportEntriesAreExcluded() throws {
        let config = try XCTUnwrap(Model.parseSupport(messages: ["remote_config\ndonates=[NoDelimiter, #empty, Bad#javascript:alert(1), Bad#https://example.org#fragment, Boosty#https://example.org, Boosty#https://example.org]"], project: .extera))
        XCTAssertEqual(config.entries.map(\.name), ["Boosty"])
    }

    func testUnsupportedLauncherAndUnsafeURLsCannotOpen() {
        for value in ["app", "http://example.org", "javascript:alert(1)", "file:///etc/passwd", "https://user:secret@example.org", "https://example.org\n"] {
            XCTAssertNil(Model.route(for: .init(project: .extera, name: "Universal", details: value), banks: [], accountId: 1), value)
        }
    }

    func testUniversalTelegramMiniAppUsesNativeURLFlow() {
        let url = URL(string: "https://t.me/exteraBotApp/donate")!
        XCTAssertEqual(Model.route(for: .init(project: .extera, name: "Universal", details: url.absoluteString), banks: [], accountId: 1), .web(url))
    }

    func testWalletCarriesOnlyCurrentActorIdAsCommentAndNoAmount() throws {
        let route = try XCTUnwrap(Model.route(for: .init(project: .ayu, name: "Tonkeeper", details: self.address), banks: [], accountId: 12345))
        guard case let .wallet(url, address, comment) = route else { return XCTFail("Expected wallet route") }
        XCTAssertEqual(address, self.address)
        XCTAssertEqual(comment, "12345")
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "ton")
        XCTAssertEqual(components.host, "transfer")
        XCTAssertEqual(components.path, "/" + self.address)
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "text", value: "12345")])
    }

    func testWalletRejectsUnknownActorAndInjectedDestination() {
        for value in [self.address + "?amount=1000", "https://example.org", "not-an-address"] {
            XCTAssertNil(Model.route(for: .init(project: .ayu, name: "Tonkeeper", details: value), banks: [], accountId: 1))
        }
        XCTAssertNil(Model.route(for: .init(project: .ayu, name: "Tonkeeper", details: self.address), banks: [], accountId: 0))
    }

    func testTONChecksumAndWorkchainAreChecked() {
        // Public TON zero-address fixture, not a donation destination.
        XCTAssertTrue(Model.isTONAddress("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9c"))
        XCTAssertFalse(Model.isTONAddress("EQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAM9d"))
        XCTAssertTrue(Model.isTONAddress(self.address))
        XCTAssertFalse(Model.isTONAddress("2:" + String(repeating: "0", count: 64)))
    }

    func testExteraBankSelectorAndPlainCopyKeepTheirDistinctRoutes() throws {
        let config = try XCTUnwrap(Model.parseSupport(messages: ["remote_config\ndonates=[Card#123456]\ndonates_banks=[Bank A#1111, Bank B#2222]"], project: .extera))
        let card = try XCTUnwrap(config.entries.first)
        XCTAssertEqual(Model.route(for: card, banks: config.banks, accountId: 1), .banks(config.banks))
        XCTAssertEqual(Model.route(for: card, banks: [], accountId: 1), .copy("123456"))
        let ayuCard = Model.SupportEntry(project: .ayu, name: "Card", details: "3333")
        XCTAssertEqual(Model.route(for: ayuCard, banks: config.banks, accountId: 1), .copy("3333"))
    }

    func testOversizedRemoteDataIsRejectedAndNeverStoredAsSettings() {
        XCTAssertNil(Model.parseSupport(messages: Array(repeating: "remote_config", count: 101), project: .ayu))
        XCTAssertNil(Model.parseSupport(messages: [String(repeating: "x", count: 128 * 1024 + 1)], project: .ayu))
    }
}
