// Ported from exteraGram for Android (com.exteragram.messenger.components.ReverseImageSearch), GPL v3 or later,
// © exteraGram.

import Foundation

// Looking a picture up on the web: it is uploaded to Yandex's image search, which gives it an address, and
// the chosen service is opened on that address.
enum AyuReverseImageSearch {
    enum Provider: Int, CaseIterable {
        case yandex
        case google
        case bing
        case tineye

        var title: String {
            switch self {
            case .yandex:
                return "Yandex"
            case .google:
                return "Google Lens"
            case .bing:
                return "Bing"
            case .tineye:
                return "TinEye"
            }
        }
    }

    static let maxImageSide = 1280

    private static let queryAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    private static func encoded(_ value: String) -> String {
        return value.addingPercentEncoding(withAllowedCharacters: queryAllowed) ?? ""
    }

    static let uploadURL = "https://yandex.com/images/touch/search?rpt=imageview&format=json&request=" + encoded("{\"blocks\":[{\"block\":\"cbir-uploader__get-cbir-id\"}]}")

    // The upload of a JPEG picture as a form with one file.
    static func uploadRequest(jpeg: Data, userAgent: String?, boundary: String = "AyuBoundary" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) -> URLRequest {
        var request = URLRequest(url: URL(string: uploadURL)!, timeoutInterval: 30.0)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("gdpr=0", forHTTPHeaderField: "Cookie")
        if let userAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"upfile\"; filename=\"image.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".utf8))
        body.append(jpeg)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body
        return request
    }

    // The search page of a provider for an uploaded picture, from the upload's answer and the host that gave it
    // (the service may have redirected to its regional site).
    static func searchURL(provider: Provider, uploadResponse: Data, uploadHost: String) -> String? {
        guard let json = (try? JSONSerialization.jsonObject(with: uploadResponse)) as? [String: Any], let blocks = json["blocks"] as? [Any], let block = blocks.first as? [String: Any], let params = block["params"] as? [String: Any] else {
            return nil
        }
        guard let cbirId = params["cbirId"] as? String, !cbirId.isEmpty, let imageUrl = params["originalImageUrl"] as? String, !imageUrl.isEmpty else {
            return nil
        }
        let image = encoded(imageUrl)
        switch provider {
        case .yandex:
            return "https://\(uploadHost)/images/search?rpt=imageview&cbir_id=\(encoded(cbirId))&url=\(image)"
        case .google:
            return "https://lens.google.com/uploadbyurl?url=\(image)"
        case .bing:
            return "https://www.bing.com/images/search?view=detailv2&iss=sbi&form=SBIVSP&sbisrc=UrlPaste&q=imgurl:\(image)"
        case .tineye:
            return "https://tineye.com/search?url=\(image)"
        }
    }
}
