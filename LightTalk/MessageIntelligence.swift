import Foundation

/// The AI layer of LightTalk — and its limits are the point.
///
/// The light itself is NEVER read by AI. Reading blinks is deterministic signal
/// processing (BlinkDecoder): fast, explainable, demo-safe. AI only touches the
/// *meaning* of already-decoded text:
///   1. Repair — a character that failed parity ("WATER TRUCI�") gets a
///      context-aware best guess instead of a raw �.
///   2. Translate — a camp beacon's English code becomes the reader's language.
///   3. Expand — compact codes ("WTR-1400") become full sentences.
///
/// If the on-device model is unavailable (older iOS / Xcode 16 SDK builds),
/// everything degrades gracefully to deterministic rules — the app never
/// pretends AI did something it didn't.
struct DecodedMessage {
    let rawText: String
    /// character offsets that failed parity
    let uncertainIndices: Set<Int>
}

enum MessageIntelligence {

    /// Debug logging: visible in Xcode's console (View → Debug Area → Activate Console).
    /// Filter the console for [LightTalk]. Compiled out in release builds.
    static func debugLog(_ msg: String) {
        #if DEBUG
        print("[LightTalk] \(msg)")
        #endif
    }

    /// Human-readable label for the UI badge. Honesty as a feature.
    static var engineLabel: String {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            return FoundationModelAssist.isAvailable ? "AI assist · on-device" : "Direct decode"
        }
        #endif
        return "Direct decode"
    }

    /// Enhance a decoded message. Always calls completion exactly once, on main.
    /// - Parameters:
    ///   - language: a language code ("es", "hi", …) or "system" for the device language.
    ///   - customCodes: the user's own codebook, checked before built-in presets.
    static func enhance(_ message: DecodedMessage,
                        language: String = "system",
                        customCodes: [CustomCode] = [],
                        completion: @escaping (String, MeaningSource) -> Void) {
        // Deterministic first: user codebook, then built-in presets (translated).
        let deterministic = deterministicEnhance(message, customCodes: customCodes, language: language)
        debugLog("enhance raw='\(message.rawText)' lang='\(language)' → deterministic='\(deterministic)'")
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelAssist.isAvailable {
            // Codebook knew it and the text is clean: trust the codebook, skip the model.
            // The model only runs for unknown text or text with uncertain characters.
            if deterministic != message.rawText && message.uncertainIndices.isEmpty {
                debugLog("codebook hit — skipping model")
                completion(deterministic, .phrasebook)
                return
            }
            debugLog("asking on-device model")
            FoundationModelAssist.enhance(message, language: language, customCodes: customCodes,
                                          deterministicFallback: deterministic) { out in
                // If the model's answer differs from the deterministic result, the
                // model added the value. If it equals it, label honestly as direct.
                completion(out, out != deterministic ? .model : .direct)
            }
            return
        }
        #endif
        completion(deterministic, deterministic != message.rawText ? .phrasebook : .direct)
    }

    /// No-model path: expand user codes, then known beacon codes (translated),
    /// and bracket uncertain characters. This is what runs on every device,
    /// every time — the language picker works with or without the AI model.
    static func deterministicEnhance(_ message: DecodedMessage,
                                     customCodes: [CustomCode] = [],
                                     language: String = "system") -> String {
        var chars = Array(message.rawText)
        for i in message.uncertainIndices where i < chars.count {
            chars[i] = "�"
        }
        let raw = String(chars)
        let lang = resolveLanguage(language)
        // User's own codebook first — a camp's language wins (wildcards supported).
        if let custom = CustomCodeStore.expansion(for: raw, in: customCodes) {
            return custom
        }
        if let expanded = BeaconPresets.localizedExpansion(for: raw, language: lang) {
            return expanded
        }
        return raw
    }

    /// One-line digest of recent messages, for the History tab.
    static func digest(messages: [String], completion: @escaping (String) -> Void) {
        guard !messages.isEmpty else {
            completion("No messages to summarize.")
            return
        }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelAssist.isAvailable {
            let prompt = """
            These are short messages decoded from blinking LED beacons (most \
            recent first). Summarize what is happening in one plain sentence, \
            e.g. "Water at 2 PM, food at 6 PM, curfew at 8 PM."
            Messages: \(messages.joined(separator: " | "))
            Reply with ONLY the summary sentence.
            """
            Task {
                do {
                    let session = LanguageModelSession()
                    let response = try await session.respond(to: prompt)
                    let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    await MainActor.run { completion(text.isEmpty ? fallbackDigest(messages) : text) }
                } catch {
                    await MainActor.run { completion(fallbackDigest(messages)) }
                }
            }
            return
        }
        #endif
        completion(fallbackDigest(messages))
    }

    private static func fallbackDigest(_ messages: [String]) -> String {
        if messages.count == 1 {
            return "1 message received. Latest: \(messages[0])"
        }
        return "\(messages.count) messages received. Latest: \(messages[0])"
    }

    /// Plain English → beacon code ("water truck at 3pm" → "WTR 1500").
    /// Uses the on-device model when available; otherwise completes with nil
    /// so the UI can show its "try simpler words" message.
    static func naturalLanguageToCode(_ text: String,
                                      customCodes: [CustomCode],
                                      completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelAssist.isAvailable {
            FoundationModelAssist.naturalLanguageToCode(text, customCodes: customCodes,
                                                        completion: completion)
            return
        }
        #endif
        completion(nil)
    }

    /// Plain English → suggested (code, meaning) pair for the custom codebook.
    /// Same routing: on-device model if available, otherwise nil.
    static func suggestCodePair(_ text: String,
                                customCodes: [CustomCode],
                                completion: @escaping ((code: String, meaning: String)?) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelAssist.isAvailable {
            FoundationModelAssist.suggestCodePair(text, customCodes: customCodes,
                                                  completion: completion)
            return
        }
        #endif
        completion(nil)
    }

    /// Quick health check for the on-device model: pings it with a trivial
    /// prompt. Used by the Guide's "AI status" row so the user can see
    /// whether the ✨ features are actually live on this phone.
    enum ModelHealth { case ready, notReady, unavailable }

    static func checkModelHealth(completion: @escaping (ModelHealth) -> Void) {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), FoundationModelAssist.isAvailable {
            var done = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if !done { done = true; completion(.notReady) }
            }
            Task {
                do {
                    let session = LanguageModelSession()
                    let r = try await session.respond(to: "Reply with exactly: OK")
                    let ok = r.content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("OK")
                    if !done {
                        done = true
                        await MainActor.run { completion(ok ? .ready : .notReady) }
                    }
                } catch {
                    if !done {
                        done = true
                        await MainActor.run { completion(.notReady) }
                    }
                }
            }
            return
        }
        #endif
        completion(.unavailable)
    }

    /// Resolve "system" to the device language code.
    static func resolveLanguage(_ language: String) -> String {
        if language == "system" {
            return Locale.current.language.languageCode?.identifier ?? "en"
        }
        return language
    }
}

// MARK: - On-device model path (only compiled when the SDK provides it)

#if canImport(FoundationModels)
import FoundationModels

/// Thin wrapper over Apple's on-device Foundation Model. The prompt is
/// deliberately constrained: fix, translate, expand — never invent content
/// beyond the decoded characters.
@available(iOS 26.0, *)
enum FoundationModelAssist {

    static var isAvailable: Bool {
        // SystemLanguageModel availability check — cheap, synchronous.
        SystemLanguageModel.default.isAvailable
    }

    static func enhance(_ message: DecodedMessage,
                        language: String,
                        customCodes: [CustomCode],
                        deterministicFallback: String,
                        completion: @escaping (String) -> Void) {
        let uncertainList = message.uncertainIndices.sorted().map(String.init).joined(separator: ",")
        let lang = MessageIntelligence.resolveLanguage(language)
        // The model gets the FULL codebook — built-in presets plus user codes —
        // so it repairs and expands from knowledge, not imagination.
        let presetBook = BeaconPresets.all
            .map { "\"\($0.code)\" means \"\($0.detail)\"" }
            .joined(separator: "; ")
        let customBook = customCodes.map { "\"\($0.code)\" means \"\($0.meaning)\"" }.joined(separator: "; ")
        var bookLine = "Known codes: \(presetBook)."
        bookLine += " Pattern: \"WTR <HHMM>\" (e.g. \"WTR 1000\") means the water truck arrives at that time — same sentence as WTR 1400 with the time substituted."
        if !customBook.isEmpty {
            bookLine += " User-defined codes (use first): \(customBook)."
        }
        let prompt = """
        You received text decoded from a blinking LED beacon. \(bookLine)
        Decoded text: "\(message.rawText)"
        The characters at these 0-based positions failed their parity check and may be wrong: [\(uncertainList)].
        Task: 1) LITERAL codebook check: does the decoded text match a known code character-for-character, treating ONLY the flagged positions as wildcards? If yes, use that code's meaning. If no, the text is NOT a known code — do NOT substitute any other known code's meaning. NEVER turn "BEDS 34" into "SHL B" or any similar semantic guess. 2) Repair: you may change ONLY the flagged positions, one character each, smallest change first. NEVER change unflagged characters. 3) Translate the final result to language code "\(lang)" if not already in that language.
        Rules: NEVER invent new facts, numbers, or times. NEVER output the meaning of a code other than the one literally decoded. If the text matches no known code, translate it literally into "\(lang)". Reply with ONLY the final text, no explanation, no quotes.
        """
        MessageIntelligence.debugLog("model prompt lang='\(lang)' text='\(message.rawText)'")
        // Guard against semantic substitution: if the raw text does NOT
        // literally match a known code (flagged positions as wildcards),
        // the model may not answer with a DIFFERENT code's meaning verbatim.
        let cleanedRaw = message.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        func wildcardMatch(_ code: String) -> Bool {
            guard code.count == cleanedRaw.count else { return false }
            for (i, pair) in zip(cleanedRaw, code).enumerated() {
                if message.uncertainIndices.contains(i) { continue }
                if pair.0 != pair.1 { return false }
            }
            return true
        }
        let rawMatchesKnown = BeaconPresets.all.contains { wildcardMatch($0.code) }
            || customCodes.contains { wildcardMatch($0.code) }
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                MessageIntelligence.debugLog("model returned: '\(text)'")
                if !rawMatchesKnown {
                    let knownMeanings = BeaconPresets.all.map(\.detail) + customCodes.map(\.meaning)
                    if knownMeanings.contains(text) {
                        MessageIntelligence.debugLog("guard: rejected semantic substitution '\(text)'")
                        await MainActor.run { completion(deterministicFallback) }
                        return
                    }
                }
                await MainActor.run { completion(text.isEmpty ? deterministicFallback : text) }
            } catch {
                MessageIntelligence.debugLog("model error, using deterministic fallback")
                await MainActor.run { completion(deterministicFallback) }
            }
        }
    }

    // MARK: - Natural language → beacon code ("speak plainly, flash precisely")

    /// Converts a plain-English description into a valid beacon code.
    /// "water truck coming at 3pm" → "WTR 1500". Uses the on-device model;
    /// falls back to nil when the model is unavailable.
    static func naturalLanguageToCode(_ text: String, customCodes: [CustomCode],
                                     completion: @escaping (String?) -> Void) {
        #if canImport(FoundationModels)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(nil); return }

        let presetBook = BeaconPresets.all
            .map { "\"\($0.code)\" means \"\($0.detail)\"" }
            .joined(separator: "; ")
        let customBook = customCodes.map { "\"\($0.code)\" means \"\($0.meaning)\"" }.joined(separator: "; ")
        var bookLine = "Known codes: \(presetBook)."
        if !customBook.isEmpty { bookLine += " User codes: \(customBook)." }

        // The beacon alphabet: A-Z, 0-9, space, and : - . / ?
        let prompt = """
        You convert plain-English requests into short beacon codes for a blinking-LED messenger. \(bookLine)

        Convert the Request below. Do NOT output an unrelated known code — the output MUST come from the Request words.

        Examples:
        Request: "water truck coming at 3pm" → "WTR 1500"
        Request: "good morning" → "GOOD MORNING"
        Request: "need blankets" → "NEED BLANKETS"

        Request: "\(trimmed)"
        Rules:
        - If the request matches a known code (e.g. water truck → "WTR <HHMM>" with 24-hour time, medical → "MED <station>", food → "FOOD <HHMM>", curfew → "CRFW <HHMM>", shelter → "SHL <zone>", all-clear → "ALCLR"), output that code with the right details filled in.
        - Otherwise, compress the request into 2-4 uppercase words using ONLY letters A-Z, digits 0-9, spaces, and the symbols : - . / ?
        - Convert times to 24-hour HHMM: "3pm" → "1500", "2:00 PM" → "1400".
        - NEVER invent a code format that isn't in the known list; prefer plain uppercase words.
        Reply with ONLY the beacon code, no quotes, no explanation.
        """
        MessageIntelligence.debugLog("nl→code prompt: '\(trimmed)'")
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                var code = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                // Sanitize: keep only valid beacon characters, uppercase.
                let valid = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?")
                code = String(code.uppercased().filter { valid.contains($0) })
                    .trimmingCharacters(in: .whitespaces)
                MessageIntelligence.debugLog("nl→code result: '\(code)'")
                await MainActor.run { completion(code.isEmpty ? nil : code) }
            } catch {
                MessageIntelligence.debugLog("nl→code model error")
                await MainActor.run { completion(nil) }
            }
        }
        #else
        completion(nil)
        #endif
    }
    // MARK: - Suggest a new custom code ("describe it, get code + meaning")

    /// Suggests a (code, meaning) pair from a plain-English description.
    /// "second water truck at 3pm" → ("WTR2 1500", "Second water truck arrives at 3:00 PM").
    static func suggestCodePair(_ text: String, customCodes: [CustomCode],
                               completion: @escaping ((code: String, meaning: String)?) -> Void) {
        #if canImport(FoundationModels)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { completion(nil); return }

        let existing = (BeaconPresets.all.map { $0.code } + customCodes.map { $0.code })
            .joined(separator: ", ")
        let prompt = """
        You design short beacon codes for a blinking-LED messenger used in refugee camps.
        Existing codes (do NOT reuse these exactly): \(existing).

        Convert the Request below into a NEW code. Do NOT copy an existing code — create one from the Request words.

        Examples:
        Request: "good morning" → Code: "GOOD MORNING" / Meaning: "Good morning."
        Request: "need blankets" → Code: "BLANKET" / Meaning: "Blankets needed."
        Request: "second water truck at 3pm" → Code: "WTR2 1500" / Meaning: "Second water truck arrives at 3:00 PM."

        Request: "\(trimmed)"
        Rules:
        - Code: 2-8 uppercase characters/digits, optionally followed by a space and details (time as HHMM, zone, number). Use ONLY A-Z, 0-9, space, : - . / ?. If part of the message varies (like a time), end the code with " *" as a wildcard.
        - Meaning: one clear sentence explaining the code. If the code has a " *" wildcard, the meaning must contain " *" where the variable goes.
        - The code MUST relate to the Request words — never output an unrelated existing code.
        Reply with EXACTLY two lines: first line the CODE, second line the MEANING. No quotes, no explanation.
        """
        MessageIntelligence.debugLog("suggestCode prompt: '\(trimmed)'")
        Task {
            do {
                let session = LanguageModelSession()
                let response = try await session.respond(to: prompt)
                let lines = response.content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard lines.count >= 2 else {
                    await MainActor.run { completion(nil) }
                    return
                }
                let valid = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?*")
                let code = String(lines[0].uppercased().filter { valid.contains($0) })
                    .trimmingCharacters(in: .whitespaces)
                let meaning = lines[1...].joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                MessageIntelligence.debugLog("suggestCode result: '\(code)' / '\(meaning)'")
                await MainActor.run {
                    completion(code.isEmpty || meaning.isEmpty ? nil : (code, meaning))
                }
            } catch {
                MessageIntelligence.debugLog("suggestCode model error")
                await MainActor.run { completion(nil) }
            }
        }
        #else
        completion(nil)
        #endif
    }
}
#endif
