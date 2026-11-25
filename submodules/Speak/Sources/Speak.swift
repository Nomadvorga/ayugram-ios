import Foundation
import AVFoundation

// Incuding at least one Objective-C class in a swift file ensures that it doesn't get stripped by the linker
private final class LinkHelperClass: NSObject {
}

public class SpeechSynthesizerHolder: NSObject, AVSpeechSynthesizerDelegate {
    private var speechSynthesizer: AVSpeechSynthesizer
    
    public var completion: () -> Void = {}
    private var didComplete = false
    
    init(speechSynthesizer: AVSpeechSynthesizer) {
        self.speechSynthesizer = speechSynthesizer
        
        super.init()
        
        self.speechSynthesizer.delegate = self
    }
    
    deinit {
        self.stop()
    }
    
    public func stop() {
        self.speechSynthesizer.stopSpeaking(at: .immediate)
    }
    
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        self.complete()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        self.complete()
    }

    private func complete() {
        guard !self.didComplete else {
            return
        }
        self.didComplete = true
        self.completion()
    }
}

public func supportedSpeakLanguages() -> Set<String> {
    var languages: [String] = []
    for voice in AVSpeechSynthesisVoice.speechVoices() {
        let components = voice.language.components(separatedBy: "-")
        if let language = components.first {
            languages.append(language)
        }
    }
    return Set(languages)
}

/// Speak text using an explicit language when supplied, otherwise detect its language.
public func speakText(text: String, language: String? = nil) -> SpeechSynthesizerHolder? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return nil
    }
    
    let speechSynthesizer = AVSpeechSynthesizer()
    let utterance = AVSpeechUtterance(string: text)
    if let language, !language.isEmpty {
        utterance.voice = AVSpeechSynthesisVoice(language: language.replacingOccurrences(of: "_", with: "-"))
    } else if #available(iOS 11.0, *), let language = NSLinguisticTagger.dominantLanguage(for: text) {
        utterance.voice = AVSpeechSynthesisVoice(language: language)
    }
    let holder = SpeechSynthesizerHolder(speechSynthesizer: speechSynthesizer)
    speechSynthesizer.speak(utterance)
    return holder
}
