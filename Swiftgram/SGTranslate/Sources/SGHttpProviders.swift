import Foundation
import CommonCrypto
import SwiftSignalKit
import Postbox

let sgMicrosoftSigningKeyBase64Url = "VkoWrMP7SOoLpld96DpMgu62G2pGf-nql2-ArwaqpebuNvhBXWDd9dO607hKGNSk_kMvimVi2tfSTw9dSnzblT9IYMCO5KWoixFL73MvoMVQ7xGMhfkBHp-U6wBIuw"

private func sgBase64UrlDecode(_ string: String) -> Data? {
    var base64 = string
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
        base64.append("=")
    }
    return Data(base64Encoded: base64)
}

private func sgHmacSha256(key: Data, payload: Data) -> Data {
    var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    payload.withUnsafeBytes { payloadBytes in
        key.withUnsafeBytes { keyBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count, payloadBytes.baseAddress, payload.count, &hmac)
        }
    }
    return Data(hmac)
}

private func sgHttpProviderSignal(request: URLRequest, expected: Int, parse: @escaping (Data) -> [String]?) -> Signal<[String], TranslationError> {
    return Signal { subscriber in
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data, !data.isEmpty else {
                subscriber.putError(.generic)
                return
            }
            if let parsed = parse(data), parsed.count == expected {
                subscriber.putNext(parsed)
                subscriber.putCompletion()
            } else {
                subscriber.putError(.generic)
            }
        }
        task.resume()
        return ActionDisposable {
            task.cancel()
        }
    }
}

func sgMicrosoftTranslate(texts: [String], toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    guard !texts.isEmpty else {
        return .single([])
    }
    var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")
    components?.queryItems = [
        URLQueryItem(name: "api-version", value: "3.0"),
        URLQueryItem(name: "from", value: ""),
        URLQueryItem(name: "to", value: toLang),
        URLQueryItem(name: "textType", value: "plain")
    ]
    guard let url = components?.url else {
        return .fail(.generic)
    }
    let path = url.path + "?" + (url.query ?? "")
    let body: [[String: String]] = texts.map { ["Text": $0] }
    guard let bodyData = try? JSONSerialization.data(withJSONObject: body, options: []) else {
        return .fail(.generic)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = bodyData
    request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
    request.setValue("okhttp/4.5.0", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20.0

    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    let dateFormatter = DateFormatter()
    dateFormatter.locale = Locale(identifier: "en_US_POSIX")
    dateFormatter.timeZone = TimeZone(identifier: "GMT")
    dateFormatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"
    let date = dateFormatter.string(from: Date()).lowercased() + "gmt"
    let encodedPath = path.addingPercentEncoding(withAllowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
    let payload = ("MSTranslatorAndroidApp" + encodedPath + date + nonce).lowercased()
    guard let keyData = sgBase64UrlDecode(sgMicrosoftSigningKeyBase64Url) else {
        return .fail(.generic)
    }
    let hmac = sgHmacSha256(key: keyData, payload: Data(payload.utf8))
    request.setValue("MSTranslatorAndroidApp::\(hmac.base64EncodedString())::\(date)::\(nonce)", forHTTPHeaderField: "X-Mt-Signature")

    return sgHttpProviderSignal(request: request, expected: texts.count, parse: { data in
        guard let array = try? JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] else {
            return nil
        }
        return array.compactMap { entry in
            (entry["translations"] as? [[String: Any]])?.first?["text"] as? String
        }
    })
    |> map { translated in
        translated.map { ($0, [MessageTextEntity]()) }
    }
}

func sgYandexTranslate(texts: [String], toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    guard !texts.isEmpty else {
        return .single([])
    }
    let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var components = URLComponents(string: "https://translate.yandex.net/api/v1/tr.json/translate")
    components?.queryItems = [
        URLQueryItem(name: "srv", value: "android"),
        URLQueryItem(name: "id", value: "\(id)-0-0")
    ]
    guard let url = components?.url else {
        return .fail(.generic)
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("ru.yandex.translate/21.15.4.21402814 (Xiaomi Redmi K20 Pro; Android 11)", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 20.0

    var bodyItems: [URLQueryItem] = [URLQueryItem(name: "lang", value: toLang), URLQueryItem(name: "format", value: "plain")]
    for text in texts {
        bodyItems.append(URLQueryItem(name: "text", value: text))
    }
    var bodyComponents = URLComponents()
    bodyComponents.queryItems = bodyItems
    let query = (bodyComponents.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
    request.httpBody = query.data(using: .utf8)

    return sgHttpProviderSignal(request: request, expected: texts.count, parse: { data in
        guard let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let code = json["code"] as? Int, code == 200,
              let textArray = json["text"] as? [String] else {
            return nil
        }
        return textArray
    })
    |> map { translated in
        translated.map { ($0, [MessageTextEntity]()) }
    }
}
