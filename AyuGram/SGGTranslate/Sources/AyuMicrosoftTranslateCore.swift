// Ported from exteraGram for Android (com.exteragram.messenger.translator.providers.MicrosoftTranslator),
// GPL v3 or later, © exteraGram.

import Foundation

// The Microsoft Translator provider: what a request looks like and what a response means.
public enum AyuMicrosoftTranslate {
    public static let limits = AyuTranslateLimits(maxTextsPerRequest: 20, maxCharsPerText: 5000, maxCharsPerRequest: 10000)

    public static func plan(texts: [String]) -> AyuTranslatePlan {
        return AyuTranslatePlan(texts: texts, limits: limits)
    }

    private static let signingKey: [UInt8] = {
        guard var key = AyuSealedString.open("VkoWrMP7SOoLpld96DpMgu62G2pGf-nql2-ArwaqpebuNvhBXWDd9dO607hKGNSk_kMvimVi2tfSTw9dSnzblT9IYMCO5KWoixFL73MvoMVQ7xGMhfkBHp-U6wBIuw") else {
            return []
        }
        while key.count % 4 != 0 {
            key += "="
        }
        return [UInt8](Data(base64Encoded: key) ?? Data())
    }()

    private static let endpointPath = "api.cognitive.microsofttranslator.com/translate?api-version=3.0&from="
    private static let signatureScheme = "MSTranslatorAndroidApp"

    // The service's code for an app language code ("pt-BR", "zh-hans-raw", "nb").
    public static func languageCode(_ language: String) -> String {
        var code = language.lowercased().replacingOccurrences(of: "_", with: "-")
        if code.hasSuffix("-raw") {
            code = String(code.dropLast(4))
        }
        switch code {
        case "zh", "zh-hans", "zh-cn", "zh-sg":
            return "zh-Hans"
        case "zh-hant", "zh-tw", "zh-hk", "zh-mo":
            return "zh-Hant"
        case "pt-pt":
            return "pt-pt"
        case "sr-latn":
            return "sr-Latn"
        default:
            break
        }
        switch code.components(separatedBy: "-")[0] {
        case "no", "nn", "nb":
            return "nb"
        case "tl":
            return "fil"
        case "iw":
            return "he"
        case "in":
            return "id"
        case "sr":
            return "sr-Cyrl"
        case let language:
            return language
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"
        return formatter
    }()

    // The request's `X-Mt-Signature`: the scheme, an HMAC of the path with the time and a nonce, and both.
    static func signature(path: String, date: Date, nonce: String) -> String {
        let dateString = dateFormatter.string(from: date).lowercased() + "GMT"
        let payload = (signatureScheme + ayuTranslateFormEncoded(path) + dateString + nonce).lowercased()
        let hmac = Data(AyuSealedString.hmacSHA256(key: signingKey, message: Array(payload.utf8))).base64EncodedString()
        return "\(signatureScheme)::\(hmac)::\(dateString)::\(nonce)"
    }

    public static func requestBody(texts: [String]) -> Data {
        return (try? JSONSerialization.data(withJSONObject: texts.map { ["Text": $0] })) ?? Data("[]".utf8)
    }

    public static func request(texts: [String], toLang: String, html: Bool = false, date: Date = Date(), nonce: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()) -> URLRequest {
        let path = "\(endpointPath)&to=\(languageCode(toLang))&textType=\(html ? "html" : "plain")"
        var request = URLRequest(url: URL(string: "https://" + path)!)
        request.httpMethod = "POST"
        request.setValue(signature(path: path, date: date, nonce: nonce), forHTTPHeaderField: "X-Mt-Signature")
        request.setValue("okhttp/4.5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(texts: texts)
        return request
    }

    // The translations of a response, one per text sent, in order.
    public static func parseResponse(data: Data?, statusCode: Int, expected: Int) -> Result<[String], AyuTranslateProviderError> {
        let isSuccessful = (200 ..< 300).contains(statusCode)
        guard let data, !data.isEmpty else {
            return .failure(isSuccessful ? .transient : ayuTranslateHTTPError(statusCode))
        }
        let json = try? JSONSerialization.jsonObject(with: data)
        guard let array = json as? [Any] else {
            let code = (((json as? [String: Any])?["error"] as? [String: Any])?["code"] as? Int) ?? 0
            if statusCode == 429 {
                return .failure(.rateLimited)
            } else if code / 1000 == 401 {
                return .failure(.fatal)
            } else if code == 400036 {
                // "The target language is not valid."
                return .failure(.languageUnsupported)
            } else if (500 ... 599).contains(statusCode) {
                return .failure(.transient)
            } else if json == nil && isSuccessful {
                return .failure(.transient)
            } else {
                return .failure(.fatal)
            }
        }
        guard array.count == expected else {
            return .failure(.transient)
        }
        var result: [String] = []
        for item in array {
            guard let translations = (item as? [String: Any])?["translations"] as? [Any], let first = translations.first as? [String: Any] else {
                return .failure(.transient)
            }
            result.append((first["text"] as? String) ?? "")
        }
        return .success(result)
    }
}
