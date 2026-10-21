import Foundation

/// The LightTalk blink protocol, v1.
///
/// A transmitter (Arduino + LED) sends text as light. A receiver (iPhone camera)
/// reads it back. This file is the single source of truth for the encoding —
/// the Arduino sketch (Transmitter.ino) implements the identical table.
///
/// Frame layout, transmitted in a loop:
///   PREAMBLE  1,0,1,0,1,0,1,0   (8 bits — receiver calibrates bright/dim levels here)
///   START     1,1,1,0,0,0        (6 bits — marks the beginning of a message)
///   CHARS     7 bits each: 6 data bits (MSB first) + 1 even-parity bit
///   END       1,1,1,1,1,1        (6 bits — all-ones, i.e. code 63)
///   GAP       LED off for 2.0 s  (then the loop repeats)
///
/// The markers use codes no letter can produce (the alphabet only uses codes
/// 0–41), so a character like H (000111) can never be mistaken for END.
///
/// Bit timing: 400 ms per bit (2.5 bits/sec). Slow on purpose — at 30 camera
/// frames/sec that's 12 frames per bit, which makes decoding robust in
/// daylight without any exotic signal processing.
enum BlinkProtocol {

    /// 6-bit alphabet. Index in this string IS the code. Must match Transmitter.ino.
    static let alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?"

    static let bitDuration: TimeInterval = 0.2
    static let preamble: [Int] = [1,0,1,0,1,0,1,0]
    static let startMarker: [Int] = [1,1,1,0,0,0]
    static let endMarker: [Int] = [1,1,1,1,1,1]
    static let interFrameGap: TimeInterval = 2.0

    /// Encode one character to 7 bits (6 data MSB-first + even parity).
    /// Returns nil for characters outside the alphabet.
    static func encode(_ ch: Character) -> [Int]? {
        let upper = String(ch).uppercased()
        guard upper.count == 1, let scalar = upper.unicodeScalars.first else { return nil }
        guard let idx = alphabet.firstIndex(of: Character(scalar)) else { return nil }
        let code = alphabet.distance(from: alphabet.startIndex, to: idx)
        var bits: [Int] = []
        for shift in stride(from: 5, through: 0, by: -1) {
            bits.append((code >> shift) & 1)
        }
        let parity = bits.reduce(0, +) % 2 == 0 ? 0 : 1   // even parity
        bits.append(parity)
        return bits
    }

    /// Decode 7 bits to a character. Returns (character, parityOK).
    static func decode(_ bits: [Int]) -> (Character, Bool)? {
        guard bits.count == 7 else { return nil }
        let data = Array(bits[0..<6])
        let parityBit = bits[6]
        let parityOK = (data.reduce(0, +) + parityBit) % 2 == 0
        let code = data.enumerated().reduce(0) { $0 + ($1.element << (5 - $1.offset)) }
        guard code < alphabet.count else { return nil }
        let idx = alphabet.index(alphabet.startIndex, offsetBy: code)
        return (alphabet[idx], parityOK)
    }

    /// Full bit stream for a message (preamble + start + chars + end).
    /// Characters outside the alphabet are skipped.
    static func bitStream(for message: String) -> [Int] {
        var bits = preamble + startMarker
        for ch in message.uppercased() {
            if let b = encode(ch) { bits += b }
        }
        bits += endMarker
        return bits
    }

    /// How long one transmission loop takes, in seconds (excluding the gap).
    static func airtime(for message: String) -> TimeInterval {
        Double(bitStream(for: message).count) * bitDuration + interFrameGap
    }
}
