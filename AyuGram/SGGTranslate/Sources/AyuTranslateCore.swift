// Ported from exteraGram for Android (com.exteragram.messenger.translator.core.ProviderLimits, TranslationError,
// TranslationDispatcher's batching and utils.text.SealedString), GPL v3 or later, © exteraGram.

import Foundation
import CommonCrypto

public enum AyuTranslateProviderError: Error, Equatable {
    // Too many requests; worth another try later.
    case rateLimited
    // The service failed this time; worth another try.
    case transient
    case languageUnsupported
    case fatal
}

func ayuTranslateHTTPError(_ statusCode: Int) -> AyuTranslateProviderError {
    if statusCode == 429 {
        return .rateLimited
    } else if (500 ... 599).contains(statusCode) {
        return .transient
    } else {
        return .fatal
    }
}

private let ayuTranslateFormAllowed: CharacterSet = {
    var allowed = CharacterSet()
    allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._*")
    return allowed
}()

// Java's URLEncoder: everything but ASCII letters, digits and "-._*" escaped, a space as "+".
func ayuTranslateFormEncoded(_ value: String) -> String {
    return (value.addingPercentEncoding(withAllowedCharacters: ayuTranslateFormAllowed) ?? "").replacingOccurrences(of: "%20", with: "+")
}

public struct AyuTranslateLimits: Equatable {
    public let maxTextsPerRequest: Int
    // Lengths are in UTF-16 units.
    public let maxCharsPerText: Int
    public let maxCharsPerRequest: Int

    public init(maxTextsPerRequest: Int, maxCharsPerText: Int, maxCharsPerRequest: Int) {
        self.maxTextsPerRequest = maxTextsPerRequest
        self.maxCharsPerText = maxCharsPerText
        self.maxCharsPerRequest = maxCharsPerRequest
    }
}

// How texts go to a service and come back: in requests within its limits. A text longer than a request is
// cut at a line break, a sentence end or a space where there is one. Only the part of a piece between its
// outer whitespace is sent, and the whitespace is put back around the translation, so nothing is lost where
// pieces meet.
public struct AyuTranslatePlan {
    struct Piece {
        let prefix: String
        let suffix: String
        // False for a piece of nothing but whitespace, which stays as it is.
        let isSent: Bool
    }

    public let batches: [[String]]
    let pieces: [[Piece]]

    public init(texts: [String], limits: AyuTranslateLimits) {
        var sent: [String] = []
        var pieces: [[Piece]] = []
        for text in texts {
            var textPieces: [Piece] = []
            for part in AyuTranslatePlan.splitLongText(text, limit: min(limits.maxCharsPerText, limits.maxCharsPerRequest)) {
                let core = part.trimmingCharacters(in: .whitespacesAndNewlines)
                if core.isEmpty {
                    textPieces.append(Piece(prefix: part, suffix: "", isSent: false))
                } else if let range = part.range(of: core) {
                    textPieces.append(Piece(prefix: String(part[part.startIndex ..< range.lowerBound]), suffix: String(part[range.upperBound...]), isSent: true))
                    sent.append(core)
                }
            }
            pieces.append(textPieces)
        }

        var batches: [[String]] = []
        var current: [String] = []
        var currentLength = 0
        for part in sent {
            let length = part.utf16.count
            if !current.isEmpty && (current.count >= limits.maxTextsPerRequest || currentLength + length > limits.maxCharsPerRequest) {
                batches.append(current)
                current = []
                currentLength = 0
            }
            current.append(part)
            currentLength += length
        }
        if !current.isEmpty {
            batches.append(current)
        }
        self.batches = batches
        self.pieces = pieces
    }

    // The translation of every text, from the translations of the batches in order; nil when some are missing.
    public func joined(_ translated: [String]) -> [String]? {
        guard translated.count == self.batches.reduce(0, { $0 + $1.count }) else {
            return nil
        }
        var index = 0
        return self.pieces.map { textPieces in
            var result = ""
            for piece in textPieces {
                result += piece.prefix
                if piece.isSent {
                    result += translated[index]
                    index += 1
                }
                result += piece.suffix
            }
            return result
        }
    }

    static func splitLongText(_ text: String, limit maxLength: Int) -> [String] {
        var result: [String] = []
        var rest = Substring(text)
        while rest.utf16.count > maxLength {
            let limit = String.Index(utf16Offset: rest.startIndex.utf16Offset(in: text) + maxLength, in: text)
            // Never inside a character.
            let end = text.rangeOfComposedCharacterSequence(at: limit).lowerBound
            let window = rest[rest.startIndex ..< end]
            var cut = end
            for separators in ["\n", ".!?…", " "] {
                if let index = window.lastIndex(where: { separators.contains($0) }), index > window.startIndex {
                    cut = window.index(after: index)
                    break
                }
            }
            result.append(String(rest[rest.startIndex ..< cut]))
            rest = rest[cut...]
        }
        result.append(String(rest))
        return result
    }
}

// exteraGram's SealedString: text kept out of plain sight in the sources. URL-safe Base64 of an 8 byte salt
// and the text XORed with SHA-256(key + salt + block number) blocks.
public enum AyuSealedString {
    private static let key = Array("exteraGram/SealedString/v1".utf8)
    private static let saltLength = 8

    public static func open(_ sealed: String) -> String? {
        var base64 = sealed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64 += "="
        }
        guard let data = Data(base64Encoded: base64), data.count >= saltLength else {
            return nil
        }
        let bytes = [UInt8](data)
        var plain = [UInt8](repeating: 0, count: bytes.count - saltLength)
        var block: [UInt8] = []
        for index in 0 ..< plain.count {
            let offset = index % 32
            if offset == 0 {
                block = sha256(key + bytes[0 ..< saltLength] + [UInt8(truncatingIfNeeded: index / 32)])
            }
            plain[index] = bytes[saltLength + index] ^ block[offset]
        }
        return String(bytes: plain, encoding: .utf8)
    }

    static func sha256(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        _ = CC_SHA256(bytes, CC_LONG(bytes.count), &digest)
        return digest
    }

    static func hmacSHA256(key: [UInt8], message: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CCHmac(CCHmacAlgorithm(kCCHmacAlgSHA256), key, key.count, message, message.count, &digest)
        return digest
    }
}
