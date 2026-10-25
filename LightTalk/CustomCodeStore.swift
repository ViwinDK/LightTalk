import Foundation
import Combine
import SwiftUI

/// User-defined beacon codes, persisted on device. A camp defines its own
/// shorthand; the phone learns it. Checked before the built-in presets.
final class CustomCodeStore: ObservableObject {
    static let shared = CustomCodeStore()

    @Published var codes: [CustomCode] = [] {
        didSet { save() }
    }

    private let key = "lighttalk.customCodes.v1"

    private init() { load() }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CustomCode].self, from: data)
        else { return }
        codes = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(codes) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Deterministic expansion of a user code, or nil.
    /// Supports wildcards: a code ending in "*" (e.g. "WTR *") matches any
    /// message starting with that prefix, and the "*" in the meaning is
    /// replaced with the variable part. So "WTR *" + "Water truck at *" turns
    /// a decoded "WTR 1500" into "Water truck at 1500" — define the code once,
    /// and the time (or any variable) flows through automatically.
    func expansion(for raw: String) -> String? {
        Self.expansion(for: raw, in: codes)
    }

    static func expansion(for raw: String, in codes: [CustomCode]) -> String? {
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !k.isEmpty else { return nil }
        // Exact match first.
        if let exact = codes.first(where: { $0.code.uppercased() == k }) {
            return fillTemplate(exact.meaning, with: "")
        }
        // Wildcard match.
        for entry in codes where entry.code.hasSuffix("*") {
            let prefix = String(entry.code.dropLast()).trimmingCharacters(in: .whitespaces).uppercased()
            guard !prefix.isEmpty, k.hasPrefix(prefix) else { continue }
            // The variable part, taken from the ORIGINAL (un-uppercased) text.
            let rawTrimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let param: String
            if rawTrimmed.uppercased().hasPrefix(prefix) {
                let idx = rawTrimmed.index(rawTrimmed.startIndex, offsetBy: min(prefix.count, rawTrimmed.count))
                param = String(rawTrimmed[idx...]).trimmingCharacters(in: .whitespaces)
            } else {
                param = ""
            }
            return fillTemplate(entry.meaning, with: param)
        }
        return nil
    }

    private static func fillTemplate(_ meaning: String, with param: String) -> String {
        if meaning.contains("*") {
            return meaning.replacingOccurrences(of: "*", with: param)
        }
        return param.isEmpty ? meaning : "\(meaning) \(param)"
    }

    private func fillTemplate(_ meaning: String, with param: String) -> String {
        Self.fillTemplate(meaning, with: param)
    }

    func add(code: String, meaning: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !m.isEmpty else { return }
        // Replace an existing entry with the same code.
        codes.removeAll { $0.code.uppercased() == c }
        codes.append(CustomCode(id: UUID(), code: c, meaning: m))
    }

    func delete(at offsets: IndexSet) {
        codes.remove(atOffsets: offsets)
    }

    /// Edit an existing entry in place. If the code string itself changed,
    /// the old entry is removed and the new one added (same as re-adding).
    func update(oldCode: String, code: String, meaning: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let m = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !m.isEmpty else { return }
        codes.removeAll { $0.code.uppercased() == oldCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        codes.append(CustomCode(id: UUID(), code: c, meaning: m))
    }

    /// Delete a single entry by code string (used by the edit sheet).
    func delete(code: String) {
        let c = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        codes.removeAll { $0.code.uppercased() == c }
    }
}
