import SwiftUI

/// History tab: every message the phone has ever decoded, with AI digest.
struct HistoryView: View {
    @ObservedObject private var decoder = BlinkDecoder.shared
    @StateObject private var speaker = Speaker()
    @State private var shareText = ""
    @State private var showingShare = false
    @State private var digestText: String? = nil
    @State private var digesting = false

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }

    var body: some View {
        NavigationStack {
            List {
                if let d = digestText {
                    Section("AI digest") {
                        Text(d).font(.callout)
                    }
                }
                Section {
                    ForEach(decoder.messages) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.raw)
                                    .font(.system(.headline, design: .monospaced))
                                Spacer()
                                Text(dateFormatter.string(from: entry.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            if let em = entry.enhanced, em != entry.raw {
                                Text("💡 " + em)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .lineLimit(4)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if entry.uncertainCount > 0 {
                                Text("⚠️ \(entry.uncertainCount) uncertain character(s)")
                                    .font(.caption2)
                                    .foregroundColor(.orange)
                            }
                            HStack {
                                Button {
                                    speaker.speak(entry.displayText)
                                } label: {
                                    Label("Speak", systemImage: "speaker.wave.2.fill")
                                        .font(.caption)
                                }
                                Button {
                                    shareText = entry.displayText
                                    showingShare = true
                                } label: {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                        .font(.caption)
                                }
                                Spacer()
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                } header: {
                    Text("\(decoder.messages.count) messages")
                }
            }
            .navigationTitle("History")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("Summarize") { summarize() }
                        .disabled(decoder.messages.isEmpty || digesting)
                    Button("Clear", role: .destructive) {
                        decoder.clearHistory()
                        digestText = nil
                    }
                    .disabled(decoder.messages.isEmpty)
                }
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(text: shareText)
            }
            .overlay {
                if decoder.messages.isEmpty {
                    ContentUnavailableView("No messages yet",
                                           systemImage: "lightbulb",
                                           description: Text("Decoded messages appear here automatically."))
                }
            }
        }
    }

    private func summarize() {
        digesting = true
        let texts = decoder.messages.prefix(20).map { $0.displayText }
        MessageIntelligence.digest(messages: texts) { out in
            digestText = out
            digesting = false
        }
    }
}
