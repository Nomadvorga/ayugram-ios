/// Adapter for the independent Vosk backend. Kept in this module so the frozen
/// Apple source and LocallyTranscribedAudio's existing initializer stay intact.
public func makeVoskTranscribedAudio(text: String, isFinal: Bool) -> LocallyTranscribedAudio {
    LocallyTranscribedAudio(text: text, isFinal: isFinal)
}
