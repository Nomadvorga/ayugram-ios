import Foundation
import SGSimpleSettings
import TelegramCore

/// Translate the existing editor modes into explicit provider instructions.
/// No Telegram conversation messages, AI chat history or attachments are sent.
enum ExteraAITextProcessing {
    static func generate(text: ComposedRichMessage, mode: TelegramComposeAIMessageMode, styles: [TextProcessingScreen.Style], completion: @escaping (Result<TelegramAIComposeMessageResult, ExteraAIError>) -> Void) throws -> ExteraAIRequest {
        let config = ExteraAISettings.shared.configuration
        guard let service = config.selectedService else { throw ExteraAIError.configuration("Select an AI service in exteraGram → Other → AI → Services first.") }
        let source: String
        switch text {
        case .empty: source = ""
        case let .plain(value, _): source = value
        case .rich: throw ExteraAIError.configuration("Custom AI editing supports plain text. Rich documents and their embedded media cannot be edited by this service.")
        }
        let instruction: String
        var prompt = source
        switch mode {
        case .proofread:
            instruction = "Correct the spelling and grammar of the supplied text. Preserve its meaning, language and formatting. Return only the corrected text."
        case let .generate(userPrompt):
            instruction = "Write the text requested by the user, using the supplied context if present. Respond in the language requested, or otherwise the user's language. Return only the generated text."
            prompt = "Request:\n" + userPrompt + (source.isEmpty ? "" : "\n\nContext:\n" + source)
        case let .translate(language, emojify, style):
            instruction = "Translate the supplied text into the language with locale identifier \(language). Preserve meaning and formatting. Return only the translation." + (emojify ? " Add suitable emoji where appropriate." : "") + (try self.styleInstruction(style, styles: styles))
        case let .stylize(emojify, style):
            instruction = "Rewrite the supplied text according to the requested style while preserving its meaning and language. Return only the rewritten text." + (emojify ? " Add suitable emoji where appropriate." : "") + (try self.styleInstruction(style, styles: styles))
        }
        let role = ExteraAIRole(name: "Text Editor", prompt: instruction)
        return try ExteraAIClient.generate(service: service, apiKey: ExteraAISettings.shared.apiKey(serviceId: service.id), role: role, prompt: prompt, temperature: config.temperature, stream: config.responseStreaming, completion: { result in
            switch result {
            case let .success(value):
                let output = value == source ? text : .plain(text: value, entities: [])
                completion(.success(TelegramAIComposeMessageResult(text: output, diffRanges: [])))
            case let .failure(error): completion(.failure(error))
            }
        })
    }

    private static func styleInstruction(_ style: TelegramComposeAIMessageMode.StyleReference, styles: [TextProcessingScreen.Style]) throws -> String {
        switch style {
        case .neutral: return ""
        case let .prompt(prompt): return "\nStyle instruction:\n" + prompt
        case let .style(reference):
            if let style = styles.first(where: { $0.reference == reference }) {
                switch style.cloudStyle.content {
                case let .standard(value): return "\nUse this tone: " + value.title
                case let .custom(value):
                    guard let prompt = value.prompt, !prompt.isEmpty else { throw ExteraAIError.configuration("The selected Telegram cloud style does not expose a prompt. Use a text prompt instead.") }
                    return "\nStyle instruction:\n" + prompt
                }
            }
            if case let .standard(value) = reference { return "\nUse this tone: " + value }
            throw ExteraAIError.configuration("This Telegram cloud style is unavailable for the selected AI service. Use a text prompt instead.")
        }
    }
}
