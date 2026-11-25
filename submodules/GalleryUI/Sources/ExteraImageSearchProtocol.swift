import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Provider URLs and multipart format ported from exteraGram Android's
/// components/ReverseImageSearch.java (2022–2026 exteraGram, GPL-3.0-or-later
/// with the reference repository's ADDITIONAL_TERMS.md).
enum ExteraImageSearchProvider: String, CaseIterable {
    case yandex
    case google
    case bing
    case tineye

    var title: String {
        switch self {
        case .yandex: return "Yandex"
        case .google: return "Google Lens"
        case .bing: return "Bing"
        case .tineye: return "TinEye"
        }
    }
}

enum ExteraImageSearchProtocol {
    static let maximumUploadBytes = 5 * 1024 * 1024
    static let maximumResponseBytes = 1024 * 1024

    enum SearchError: Error {
        case invalidImage
        case invalidResponse
        case untrustedURL
        case failedRequest
    }

    static var uploadURL: URL {
        var components = URLComponents(string: "https://yandex.com/images/touch/search")!
        components.queryItems = [
            URLQueryItem(name: "rpt", value: "imageview"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "request", value: "{\"blocks\":[{\"block\":\"cbir-uploader__get-cbir-id\"}]}"),
        ]
        return components.url!
    }

    static func isUploadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return ["yandex.com", "www.yandex.com", "yandex.ru", "www.yandex.ru"].contains(url.host?.lowercased() ?? "")
    }

    static func upload(jpeg: Data, boundary: String) throws -> (URLRequest, Data) {
        guard jpeg.count >= 4, jpeg.count <= self.maximumUploadBytes,
              jpeg.starts(with: [0xff, 0xd8]), !boundary.isEmpty,
              boundary.count <= 70,
              boundary.utf8.allSatisfy({ (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 }) else {
            throw SearchError.invalidImage
        }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"upfile\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: self.uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45.0)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        return (request, body)
    }

    static func resultURL(data: Data, responseURL: URL, provider: ExteraImageSearchProvider) throws -> URL {
        guard data.count <= self.maximumResponseBytes, self.isUploadURL(responseURL),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = object["blocks"] as? [[String: Any]],
              let params = blocks.first?["params"] as? [String: Any],
              let cbirId = params["cbirId"] as? String, !cbirId.isEmpty, cbirId.count <= 4096,
              let image = params["originalImageUrl"] as? String, image.count <= 16 * 1024,
              let imageURL = URL(string: image), imageURL.scheme?.lowercased() == "https",
              imageURL.user == nil, imageURL.password == nil, imageURL.port == nil || imageURL.port == 443,
              let imageHost = imageURL.host?.lowercased(),
              ["yandex.com", "yandex.ru", "yandex.net"].contains(where: { imageHost == $0 || imageHost.hasSuffix("." + $0) }) else {
            throw SearchError.invalidResponse
        }
        var components: URLComponents
        switch provider {
        case .yandex:
            components = URLComponents(string: "https://\(responseURL.host!)/images/search")!
            components.queryItems = [URLQueryItem(name: "rpt", value: "imageview"), URLQueryItem(name: "cbir_id", value: cbirId), URLQueryItem(name: "url", value: image)]
        case .google:
            components = URLComponents(string: "https://lens.google.com/uploadbyurl")!
            components.queryItems = [URLQueryItem(name: "url", value: image)]
        case .bing:
            components = URLComponents(string: "https://www.bing.com/images/search")!
            components.queryItems = [URLQueryItem(name: "view", value: "detailv2"), URLQueryItem(name: "iss", value: "sbi"), URLQueryItem(name: "form", value: "SBIVSP"), URLQueryItem(name: "sbisrc", value: "UrlPaste"), URLQueryItem(name: "q", value: "imgurl:" + image)]
        case .tineye:
            components = URLComponents(string: "https://tineye.com/search")!
            components.queryItems = [URLQueryItem(name: "url", value: image)]
        }
        // Web query parsers treat '+' as a space; URLComponents leaves it literal.
        // Match Android's Uri.encode so a returned image URL/token keeps real '+' bytes.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw SearchError.untrustedURL }
        return url
    }
}
