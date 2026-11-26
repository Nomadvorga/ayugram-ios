import CVosk

enum VoskNativeLogging {
    static func disable() { vosk_set_log_level(-1) }
}
