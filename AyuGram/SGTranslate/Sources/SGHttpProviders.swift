import CommonCrypto
import Foundation
import Postbox
import SwiftSignalKit

// Request signing and provider limits follow exteraGram's MicrosoftTranslator,
// YandexTranslator and SealedString implementations (GPL-3.0-or-later).
private let sgMicrosoftSealedSigningKey = "VkoWrMP7SOoLpld96DpMgu62G2pGf-nql2-ArwaqpebuNvhBXWDd9dO607hKGNSk_kMvimVi2tfSTw9dSnzblT9IYMCO5KWoixFL73MvoMVQ7xGMhfkBHp-U6wBIuw"
private let sgProviderSession: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 4
    configuration.timeoutIntervalForResource = 60.0
    return URLSession(configuration: configuration)
}()

private func sgBase64UrlDecode(_ string: String) -> Data? {
    var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while base64.count % 4 != 0 {
        base64.append("=")
    }
    return Data(base64Encoded: base64)
}

private let sgMicrosoftSigningKey: Data? = {
    guard let sealed = sgBase64UrlDecode(sgMicrosoftSealedSigningKey), sealed.count > 8 else {
        return nil
    }
    let bytes = Array(sealed)
    var plain: [UInt8] = []
    var block = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    for index in 0 ..< bytes.count - 8 {
        if index % 32 == 0 {
            var input = Data("exteraGram/SealedString/v1".utf8)
            input.append(contentsOf: bytes.prefix(8))
            input.append(UInt8(index / 32))
            input.withUnsafeBytes { buffer in
                _ = CC_SHA256(buffer.baseAddress, CC_LONG(input.count), &block)
            }
        }
        plain.append(bytes[index + 8] ^ block[index % 32])
    }
    guard let base64 = String(bytes: plain, encoding: .utf8) else {
        return nil
    }
    return Data(base64Encoded: base64)
}()

private func sgHmacSha256(key: Data, payload: Data) -> Data {
    var hmac = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    payload.withUnsafeBytes { payloadBytes in
        key.withUnsafeBytes { keyBytes in
            CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), keyBytes.baseAddress, key.count, payloadBytes.baseAddress, payload.count, &hmac)
        }
    }
    return Data(hmac)
}

private func sgProviderLanguage(_ code: String, microsoft: Bool) -> String {
    var code = code.replacingOccurrences(of: "_", with: "-").lowercased()
    if code.hasSuffix("-raw") {
        code = String(code.dropLast(4))
    }
    let base = code.components(separatedBy: "-").first ?? code
    if microsoft {
        switch base {
        case "zh": return code.contains("hant") || code.contains("tw") || code.contains("hk") ? "zh-Hant" : "zh-Hans"
        case "sr": return code.contains("latn") ? "sr-Latn" : "sr-Cyrl"
        case "no", "nb": return "nb"
        case "tl", "fil": return "fil"
        case "iw": return "he"
        case "pt": return code.contains("pt") && code != "pt" && !code.contains("br") ? "pt-pt" : "pt"
        default: return base
        }
    }
    switch base {
    case "iw": return "he"
    case "nb": return "no"
    case "fil": return "tl"
    default: return base
    }
}

private enum SGProviderRequestError {
    case terminal(TranslationError)
    case transient(TranslationError, Double)
}

private func sgHttpProviderSignal(request: URLRequest, expected: Int, attempt: Int = 0, parse: @escaping (Any) -> [String]?) -> Signal<[String], TranslationError> {
    let signal = Signal<[String], SGProviderRequestError> { subscriber in
        let task = sgProviderSession.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse else {
                subscriber.putError(.transient(.generic, pow(2.0, Double(attempt))))
                return
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                if response.statusCode == 429 || response.statusCode == 408 || (500 ..< 600).contains(response.statusCode) {
                    let retryAfter: Double
                    if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
                        retryAfter = min(30.0, max(1.0, seconds))
                    } else {
                        retryAfter = pow(2.0, Double(attempt))
                    }
                    subscriber.putError(.transient(response.statusCode == 429 ? .limitExceeded : .generic, retryAfter))
                } else {
                    subscriber.putError(.terminal(.generic))
                }
                return
            }
            // Cap JSON parsing and decoded output independently of the provider's
            // Content-Length header (which may be absent or refer to compressed data).
            guard let data, !data.isEmpty, data.count <= 2 * 1024 * 1024 else {
                subscriber.putError(.terminal(.generic))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) else {
                subscriber.putError(.terminal(.generic))
                return
            }
            if let dictionary = json as? [String: Any], let code = dictionary["code"] as? Int, code != 200 {
                switch code {
                case 429, 1052: subscriber.putError(.transient(.limitExceeded, pow(2.0, Double(attempt))))
                case 501: subscriber.putError(.terminal(.invalidLanguage))
                case 413: subscriber.putError(.terminal(.textTooLong))
                default: subscriber.putError(.terminal(.generic))
                }
                return
            }
            guard let parsed = parse(json), parsed.count == expected,
                  parsed.allSatisfy({ !$0.isEmpty }) else {
                subscriber.putError(.terminal(.generic))
                return
            }
            subscriber.putNext(parsed)
            subscriber.putCompletion()
        }
        task.resume()
        return ActionDisposable {
            task.cancel()
        }
    }
    return signal |> `catch` { error -> Signal<[String], TranslationError> in
        switch error {
        case let .terminal(error):
            return .fail(error)
        case let .transient(error, interval):
            guard attempt < 2 else {
                return .fail(error)
            }
            let retry: Signal<Void, TranslationError> = .single(Void())
            return retry
            |> delay(interval, queue: .concurrentDefaultQueue())
            |> mapToSignal { _ in
                sgHttpProviderSignal(request: request, expected: expected, attempt: attempt + 1, parse: parse)
            }
        }
    }
}

// Split at Character boundaries, budget in UTF-16 units (also bounds scalar counts),
// and send batches serially so a whole chat cannot flood a provider with requests.
private func sgTranslateBatches(texts: [String], maxCharacters: Int, request: @escaping ([String]) -> Signal<[String], TranslationError>) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    var pieces: [(Int, String)] = []
    for (index, text) in texts.enumerated() where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        var chunk = ""
        var length = 0
        for character in text {
            let value = String(character)
            let count = value.utf16.count
            guard count <= maxCharacters else {
                return .fail(.textTooLong)
            }
            if length + count > maxCharacters {
                if let boundary = chunk.lastIndex(where: { $0.isWhitespace }), chunk[chunk.index(after: boundary)...].utf16.count + count <= maxCharacters {
                    let end = chunk.index(after: boundary)
                    pieces.append((index, String(chunk[..<end])))
                    chunk = String(chunk[end...])
                    length = chunk.utf16.count
                } else {
                    pieces.append((index, chunk))
                    chunk = ""
                    length = 0
                }
            }
            chunk.append(character)
            length += count
        }
        if !chunk.isEmpty {
            pieces.append((index, chunk))
        }
    }
    var batches: [[(Int, String)]] = []
    var batch: [(Int, String)] = []
    var length = 0
    for piece in pieces {
        if batch.count == 20 || length + piece.1.utf16.count > maxCharacters {
            batches.append(batch)
            batch = []
            length = 0
        }
        batch.append(piece)
        length += piece.1.utf16.count
    }
    if !batch.isEmpty {
        batches.append(batch)
    }
    var signal: Signal<[String], TranslationError> = .single(texts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? $0 : "" })
    for batch in batches {
        signal = signal |> mapToSignal { accumulated in
            let input = batch.map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            let translation: Signal<[String], TranslationError> = input.isEmpty ? .single([]) : request(input)
            return translation |> map { translated in
                var accumulated = accumulated
                var resultIndex = 0
                for piece in batch {
                    if piece.1.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        accumulated[piece.0] += piece.1
                        continue
                    }
                    let result = translated[resultIndex]
                    resultIndex += 1
                    let leading = String(piece.1.prefix { $0.isWhitespace })
                    let trailing = String(piece.1.reversed().prefix { $0.isWhitespace }.reversed())
                    accumulated[piece.0] += leading + result.trimmingCharacters(in: .whitespacesAndNewlines) + trailing
                }
                return accumulated
            }
        }
    }
    return signal |> map { $0.map { ($0, [MessageTextEntity]()) } }
}

func sgMicrosoftTranslate(texts: [String], fromLang: String? = nil, toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    return sgTranslateBatches(texts: texts, maxCharacters: 5000) { batch in
        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")
        components?.queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "from", value: fromLang.flatMap { $0.isEmpty || $0 == "auto" ? nil : sgProviderLanguage($0, microsoft: true) } ?? ""),
            URLQueryItem(name: "to", value: sgProviderLanguage(toLang, microsoft: true)),
            URLQueryItem(name: "textType", value: "plain")
        ]
        guard let url = components?.url, let host = url.host, let key = sgMicrosoftSigningKey,
              let body = try? JSONSerialization.data(withJSONObject: batch.map { ["Text": $0] }) else {
            return .fail(.generic)
        }
        // Android's URLEncoder uses application/x-www-form-urlencoded encoding.
        let path = host + url.path + "?" + (url.query ?? "")
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return .fail(.generic)
        }
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss"
        let date = formatter.string(from: Date()).lowercased() + "GMT"
        let payload = ("MSTranslatorAndroidApp" + encodedPath + date + nonce).lowercased()
        let hmac = sgHmacSha256(key: key, payload: Data(payload.utf8)).base64EncodedString()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 30.0
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("okhttp/4.5.0", forHTTPHeaderField: "User-Agent")
        request.setValue("MSTranslatorAndroidApp::\(hmac)::\(date)::\(nonce)", forHTTPHeaderField: "X-Mt-Signature")
        return sgHttpProviderSignal(request: request, expected: batch.count) { json in
            guard let array = json as? [[String: Any]] else {
                return nil
            }
            return array.compactMap { ($0["translations"] as? [[String: Any]])?.first?["text"] as? String }
        }
    }
}

func sgYandexTranslate(texts: [String], fromLang: String? = nil, toLang: String) -> Signal<[(String, [MessageTextEntity])], TranslationError> {
    let target = sgProviderLanguage(toLang, microsoft: false)
    let supported = Set("az sq am en ar hy af eu ba be bn my bg bs cv cy hu vi ht gl nl mrj el ka gu da he yi id ga it is es kk kn ca ky zh ko xh km lo la lv lt lb mg ms ml mt mk mi mr mhr mn de ne no pa pap fa pl pt ro ru ceb sr si sk sl sw su tg th tl ta tt te tr udm uz uk ur fi fr hi hr cs sv gd et eo jv ja".split(separator: " ").map(String.init))
    guard supported.contains(target) else {
        return .fail(.invalidLanguage)
    }
    return sgTranslateBatches(texts: texts, maxCharacters: 5000) { batch in
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        guard let url = URL(string: "https://translate.yandex.net/api/v1/tr.json/translate?srv=android&id=\(id)-0-0") else {
            return .fail(.generic)
        }
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "lang", value: target), URLQueryItem(name: "format", value: "plain")] + batch.map { URLQueryItem(name: "text", value: $0) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        request.timeoutInterval = 30.0
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("ru.yandex.translate/21.15.4.21402814 (Xiaomi Redmi K20 Pro; Android 11)", forHTTPHeaderField: "User-Agent")
        return sgHttpProviderSignal(request: request, expected: batch.count) { value in
            guard let json = value as? [String: Any], json["code"] as? Int == 200 else {
                return nil
            }
            return json["text"] as? [String]
        }
    }
}
