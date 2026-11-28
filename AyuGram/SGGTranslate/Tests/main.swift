// Host check of the Yandex and Microsoft providers' request and response handling. Run from the repository root:
// swiftc -warnings-as-errors -o /tmp/ayu-translate-tests AyuGram/SGGTranslate/Sources/Ayu*Core.swift AyuGram/SGGTranslate/Tests/main.swift && /tmp/ayu-translate-tests
// With the argument "live" it also sends one request to each service.

import Foundation

var passed = 0
var failed = 0
func check(_ label: String, _ expected: String, _ actual: String) {
    if expected == actual {
        passed += 1
    } else {
        failed += 1
        print("FAILED \(label): expected \(expected), got \(actual)")
    }
}

func describe(_ result: Result<[String], AyuTranslateProviderError>) -> String {
    switch result {
    case let .success(texts):
        return texts.joined(separator: "|")
    case let .failure(error):
        return "\(error)"
    }
}

func parse(_ json: String, status: Int = 200, expected: Int = 1) -> String {
    return describe(AyuYandexTranslate.parseResponse(data: Data(json.utf8), statusCode: status, expected: expected))
}

check("language codes", "pt zh no he id ru en", ["pt-BR", "zh-hans-raw", "nb", "iw", "in", "RU", "en_US"].map(AyuYandexTranslate.languageCode).joined(separator: " "))
check("supported languages", "true true false false", "\(AyuYandexTranslate.isLanguageSupported("zh-hant")) \(AyuYandexTranslate.isLanguageSupported("nb")) \(AyuYandexTranslate.isLanguageSupported("zu")) \(AyuYandexTranslate.isLanguageSupported(""))")

check("request body", "lang=pt&format=plain&text=a+b%26c%3Dd%2B&text=%D0%BF%D1%80%D0%B8%D0%B2%D0%B5%D1%82%0A%F0%9F%99%82&text=x*y-z_.%7E",
      String(decoding: AyuYandexTranslate.requestBody(texts: ["a b&c=d+", "привет\n🙂", "x*y-z_.~"], toLang: "pt-BR"), as: UTF8.self))
let request = AyuYandexTranslate.request(texts: ["hi"], toLang: "ru", html: true)
check("request", "POST translate.yandex.net /api/v1/tr.json/translate true lang=ru&format=html&text=hi",
      "\(request.httpMethod ?? "") \(request.url?.host ?? "") \(request.url?.path ?? "") \(request.url?.query?.hasPrefix("&srv=android&id=") ?? false) \(String(decoding: request.httpBody ?? Data(), as: UTF8.self))")
check("one client id per launch", "true 32", "\(request.url == AyuYandexTranslate.request(texts: ["x"], toLang: "en").url) \((request.url?.query ?? "").dropFirst("&srv=android&id=".count).dropLast("-0-0".count).count)")

check("translations", "привет|мир", parse(#"{"code":200,"lang":"en-ru","text":["привет","мир"]}"#, expected: 2))
check("no code field means the HTTP status", "ok", parse(#"{"text":["ok"]}"#))
check("fewer texts than sent", "transient", parse(#"{"code":200,"text":["a"]}"#, expected: 2))
check("rate limits", "rateLimited rateLimited rateLimited", "\(parse(#"{"code":429,"message":"x"}"#)) \(parse(#"{"code":1052}"#)) \(parse(#"{"message":"x"}"#, status: 429))")
check("unsupported language", "languageUnsupported", parse(#"{"code":501,"message":"The specified translation direction is not supported"}"#, status: 400))
check("server failure", "transient transient", "\(parse(#"{"message":"x"}"#, status: 503)) \(describe(AyuYandexTranslate.parseResponse(data: nil, statusCode: 502, expected: 1)))")
check("other failures", "fatal fatal fatal", "\(parse(#"{"code":401}"#, status: 401)) \(parse(#"{"code":200}"#)) \(describe(AyuYandexTranslate.parseResponse(data: Data(), statusCode: 403, expected: 1)))")
check("empty or broken body of a successful answer", "transient transient", "\(describe(AyuYandexTranslate.parseResponse(data: Data(), statusCode: 200, expected: 1))) \(parse("<html>"))")

let byCount = AyuYandexTranslate.plan(texts: (0 ..< 25).map { "t\($0)" })
check("at most 20 texts in a request", "20 5", byCount.batches.map { "\($0.count)" }.joined(separator: " "))
let byLength = AyuYandexTranslate.plan(texts: [String(repeating: "a", count: 3000), String(repeating: "b", count: 2000), String(repeating: "c", count: 10)])
check("at most 5000 characters in a request", "2 1", byLength.batches.map { "\($0.count)" }.joined(separator: " "))

let long = String(repeating: "Lorem ipsum dolor sit amet. ", count: 400)
let longPlan = AyuYandexTranslate.plan(texts: ["short", long, "end"])
let longSent = longPlan.batches.flatMap { $0 }
check("a long text is cut at sentence ends into requests and joined back", "true 5 true true",
      "\(longPlan.batches.allSatisfy { $0.reduce(0) { $0 + $1.utf16.count } <= 5000 }) \(longSent.count) \(longPlan.joined(longSent) == ["short", long, "end"]) \(longSent.dropFirst().dropLast().allSatisfy { $0.hasPrefix("Lorem") && $0.hasSuffix("amet.") })")

let spaced = AyuYandexTranslate.plan(texts: ["  Hello world \n", " \n ", "", "Bye"])
check("outer whitespace is not sent", "Hello world|Bye", spaced.batches.flatMap { $0 }.joined(separator: "|"))
check("and comes back around the translation", "[  Привет мир \n][ \n ][][Пока]", (spaced.joined(["Привет мир", "Пока"]) ?? []).map { "[\($0)]" }.joined())
check("joining needs every translation", "nil nil", "\(spaced.joined(["a"]).map { "\($0)" } ?? "nil") \(spaced.joined(["a", "b", "c"]).map { "\($0)" } ?? "nil")")

let emoji = String(repeating: "👨‍👩‍👧‍👦", count: 1000)
let emojiParts = AyuTranslatePlan.splitLongText(emoji, limit: 5000)
check("a cut never falls inside a character", "true true", "\(emojiParts.joined() == emoji) \(emojiParts.allSatisfy { $0.utf16.count <= 5000 && $0.count * 11 == $0.utf16.count })")
check("line breaks are the first choice for a cut", "4991", "\(AyuTranslatePlan.splitLongText(String(repeating: "word. ", count: 831) + "tail\n" + String(repeating: "x", count: 200), limit: 5000).first?.utf16.count ?? 0)")

// Microsoft.
func parseMicrosoft(_ json: String, status: Int = 200, expected: Int = 1) -> String {
    return describe(AyuMicrosoftTranslate.parseResponse(data: Data(json.utf8), statusCode: status, expected: expected))
}
check("sealed string opens", "86 true", "\(AyuSealedString.open("VkoWrMP7SOoLpld96DpMgu62G2pGf-nql2-ArwaqpebuNvhBXWDd9dO607hKGNSk_kMvimVi2tfSTw9dSnzblT9IYMCO5KWoixFL73MvoMVQ7xGMhfkBHp-U6wBIuw")?.count ?? 0) \(AyuSealedString.open("short") == nil)")
check("microsoft language codes", "zh-Hans zh-Hant zh-Hans pt pt-pt nb fil he sr-Cyrl sr-Latn ru en",
      ["zh", "zh-hant-raw", "zh_CN", "pt-BR", "pt-PT", "no", "tl", "iw", "sr", "sr-latn", "RU", "en_US"].map(AyuMicrosoftTranslate.languageCode).joined(separator: " "))
let microsoftRequest = AyuMicrosoftTranslate.request(texts: ["hi \"there\"", "пока"], toLang: "ru", date: Date(timeIntervalSince1970: 1767225600), nonce: "0123456789abcdef0123456789abcdef")
check("microsoft request", "POST https://api.cognitive.microsofttranslator.com/translate?api-version=3.0&from=&to=ru&textType=plain okhttp/4.5.0 [{\"Text\":\"hi \\\"there\\\"\"},{\"Text\":\"пока\"}]",
      "\(microsoftRequest.httpMethod ?? "") \(microsoftRequest.url?.absoluteString ?? "") \(microsoftRequest.value(forHTTPHeaderField: "User-Agent") ?? "") \(String(decoding: microsoftRequest.httpBody ?? Data(), as: UTF8.self))")
// The same HMAC as Python's hmac module gives for this path, time and nonce.
check("microsoft signature", "MSTranslatorAndroidApp::XVMAf3WnoNM9Ja03iPgpi91L330ispxu2ejoyDtMKrA=::thu, 01 jan 2026 00:00:00GMT::0123456789abcdef0123456789abcdef", microsoftRequest.value(forHTTPHeaderField: "X-Mt-Signature") ?? "")
check("microsoft translations", "привет|мир", parseMicrosoft(#"[{"detectedLanguage":{"language":"en","score":1.0},"translations":[{"text":"привет","to":"ru"}]},{"translations":[{"text":"мир","to":"ru"}]}]"#, expected: 2))
check("microsoft fewer texts than sent", "transient", parseMicrosoft(#"[{"translations":[{"text":"a","to":"ru"}]}]"#, expected: 2))
check("microsoft failures", "fatal rateLimited languageUnsupported transient fatal transient transient",
      [parseMicrosoft(#"{"error":{"code":401000,"message":"The request is not authorized"}}"#, status: 401), parseMicrosoft(#"{"error":{"code":429000}}"#, status: 429), parseMicrosoft(#"{"error":{"code":400036,"message":"The target language is not valid."}}"#, status: 400), parseMicrosoft(#"{"error":{"code":500000}}"#, status: 500), parseMicrosoft(#"{"error":{"code":400000}}"#, status: 400), parseMicrosoft("<html>"), describe(AyuMicrosoftTranslate.parseResponse(data: nil, statusCode: 200, expected: 1))].joined(separator: " "))
let microsoftPlan = AyuMicrosoftTranslate.plan(texts: [String(repeating: "a", count: 4000), String(repeating: "b", count: 4000), String(repeating: "c", count: 4000), String(repeating: "d ", count: 3000)])
check("microsoft batches: 10000 per request, 5000 per text", "2 3", microsoftPlan.batches.map { "\($0.count)" }.joined(separator: " "))

if CommandLine.arguments.contains("live") {
    let microsoftSemaphore = DispatchSemaphore(value: 0)
    var microsoftLive = "no answer"
    URLSession(configuration: .ephemeral).dataTask(with: AyuMicrosoftTranslate.request(texts: ["Good morning", "Thank you & goodbye"], toLang: "ru")) { data, response, error in
        if let response = response as? HTTPURLResponse {
            microsoftLive = "HTTP \(response.statusCode): " + describe(AyuMicrosoftTranslate.parseResponse(data: data, statusCode: response.statusCode, expected: 2))
        } else {
            microsoftLive = "error: \(error?.localizedDescription ?? "unknown")"
        }
        microsoftSemaphore.signal()
    }.resume()
    _ = microsoftSemaphore.wait(timeout: .now() + 20.0)
    print("live microsoft: \(microsoftLive)")

    let semaphore = DispatchSemaphore(value: 0)
    var live = "no answer"
    URLSession(configuration: .ephemeral).dataTask(with: AyuYandexTranslate.request(texts: ["Good morning", "Thank you & goodbye"], toLang: "ru")) { data, response, error in
        if let response = response as? HTTPURLResponse {
            live = "HTTP \(response.statusCode): " + describe(AyuYandexTranslate.parseResponse(data: data, statusCode: response.statusCode, expected: 2))
        } else {
            live = "error: \(error?.localizedDescription ?? "unknown")"
        }
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 20.0)
    print("live: \(live)")
}

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
