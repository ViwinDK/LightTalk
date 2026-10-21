import SwiftUI

/// Bit Inspector: tap any decoded character to see exactly how it traveled
/// as light. Shows the 7 bits (6 data + 1 parity), which bit is the parity
/// check, and whether the parity passed. The "how it works" made visible.
struct BitInspectorView: View {
    let character: Character
    let wasUncertain: Bool

    private var bits: [Int] {
        BlinkProtocol.encode(character) ?? []
    }

    private var parityOK: Bool {
        guard bits.count == 7 else { return false }
        let data = Array(bits[0..<6])
        return (data.reduce(0, +) + bits[6]) % 2 == 0
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // The character, big.
                Text(String(character))
                    .font(.system(size: 72, weight: .bold, design: .monospaced))
                    .foregroundColor(.yellow)

                // The 7 bits as tappable-looking cells.
                HStack(spacing: 8) {
                    ForEach(0..<bits.count, id: \.self) { i in
                        VStack(spacing: 4) {
                            Text("\(bits[i])")
                                .font(.title2).bold()
                                .frame(width: 44, height: 44)
                                .background(i == 6 ? Color.purple.opacity(0.4) : Color.blue.opacity(0.25))
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(i == 6 ? Color.purple : Color.blue.opacity(0.5), lineWidth: 2)
                                )
                            Text(i == 6 ? "parity" : "data \(i + 1)")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Explanation.
                VStack(alignment: .leading, spacing: 10) {
                    InspectorRow(
                        icon: "lightbulb.fill",
                        title: "6 data bits",
                        detail: "The character '\(String(character))' is #\(charIndex) in the LightTalk alphabet. In binary that's \(dataBitsString)."
                    )
                    InspectorRow(
                        icon: "checkmark.shield.fill",
                        title: "1 parity bit",
                        detail: parityOK
                            ? "Even parity holds: the 1s in all 7 bits add up to an even number, so this character arrived intact."
                            : "Parity FAILED — an even number of 1s was expected. This character may be wrong."
                    )
                    InspectorRow(
                        icon: "antenna.radiowaves.left.and.right",
                        title: "7 bits, 2.8 seconds",
                        detail: "At 400ms per bit, this single character took 2.8 seconds of blinking to arrive. Slow — but readable by any camera, with no pairing, no radio, no network."
                    )
                    if wasUncertain {
                        InspectorRow(
                            icon: "exclamationmark.triangle.fill",
                            title: "Flagged uncertain",
                            detail: "This character failed its parity check when it arrived. The AI tried to repair it from context — the ⚠️ count on the message says how many needed help."
                        )
                    }
                }
                .padding()

                Spacer()
            }
            .padding()
            .navigationTitle("Bit Inspector")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var charIndex: Int {
        let upper = String(character).uppercased()
        return BlinkProtocol.alphabet.distance(
            from: BlinkProtocol.alphabet.startIndex,
            to: BlinkProtocol.alphabet.firstIndex(of: Character(upper)) ?? BlinkProtocol.alphabet.startIndex
        )
    }

    private var dataBitsString: String {
        bits.prefix(6).map(String.init).joined()
    }
}

private struct InspectorRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.yellow)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
