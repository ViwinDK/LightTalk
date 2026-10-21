import Foundation

/// A message received over light, with its AI enhancement.
/// Where a 💡 meaning line came from — shown honestly under each message.
enum MeaningSource: String, Codable {
    case phrasebook   // deterministic codebook expansion/translation
    case model        // on-device AI produced or repaired it
    case direct       // deterministic fallback (no model value added)

    var label: String {
        switch self {
        case .phrasebook: return "phrasebook"
        case .model: return "✨ on-device AI"
        case .direct: return "direct decode"
        }
    }
}

struct ReceivedMessage: Codable, Identifiable {
    let id: UUID
    let raw: String
    var enhanced: String?
    var meaningSource: MeaningSource?
    let timestamp: Date
    let uncertainCount: Int
    /// Character positions that failed parity — kept so re-translation
    /// (language chip tap) can ask the AI to repair again.
    let uncertainIndices: [Int]

    /// What to show / speak / share: the enhanced meaning when we have one.
    var displayText: String { enhanced ?? raw }
}

/// A user-defined beacon code: "my camp's shorthand" -> "what it means".
struct CustomCode: Codable, Identifiable {
    let id: UUID
    var code: String
    var meaning: String
}
