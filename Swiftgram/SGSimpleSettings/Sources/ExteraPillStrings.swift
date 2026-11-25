import Foundation

/// Pill-specific English/Russian text, selected using AccountContext's presentation language by UI
/// callers. Keep endpoint values and user labels untouched. Other interface languages fall back to EN.
public func exteraPillText(_ languageCode: String, _ english: String, _ russian: String) -> String {
    return exteraPillLanguageCode(languageCode).split(separator: "-").first == "ru" ? russian : english
}

public func exteraPillLanguageCode(_ languageCode: String) -> String {
    var code = languageCode.lowercased().replacingOccurrences(of: "_", with: "-")
    if code.hasSuffix("-raw") { code.removeLast(4) }
    return code
}

public func exteraPillErrorDescription(_ error: ExteraPillError, languageCode: String) -> String {
    switch error {
    case .invalidConfiguration:
        return exteraPillText(languageCode, "Check the label, URL, path, and refresh interval.", "Проверьте название, URL, путь JSON и интервал обновления.")
    case .invalidPath:
        return exteraPillText(languageCode, "Invalid JSON path", "Неверный путь JSON")
    case .missingValue:
        return exteraPillText(languageCode, "The path must select a nonempty scalar value.", "Путь должен указывать на непустую строку, число или логическое значение.")
    case .invalidNumber:
        return exteraPillText(languageCode, "The selected value is not a valid number.", "Выбранное значение не является допустимым числом.")
    case .invalidJSON:
        return exteraPillText(languageCode, "The response is not valid JSON.", "Ответ не является корректным JSON.")
    case .responseTooLarge:
        return exteraPillText(languageCode, "Response exceeds 512 KB.", "Размер ответа превышает 512 КБ.")
    case let .httpStatus(code): return "HTTP \(code)"
    case .network:
        return exteraPillText(languageCode, "Request failed. Check the endpoint and connection.", "Ошибка запроса. Проверьте адрес сервера и подключение.")
    case .invalidFile:
        return exteraPillText(languageCode, "Invalid pill file (maximum 64 KB).", "Недопустимый файл плашек (максимум 64 КБ).")
    case .unsupportedVersion:
        return exteraPillText(languageCode, "Unsupported pill file version.", "Версия файла плашек не поддерживается.")
    case .limitReached:
        return exteraPillText(languageCode, "A maximum of 24 pills is supported.", "Можно добавить не более 24 плашек.")
    }
}
