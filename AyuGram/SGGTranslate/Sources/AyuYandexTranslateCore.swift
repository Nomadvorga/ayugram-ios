// Ported from exteraGram for Android (com.exteragram.messenger.translator.providers.YandexTranslator and
// core.HttpTranslator), GPL v3 or later, © exteraGram.

import Foundation

// The Yandex Translate provider: what a request looks like and what a response means.
public enum AyuYandexTranslate {
    public static let maxTextsPerRequest = 20
    public static let maxCharsPerRequest = 5000

    public static let supportedLanguages: Set<String> = [
        "az", "sq", "am", "en", "ar", "hy", "af", "eu", "ba", "be",
        "bn", "my", "bg", "bs", "cv", "cy", "hu", "vi", "ht", "gl",
        "nl", "mrj", "el", "ka", "gu", "da", "he", "yi", "id", "ga",
        "it", "is", "es", "kk", "kn", "ca", "ky", "zh", "ko", "xh",
        "km", "lo", "la", "lv", "lt", "lb", "mg", "ms", "ml", "mt",
        "mk", "mi", "mr", "mhr", "mn", "de", "ne", "no", "pa", "pap",
        "fa", "pl", "pt", "ro", "ru", "ceb", "sr", "si", "sk", "sl",
        "sw", "su", "tg", "th", "tl", "ta", "tt", "te", "tr", "udm",
        "uz", "uk", "ur", "fi", "fr", "hi", "hr", "cs", "sv", "gd",
        "et", "eo", "jv", "ja"
    ]

    // The service's code for an app language code ("pt-BR", "zh-hans-raw", "nb"): the language alone.
    public static func languageCode(_ language: String) -> String {
        var code = language.lowercased()
        if code.hasSuffix("-raw") {
            code = String(code.dropLast(4))
        }
        code = code.components(separatedBy: "-")[0].components(separatedBy: "_")[0]
        switch code {
        case "nb", "nn":
            return "no"
        case "iw":
            return "he"
        case "in":
            return "id"
        default:
            return code
        }
    }

    public static func isLanguageSupported(_ language: String) -> Bool {
        return supportedLanguages.contains(languageCode(language))
    }

    // One identifier per launch, as the Android client sends.
    private static let clientId = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    // The body of a request: the target language and every text, form encoded.
    public static func requestBody(texts: [String], toLang: String, html: Bool = false) -> Data {
        var fields = ["lang=" + ayuTranslateFormEncoded(languageCode(toLang)), "format=" + (html ? "html" : "plain")]
        for text in texts {
            fields.append("text=" + ayuTranslateFormEncoded(text))
        }
        return Data(fields.joined(separator: "&").utf8)
    }

    public static func request(texts: [String], toLang: String, html: Bool = false) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://translate.yandex.net/api/v1/tr.json/translate?&srv=android&id=\(clientId)-0-0")!)
        request.httpMethod = "POST"
        request.setValue("ru.yandex.translate/21.15.4.21402814 (Xiaomi Redmi K20 Pro; Android 11)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = requestBody(texts: texts, toLang: toLang, html: html)
        return request
    }

    // The translations of a response, one per text sent, in order.
    public static func parseResponse(data: Data?, statusCode: Int, expected: Int) -> Result<[String], AyuTranslateProviderError> {
        let isSuccessful = (200 ..< 300).contains(statusCode)
        guard let data, !data.isEmpty else {
            return .failure(isSuccessful ? .transient : ayuTranslateHTTPError(statusCode))
        }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(isSuccessful ? .transient : ayuTranslateHTTPError(statusCode))
        }
        let code = (json["code"] as? Int) ?? (isSuccessful ? 200 : statusCode)
        guard code == 200, let texts = json["text"] as? [Any] else {
            if code == 429 || code == 1052 || statusCode == 429 {
                return .failure(.rateLimited)
            } else if code == 501 {
                return .failure(.languageUnsupported)
            } else if (500 ... 599).contains(statusCode) {
                return .failure(.transient)
            } else {
                return .failure(.fatal)
            }
        }
        guard texts.count == expected else {
            return .failure(.transient)
        }
        return .success(texts.map { ($0 as? String) ?? "" })
    }

    public static let limits = AyuTranslateLimits(maxTextsPerRequest: maxTextsPerRequest, maxCharsPerText: maxCharsPerRequest, maxCharsPerRequest: maxCharsPerRequest)

    public static func plan(texts: [String]) -> AyuTranslatePlan {
        return AyuTranslatePlan(texts: texts, limits: limits)
    }
}
