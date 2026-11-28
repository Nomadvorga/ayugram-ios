// Ported from exteraGram for Android (com.exteragram.messenger.backup.InvisibleEncryptor), GPL v3 or later, © exteraGram.

import Foundation

// The text of a settings backup: every byte written as a base 11 number in invisible characters.
// Not a secret, only a way to keep the file from looking like editable text.
public enum InvisibleEncryptor {
    private static let characters: [Unicode.Scalar] = ["\u{200A}", "\u{200B}", "\u{200C}", "\u{200F}", "\u{202F}", "\u{206A}", "\u{206B}", "\u{206C}", "\u{206D}", "\u{206E}", "\u{206F}"]
    private static let prefix: [Unicode.Scalar] = ["\u{2001}", "\u{2002}"]
    private static let separator: Unicode.Scalar = "\u{2000}"

    public static func encode(_ source: String) -> String {
        var result = String.UnicodeScalarView()
        result.append(contentsOf: self.prefix)
        var first = true
        for byte in source.utf8 {
            if !first {
                result.append(self.separator)
            }
            first = false
            var value = Int(byte)
            var digits: [Unicode.Scalar] = []
            while value > 0 {
                digits.append(self.characters[value % self.characters.count])
                value /= self.characters.count
            }
            result.append(contentsOf: digits.reversed())
        }
        return String(result)
    }

    // nil for text that is not an encoded backup or does not hold UTF-8.
    public static func decode(_ source: String) -> String? {
        let scalars = Array(source.unicodeScalars)
        guard scalars.starts(with: self.prefix) else {
            return nil
        }
        var bytes: [UInt8] = []
        var value = 0
        for scalar in scalars.dropFirst(self.prefix.count) {
            if scalar == self.separator {
                guard value <= 255 else {
                    return nil
                }
                bytes.append(UInt8(value))
                value = 0
            } else if let digit = self.characters.firstIndex(of: scalar) {
                value = value * self.characters.count + digit
                if value > 255 {
                    return nil
                }
            } else if scalar.properties.isWhitespace {
                continue
            } else {
                return nil
            }
        }
        bytes.append(UInt8(value))
        // Android's split drops the empty groups at the end, which stand for zero bytes.
        while bytes.last == 0 {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    public static func isEncrypted(_ source: String) -> Bool {
        let scalars = Array(source.unicodeScalars)
        guard scalars.starts(with: self.prefix) else {
            return false
        }
        return scalars.dropFirst(self.prefix.count).allSatisfy { self.characters.contains($0) || $0.properties.isWhitespace }
    }
}
