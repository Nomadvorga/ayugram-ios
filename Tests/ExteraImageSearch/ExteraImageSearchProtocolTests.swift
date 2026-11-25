import Foundation
import XCTest

final class ExteraImageSearchProtocolTests: XCTestCase {
    private func response(image: String = "https://avatars.mds.yandex.net/get-images-cbir/test/orig", id: String = "id+with&symbols") throws -> Data {
        return try JSONSerialization.data(withJSONObject: ["blocks": [["params": ["cbirId": id, "originalImageUrl": image]]]])
    }

    func testUploadMatchesAndroidMultipartAndNeverAddsConsentCookies() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let (request, body) = try ExteraImageSearchProtocol.upload(jpeg: jpeg, boundary: "test-boundary")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.host, "yandex.com")
        XCTAssertEqual(request.url?.path, "/images/touch/search")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=test-boundary")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "request" })?.value, "{\"blocks\":[{\"block\":\"cbir-uploader__get-cbir-id\"}]}")
        XCTAssertTrue(body.starts(with: Data("--test-boundary\r\nContent-Disposition: form-data; name=\"upfile\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)))
        XCTAssertNotNil(body.range(of: jpeg))
        let ending = Data("\r\n--test-boundary--\r\n".utf8)
        XCTAssertTrue(body.suffix(ending.count).elementsEqual(ending))
    }

    func testAllProvidersReceiveOnlyTheRealReturnedImageURL() throws {
        let image = "https://avatars.mds.yandex.net/get-images-cbir/a/orig?x=1&y=two+three"
        let hosts: [ExteraImageSearchProvider: String] = [.yandex: "yandex.com", .google: "lens.google.com", .bing: "www.bing.com", .tineye: "tineye.com"]
        for provider in ExteraImageSearchProvider.allCases {
            let url = try ExteraImageSearchProtocol.resultURL(data: self.response(image: image), responseURL: ExteraImageSearchProtocol.uploadURL, provider: provider)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, hosts[provider])
            XCTAssertFalse(url.absoluteString.contains("+"), "A web query parser would change an unescaped plus into a space")
            let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            if provider == .bing {
                XCTAssertEqual(items.first(where: { $0.name == "q" })?.value, "imgurl:" + image)
            } else {
                XCTAssertEqual(items.first(where: { $0.name == "url" })?.value, image)
            }
        }
    }

    func testRejectsForgedOrLocalUploadResultURLs() throws {
        for image in ["http://avatars.mds.yandex.net/image", "file:///private/photo.jpg", "https://127.0.0.1/image", "https://yandex.net.evil.example/image", "https://user:password@yandex.net/image", "https://yandex.net:444/image"] {
            XCTAssertThrowsError(try ExteraImageSearchProtocol.resultURL(data: self.response(image: image), responseURL: ExteraImageSearchProtocol.uploadURL, provider: .google))
        }
        XCTAssertFalse(ExteraImageSearchProtocol.isUploadURL(URL(string: "https://yandex.com.evil.example/upload")!))
        XCTAssertFalse(ExteraImageSearchProtocol.isUploadURL(URL(string: "http://yandex.com/upload")!))
        XCTAssertFalse(ExteraImageSearchProtocol.isUploadURL(URL(string: "https://user@yandex.com/upload")!))
    }

    func testRejectsMalformedAndOversizedInputs() throws {
        XCTAssertThrowsError(try ExteraImageSearchProtocol.upload(jpeg: Data("not jpeg".utf8), boundary: "valid"))
        XCTAssertThrowsError(try ExteraImageSearchProtocol.upload(jpeg: Data([0xff, 0xd8, 0xff, 0xd9]), boundary: "bad\r\nheader"))
        var huge = Data([0xff, 0xd8])
        huge.append(Data(repeating: 0, count: ExteraImageSearchProtocol.maximumUploadBytes))
        XCTAssertThrowsError(try ExteraImageSearchProtocol.upload(jpeg: huge, boundary: "valid"))
        XCTAssertThrowsError(try ExteraImageSearchProtocol.resultURL(data: Data("{}".utf8), responseURL: ExteraImageSearchProtocol.uploadURL, provider: .yandex))
        XCTAssertThrowsError(try ExteraImageSearchProtocol.resultURL(data: self.response(id: ""), responseURL: ExteraImageSearchProtocol.uploadURL, provider: .yandex))
        XCTAssertThrowsError(try ExteraImageSearchProtocol.resultURL(data: self.response(), responseURL: URL(string: "https://evil.example/result")!, provider: .yandex))
    }

    static let allTests = [
        ("testUploadMatchesAndroidMultipartAndNeverAddsConsentCookies", testUploadMatchesAndroidMultipartAndNeverAddsConsentCookies),
        ("testAllProvidersReceiveOnlyTheRealReturnedImageURL", testAllProvidersReceiveOnlyTheRealReturnedImageURL),
        ("testRejectsForgedOrLocalUploadResultURLs", testRejectsForgedOrLocalUploadResultURLs),
        ("testRejectsMalformedAndOversizedInputs", testRejectsMalformedAndOversizedInputs),
    ]
}

#if !SWIFT_PACKAGE
@main
private enum ExteraImageSearchTestRunner {
    static func main() { XCTMain([testCase(ExteraImageSearchProtocolTests.allTests)]) }
}
#endif
