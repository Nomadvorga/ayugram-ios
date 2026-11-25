import Foundation
import SwiftSignalKit

public enum TranslateFetchError {
    case network
    case limitExceeded
}

private let sgTranslateSessionConfiguration: URLSessionConfiguration = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpMaximumConnectionsPerHost = 2
    configuration.timeoutIntervalForResource = 60.0
    return configuration
}()
private let sgTranslateSession: URLSession = URLSession(configuration: sgTranslateSessionConfiguration)

public func getTranslateUrl(_ message: String, _ toLang: String, fromLang: String? = nil) -> String {
    var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
    components?.queryItems = [
        URLQueryItem(name: "client", value: "gtx"),
        URLQueryItem(name: "sl", value: fromLang.flatMap { $0.isEmpty || $0.lowercased() == "auto" ? nil : getGTranslateLang($0) } ?? "auto"),
        URLQueryItem(name: "tl", value: getGTranslateLang(toLang)),
        URLQueryItem(name: "dt", value: "t"),
        URLQueryItem(name: "ie", value: "UTF-8"),
        URLQueryItem(name: "oe", value: "UTF-8"),
        URLQueryItem(name: "q", value: message)
    ]
    // A literal '+' must survive form-style query decoding at the provider.
    return components?.url?.absoluteString.replacingOccurrences(of: "+", with: "%2B") ?? ""
}

public func parseTranslateResponse(_ data: String) -> String {
    guard let responseData: Data = data.data(using: .utf8),
          let response: [Any] = try? JSONSerialization.jsonObject(with: responseData) as? [Any],
          let segments: [Any] = response.first as? [Any] else {
        return ""
    }
    return segments.compactMap { segment in
        return (segment as? [Any])?.first as? String
    }.joined()
}

public func getGTranslateLang(_ userLang: String) -> String {
    var lang: String = userLang
    let rawSuffix: String = "-raw"
    if lang.hasSuffix(rawSuffix) {
        lang = String(lang.dropLast(rawSuffix.count))
    }
    lang = lang.replacingOccurrences(of: "_", with: "-").lowercased()

    if lang.hasPrefix("zh-") {
        return lang.contains("hant") || lang.contains("tw") || lang.contains("hk") || lang.contains("mo") ? "zh-TW" : "zh-CN"
    }

    lang = lang.components(separatedBy: "-")[0]

    switch lang {
    case "zh-hans", "zh":
        return "zh-CN"
    case "zh-hant":
        return "zh-TW"
    case "he":
        return "iw"
    case "nb":
        return "no"
    case "fil":
        return "tl"
    default:
        break
    }

    return lang
}

public func requestTranslateUrl(url: URL) -> Signal<String, TranslateFetchError> {
    return sgRequestTranslateUrl(url: url, attempt: 0)
}

private func sgRequestTranslateUrl(url: URL, attempt: Int) -> Signal<String, TranslateFetchError> {
    return deferred {
        sgRequestTranslateUrlAttempt(url: url, attempt: attempt)
    }
}

private func sgRequestTranslateUrlAttempt(url: URL, attempt: Int) -> Signal<String, TranslateFetchError> {
    let retryAfter = Atomic(value: pow(2.0, Double(attempt)))
    let retryable = Atomic(value: false)
    let signal = Signal<String, TranslateFetchError> { subscriber in
        let completed: Atomic<Bool> = Atomic(value: false)
        var request: URLRequest = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30.0
        request.setValue(sgGTranslateUserAgent(), forHTTPHeaderField: "User-Agent")
        let downloadTask: URLSessionDataTask = sgTranslateSession.dataTask(with: request, completionHandler: { data, response, error in
            let _ = completed.swap(true)
            guard error == nil else {
                _ = retryable.swap(true)
                subscriber.putError(.network)
                return
            }
            if let response: HTTPURLResponse = response as? HTTPURLResponse {
                if response.statusCode == 200 {
                    if let data: Data = data, data.count <= 2 * 1024 * 1024 {
                        if let result: String = String(data: data, encoding: .utf8) {
                            subscriber.putNext(result)
                            subscriber.putCompletion()
                        } else {
                            subscriber.putError(.network)
                        }
                    } else {
                        subscriber.putError(.network)
                    }
                } else {
                    _ = retryable.swap(response.statusCode == 429 || response.statusCode == 408 || (500 ..< 600).contains(response.statusCode))
                    if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
                        _ = retryAfter.swap(min(30.0, max(1.0, seconds)))
                    }
                    subscriber.putError(response.statusCode == 429 ? .limitExceeded : .network)
                }
            } else {
                subscriber.putError(.network)
            }
        })
        downloadTask.resume()

        return ActionDisposable {
            if !completed.with({ $0 }) {
                downloadTask.cancel()
            }
        }
    }
    return signal |> `catch` { error -> Signal<String, TranslateFetchError> in
        guard attempt < 2, retryable.with({ $0 }) else {
            return .fail(error)
        }
        let retry: Signal<Void, TranslateFetchError> = .single(Void())
        return retry
        |> delay(retryAfter.with({ $0 }), queue: .concurrentDefaultQueue())
        |> mapToSignal { _ in sgRequestTranslateUrl(url: url, attempt: attempt + 1) }
    }
}

private func sgGTranslateUserAgent() -> String {
    let userAgents = [
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
    ]
    return userAgents.randomElement() ?? userAgents[0]
}

public func gtranslate(_ text: String, _ toLang: String, fromLang: String? = nil) -> Signal<String, TranslateFetchError> {
    let lines: [String] = text.components(separatedBy: "\n")

    let translationSignals: [Signal<String, TranslateFetchError>] = lines.map { rawLine in
        let leadingWhitespace: Substring = rawLine.prefix { $0.isWhitespace }
        let trailingWhitespace: String = String(rawLine.reversed().prefix { $0.isWhitespace }.reversed())
        let core: String = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

        if core.isEmpty {
            return .single(rawLine)
        }

        let chunks = gtranslateSplitTextBySentences(core)
        var signal: Signal<String, TranslateFetchError> = .single("")
        for chunk in chunks {
            signal = signal |> mapToSignal { accumulated in
                let leading = String(chunk.prefix { $0.isWhitespace })
                let trailing = String(chunk.reversed().prefix { $0.isWhitespace }.reversed())
                let core = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
                if core.isEmpty {
                    return .single(accumulated + chunk)
                }
                return gtranslateSentence(core, toLang, fromLang: fromLang)
                |> map { accumulated + leading + $0 + trailing }
            }
        }
        return signal
        |> map { translatedCore in
            return String(leadingWhitespace) + translatedCore + trailingWhitespace
        }
    }

    // Serialize lines as well as long chunks; pasting a long message must not
    // create hundreds of simultaneous HTTP requests.
    var signal: Signal<[String], TranslateFetchError> = .single([])
    for translation in translationSignals {
        signal = signal |> mapToSignal { accumulated in
            return translation |> map { accumulated + [$0] }
        }
    }
    return signal
    |> map { results in
        let joined: String = results.joined(separator: "\n")
        return joined.isEmpty ? text : joined
    }
}

public func gtranslateSentence(_ text: String, _ toLang: String, fromLang: String? = nil) -> Signal<String, TranslateFetchError> {
    guard let url = URL(string: getTranslateUrl(text, toLang, fromLang: fromLang)), url.absoluteString.utf8.count <= 8192 else {
        return .fail(.network)
    }
    return requestTranslateUrl(url: url)
    |> mapToSignal { response -> Signal<String, TranslateFetchError> in
        let result = parseTranslateResponse(response)
        guard !result.isEmpty else {
            return .fail(.network)
        }
        return .single(result)
    }
}

public func gtranslateSplitTextBySentences(_ text: String, maxChunkLength: Int = 1500) -> [String] {
    // Bound the encoded GET URL as well as the text. A single sentence, emoji or
    // non-Latin text can otherwise exceed HTTP URL limits even below 1500 chars.
    let maxChunkLength = max(1, maxChunkLength)
    if text.utf8.count <= maxChunkLength {
        return [text]
    }
    var chunks: [String] = []
    var currentChunk = ""
    var byteCount = 0
    for character in text {
        let count = String(character).utf8.count
        if !currentChunk.isEmpty && byteCount + count > maxChunkLength {
            if let boundary = currentChunk.lastIndex(where: { $0.isWhitespace }), currentChunk[currentChunk.index(after: boundary)...].utf8.count + count <= maxChunkLength {
                let end = currentChunk.index(after: boundary)
                chunks.append(String(currentChunk[..<end]))
                currentChunk = String(currentChunk[end...])
                byteCount = currentChunk.utf8.count
            } else {
                chunks.append(currentChunk)
                currentChunk = ""
                byteCount = 0
            }
        }
        currentChunk.append(character)
        byteCount += count
    }

    if !currentChunk.isEmpty {
        chunks.append(currentChunk)
    }

    return chunks
}
