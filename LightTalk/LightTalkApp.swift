import SwiftUI
import Combine

@main
struct LightTalkApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                BlinkDecoderView()
                    .tabItem { Label("Decode", systemImage: "lightbulb.fill") }
                BeaconTransmitView()
                    .tabItem { Label("Beacon", systemImage: "flashlight.on.fill") }
                BeaconsView()
                    .tabItem { Label("Codes", systemImage: "antenna.radiowaves.left.and.right") }
                HistoryView()
                    .tabItem { Label("History", systemImage: "clock.fill") }
                LearnView()
                    .tabItem { Label("Learn", systemImage: "graduationcap.fill") }
                GuideView()
                    .tabItem { Label("Guide", systemImage: "book.fill") }
            }
        }
    }
}

/// The beacon library: what each camp / device code means, and its airtime.
/// Plus the user's own custom codes — a camp's private language.
struct BeaconsView: View {
    @ObservedObject private var customStore = CustomCodeStore.shared
    @State private var showingAddCode = false
    @State private var newCode = ""
    @State private var newMeaning = ""
    // ✨ AI: describe the code you want, get a suggestion.
    @State private var aiDescription = ""
    @State private var isSuggesting = false
    @State private var suggestError: String?

    var body: some View {
        NavigationStack {
            List {
                if !customStore.codes.isEmpty {
                    Section("My codes") {
                        ForEach(customStore.codes) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.code)
                                    .font(.system(.headline, design: .monospaced))
                                Text(entry.meaning)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("Airtime: \(String(format: "%.0f", BlinkProtocol.airtime(for: entry.code))) s")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { customStore.delete(at: $0) }
                    }
                }
                Section("Camp coordination") {
                    ForEach(BeaconPresets.camp) { preset in
                        presetRow(preset)
                    }
                }
                Section("Device diagnostics") {
                    ForEach(BeaconPresets.device) { preset in
                        presetRow(preset)
                    }
                }
                Section {
                    Text("Program any of these codes into the Arduino transmitter (Transmitter.ino), point the phone at the LED, and the message arrives as light. No network, no pairing, no radio. Add your own codes above — the phone learns your camp's language.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Beacon codes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        newCode = ""
                        newMeaning = ""
                        aiDescription = ""
                        suggestError = nil
                        showingAddCode = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddCode) {
                NavigationStack {
                    Form {
                        // ✨ AI: describe what you need, get a code + meaning.
                        Section("✨ Describe it") {
                            TextField("e.g. second water truck at 3pm", text: $aiDescription)
                            // Mic disabled (iOS 26 speech stack hangs) — type instead.
                            Button {
                                suggestError = nil
                                isSuggesting = true
                                var didComplete = false
                                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                                    if !didComplete {
                                        didComplete = true
                                        isSuggesting = false
                                        suggestError = "AI timed out — type the code manually."
                                    }
                                }
                                MessageIntelligence.suggestCodePair(
                                    aiDescription,
                                    customCodes: customStore.codes
                                ) { pair in
                                    guard !didComplete else { return }
                                    didComplete = true
                                    isSuggesting = false
                                    if let pair {
                                        // Validate BOTH halves: code AND meaning must relate
                                        // to the description, else the model hallucinated them.
                                        let knownPrefixes = ["WTR", "MED", "FOOD", "CRFW", "SHL", "ALCLR", "T23", "FNFLT", "BATLO", "PMP"]
                                        let descWords = Set(aiDescription.uppercased().components(separatedBy: .whitespacesAndNewlines).filter { $0.count > 2 })
                                        func wordSet(_ s: String) -> Set<String> {
                                            Set(s.uppercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
                                        }
                                        func wordsRelate(_ a: Set<String>, _ b: Set<String>) -> Bool {
                                            for x in a { for y in b {
                                                if x == y { return true }
                                                if x.count >= 4 && y.hasPrefix(x) { return true }
                                                if y.count >= 4 && x.hasPrefix(y) { return true }
                                            } }
                                            return false
                                        }
                                        let codeRelates = knownPrefixes.contains(where: { pair.code.uppercased().hasPrefix($0) })
                                            || wordsRelate(descWords, wordSet(pair.code))
                                        let meaningRelates = wordsRelate(descWords, wordSet(pair.meaning))
                                        if codeRelates && meaningRelates {
                                            newCode = pair.code
                                            newMeaning = pair.meaning
                                        } else if codeRelates {
                                            // Code is fine, meaning was invented — use your own words.
                                            newCode = pair.code
                                            newMeaning = aiDescription
                                        } else {
                                            // Both invented — fall back to a plain uppercase code.
                                            let validChars = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?")
                                            newCode = String(aiDescription.uppercased().filter { validChars.contains($0) })
                                                .trimmingCharacters(in: .whitespaces)
                                            newMeaning = aiDescription
                                        }
                                    } else {
                                        suggestError = "AI couldn't suggest one — try simpler words, or type the code manually."
                                    }
                                }
                            } label: {
                                HStack {
                                    if isSuggesting { ProgressView().scaleEffect(0.8) }
                                    Text(isSuggesting ? "Thinking…" : "✨ Suggest code + meaning")
                                }
                            }
                            .disabled(isSuggesting || aiDescription.trimmingCharacters(in: .whitespaces).isEmpty)
                            if let err = suggestError {
                                Text(err).font(.caption2).foregroundColor(.orange)
                            }
                        }
                        Section("Code") {
                            TextField("e.g. WTR2 1500", text: $newCode)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                        }
                        Section("Meaning") {
                            TextField("e.g. Second water truck at 3 PM", text: $newMeaning)
                        }
                        Section {
                            Text("Codes use capital letters, digits and : - . / ? — the phone expands them to this meaning automatically, in the reader's language.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Section {
                            Text("Tip: end a code with * to make the tail end variable. Code \"WTR *\" with meaning \"Water truck at *\" turns a decoded \"WTR 1500\" into \"Water truck at 1500\" — define it once, and the time flows through on its own.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .navigationTitle("New code")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingAddCode = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Add") {
                                customStore.add(code: newCode, meaning: newMeaning)
                                showingAddCode = false
                            }
                            .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty ||
                                      newMeaning.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: BeaconPreset) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preset.code)
                .font(.system(.headline, design: .monospaced))
            Text(preset.detail)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("Airtime: \(String(format: "%.0f", BlinkProtocol.airtime(for: preset.code))) s")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// In-app explainer: how it works + the honest answers to hard questions.
struct GuideView: View {
    @State private var aiChecking = false
    @State private var aiStatus: String? = nil

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    group(title: "How it works") {
                        Text("1. The beacon blinks text as light, 5 bits per second.\n2. Point the phone at it — auto-aim finds the strongest blink by itself. Tap to aim at one specific beacon (others are ignored); 🎯 Re-aim returns to auto-aim.\n3. The app locks the camera exposure, subtracts the background light (differential measurement — that's the daylight trick), and calibrates to the room's light using the preamble.\n4. Bits become letters, live, with parity checking on every character. Tap 🔊 to hear the message spoken.")
                    }
                    group(title: "The other tabs") {
                        Text("SCANNER: point at any blinking light — no protocol needed — and read its flicker frequency. 2.5 Hz steady blink? Might be a beacon. 60/120 Hz? Mains flicker from an ordinary bulb. It also lists every beacon in view (census); tap Decode →, then read it in the Decode tab.\nBEACON: this phone becomes the transmitter — presets, your own typed message, dictate-by-voice, or 🆘 SOS which flashes your GPS coordinates as light.\nCODES: the beacon library, plus your own custom codes — a camp's private language, learned by the phone.\nHISTORY: every message ever decoded, with AI summaries.")
                    }
                    group(title: "Why not a QR code?") {
                        Text("QR codes win when you have a screen and a fixed message. This is for the opposite case: a ten-cent LED on a device with no screen and no radio. A QR is a photograph of data; this is a live broadcast — the beacon streams changing messages and sips power doing it.")
                    }
                    group(title: "Does it work in daylight?") {
                        Text("Yes — indoors and in shade. The app measures the room's actual bright/dim levels during the preamble and sets its threshold on the spot, and it locks the camera exposure so nothing else in the frame can fake a blink. Direct sunlight on the LED will swamp any camera optical link; that's physics, and the commercial systems solve it with brighter beacons and optical filters.")
                    }
                    group(title: "Is this new?") {
                        Text("The physics isn't — stores already guide shoppers' phones with ceiling LEDs, and the physics is standardized (IEEE 802.15.7). What's new here is the application: a pocket decoder anyone can point at any blinking beacon, including camp-coordination beacons where the cell network is gone.")
                    }
                    group(title: "Tips for a fast lock") {
                        Text("• Point the phone at the beacon and press Start during the 2-second dark pause between message loops — the app then catches the very next preamble.\n• 2–4 ft away, straight on, phone propped still (don't hand-hold).\n• If the room has other blinking lights, tap your beacon once to aim at it; 🎯 Re-aim returns to auto-aim.")
                    }
                    group(title: "What is Simulate mode?") {
                        Text("A practice mode: it pretends to receive \"WTR 1400\" through the real decode path, with no beacon needed — no laptop, no Arduino, no second phone. Use it to learn the app, rehearse the demo narration, or test on the Simulator (which has no camera). It is always labeled SIMULATE on screen; never present it as a live decode.")
                    }
                    group(title: "What if several beacons blink at once?") {
                        Text("You tap the one you want — the phone only watches that small spot, like pointing a remote. A camp would have many beacons (water here, medical there); you read the one you're standing at. If two overlap in the same spot, the parity check flags the garbled characters instead of showing wrong text — it fails visibly, never silently.")
                    }
                    group(title: "What about security?") {
                        Text("Honest answer: anyone with line of sight and a camera can read the blinks. This is not encryption — it's a no-radio, no-network broadcast layer. Don't send secrets over it.")
                    }
                    group(title: "Where AI fits — and where it doesn't") {
                        Text("AI never reads the light. Reading blinks is deterministic signal processing: fast, explainable, reliable. AI only touches meaning — repairing a garbled character, translating a camp message into the reader's language, expanding a compact code. The badge on the decode screen always tells you which engine produced the text.")
                    }
                    group(title: "On-device AI status") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("The ✨ buttons, AI repair, and AI translation need Apple's on-device model (iPhone 15 Pro or later, iOS 26). Tap to check whether it's actually live on this phone.")
                            Button(aiChecking ? "Checking…" : "Check on-device AI") {
                                aiChecking = true
                                aiStatus = nil
                                MessageIntelligence.checkModelHealth { health in
                                    aiChecking = false
                                    switch health {
                                    case .ready:
                                        aiStatus = "✅ On-device AI is ready. ✨ buttons, AI repair, and AI translation are live."
                                    case .notReady:
                                        aiStatus = "⏳ The model didn't answer. On a supported iPhone: Settings → Apple Intelligence & Siri → turn it on, connect to Wi-Fi, and wait for the model download. The app works fully without it — the badge shows “Direct decode”."
                                    case .unavailable:
                                        aiStatus = "ℹ️ This iPhone doesn't support Apple Intelligence (needs iPhone 15 Pro or later on iOS 26). Everything except the AI-only features works — the badge shows “Direct decode”."
                                    }
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(aiChecking)
                            if let status = aiStatus {
                                Text(status).font(.callout)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("How it works")
        }
    }

    private func group(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content().font(.body).foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}
