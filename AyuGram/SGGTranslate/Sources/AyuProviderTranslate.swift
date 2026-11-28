import Foundation
import SwiftSignalKit

// MARK: AyuGram
// Translation through Yandex and Microsoft (exteraGram's HttpTranslator providers): the requests themselves.

private let ayuProviderTranslateSession = URLSession(configuration: .ephemeral)

private typealias AyuProviderParser = (Data?, Int, Int) -> Result<[String], AyuTranslateProviderError>

private func ayuProviderTranslateRequest(_ request: URLRequest, expected: Int, parse: @escaping AyuProviderParser) -> Signal<[String], AyuTranslateProviderError> {
    return Signal { subscriber in
        let task = ayuProviderTranslateSession.dataTask(with: request, completionHandler: { data, response, _ in
            guard let response = response as? HTTPURLResponse else {
                subscriber.putError(.transient)
                return
            }
            switch parse(data, response.statusCode, expected) {
            case let .success(translated):
                subscriber.putNext(translated)
                subscriber.putCompletion()
            case let .failure(error):
                subscriber.putError(error)
            }
        })
        task.resume()

        return ActionDisposable {
            task.cancel()
        }
    }
}

// The translations of a plan's texts, in order. A failure that may pass is tried once more a second later;
// the caller decides what to fall back to after that. `request` is made anew for every attempt.
private func ayuProviderTranslate(plan: AyuTranslatePlan, request: @escaping ([String]) -> URLRequest, parse: @escaping AyuProviderParser) -> Signal<[String], AyuTranslateProviderError> {
    var signal: Signal<[String], AyuTranslateProviderError> = .single([])
    for batch in plan.batches {
        signal = signal
        |> mapToSignal { translated -> Signal<[String], AyuTranslateProviderError> in
            return ayuProviderTranslateRequest(request(batch), expected: batch.count, parse: parse)
            |> `catch` { error -> Signal<[String], AyuTranslateProviderError> in
                switch error {
                case .transient, .rateLimited:
                    return Signal<Void, AyuTranslateProviderError>.single(Void())
                    |> delay(1.0, queue: Queue.concurrentDefaultQueue())
                    |> mapToSignal { _ in
                        return ayuProviderTranslateRequest(request(batch), expected: batch.count, parse: parse)
                    }
                case .languageUnsupported, .fatal:
                    return .fail(error)
                }
            }
            |> map { translated + $0 }
        }
    }
    return signal
    |> mapToSignal { translated -> Signal<[String], AyuTranslateProviderError> in
        if let result = plan.joined(translated) {
            return .single(result)
        } else {
            return .fail(.transient)
        }
    }
}

public func ayuYandexTranslate(texts: [String], toLang: String) -> Signal<[String], AyuTranslateProviderError> {
    guard AyuYandexTranslate.isLanguageSupported(toLang) else {
        return .fail(.languageUnsupported)
    }
    return ayuProviderTranslate(plan: AyuYandexTranslate.plan(texts: texts), request: { batch in
        return AyuYandexTranslate.request(texts: batch, toLang: toLang)
    }, parse: { data, statusCode, expected in
        return AyuYandexTranslate.parseResponse(data: data, statusCode: statusCode, expected: expected)
    })
}

public func ayuMicrosoftTranslate(texts: [String], toLang: String) -> Signal<[String], AyuTranslateProviderError> {
    return ayuProviderTranslate(plan: AyuMicrosoftTranslate.plan(texts: texts), request: { batch in
        return AyuMicrosoftTranslate.request(texts: batch, toLang: toLang)
    }, parse: { data, statusCode, expected in
        return AyuMicrosoftTranslate.parseResponse(data: data, statusCode: statusCode, expected: expected)
    })
}
