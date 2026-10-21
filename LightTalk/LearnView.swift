import SwiftUI
import Combine

/// Learn tab: the educational heart of LightTalk.
/// 1. "Watch the bits become words" — animated pipeline visualizer.
/// 2. "Decode by eye" — slow-blink challenge: read the bits yourself.
struct LearnView: View {
    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink {
                        PipelineVisualizerView()
                    } label: {
                        LearnRow(
                            icon: "waveform.path.ecg",
                            title: "Watch the bits become words",
                            detail: "A 30-second animation: light → waveform → bits → letters → meaning."
                        )
                    }
                    NavigationLink {
                        DecodeByEyeView()
                    } label: {
                        LearnRow(
                            icon: "eye.fill",
                            title: "Decode by eye challenge",
                            detail: "The phone blinks slowly. Read the bits yourself — then check."
                        )
                    }
                } header: {
                    Text("Learn the tech")
                }

                Section {
                    Text("LightTalk speaks in light: 7 bits per character (6 data + 1 parity check), 400 milliseconds per bit. The phone's camera measures brightness 30 times a second and turns blinks into text — no radio, no pairing, no network. The activities above let you see, touch, and try every step.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("The one-paragraph version")
                }
            }
            .navigationTitle("Learn")
        }
    }
}

private struct LearnRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.yellow)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Pipeline visualizer

/// Animated: blinking dot → waveform → bits → characters → sentence.
struct PipelineVisualizerView: View {
    // Demo word: "HI" — short enough to watch fully.
    private let demoBits: [Int] = {
        var b: [Int] = []
        for ch in "HI" {
            b += BlinkProtocol.encode(ch) ?? []
        }
        return b
    }()

    @State private var step = 0
    @State private var timer: AnyCancellable?

    private var totalSteps: Int { demoBits.count + 4 }

    var body: some View {
        VStack(spacing: 24) {
            // Stage 1: the blinking light.
            VStack(spacing: 8) {
                Text("1 · LIGHT").font(.caption).bold().foregroundColor(.secondary)
                Circle()
                    .fill(currentBit == 1 ? Color.yellow : Color.gray.opacity(0.25))
                    .frame(width: 90, height: 90)
                    .shadow(color: currentBit == 1 ? .yellow : .clear, radius: 24)
                    .animation(.easeInOut(duration: 0.25), value: step)
            }

            // Stage 2: waveform of bits so far.
            VStack(spacing: 8) {
                Text("2 · WAVEFORM").font(.caption).bold().foregroundColor(.secondary)
                WaveformView(bits: Array(demoBits[0..<shownBits]))
                    .frame(height: 60)
            }

            // Stage 3: bits.
            VStack(spacing: 8) {
                Text("3 · BITS").font(.caption).bold().foregroundColor(.secondary)
                Text(bitString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.green)
            }

            // Stage 4 + 5: characters → meaning.
            VStack(spacing: 8) {
                Text("4 · LETTERS → 5 · MEANING").font(.caption).bold().foregroundColor(.secondary)
                Text(decodedSoFar)
                    .font(.title).bold()
                if step >= demoBits.count {
                    Text("💡 \"HI\" needs no expansion — but WTR 1400 becomes \"Water truck arrives at 2:00 PM.\"")
                        .font(.caption)
                        .foregroundColor(.yellow)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
            }

            Spacer()

            Button(step == 0 ? "▶ Play" : "↺ Replay") {
                start()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .navigationTitle("Bits become words")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { timer?.cancel() }
    }

    private var shownBits: Int { min(step, demoBits.count) }
    private var currentBit: Int { step < demoBits.count ? demoBits[step] : 0 }
    private var bitString: String {
        demoBits[0..<shownBits].map(String.init).joined(separator: " ")
    }
    private var decodedSoFar: String {
        let chars = Array(demoBits[0..<shownBits]).chunked(into: 7).compactMap { group -> Character? in
            guard group.count == 7 else { return nil }
            return BlinkProtocol.decode(Array(group))?.0
        }
        return String(chars)
    }

    private func start() {
        timer?.cancel()
        step = 0
        timer = Timer.publish(every: 0.5, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                if step < totalSteps {
                    step += 1
                }
            }
    }
}

/// Simple bar waveform of bit history.
private struct WaveformView: View {
    let bits: [Int]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<max(bits.count, 1), id: \.self) { i in
                    let v = i < bits.count ? bits[i] : 0
                    RoundedRectangle(cornerRadius: 2)
                        .fill(v == 1 ? Color.yellow : Color.gray.opacity(0.3))
                        .frame(width: 8, height: v == 1 ? geo.size.height : geo.size.height * 0.25)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Decode by eye

/// The phone blinks a message slowly on-screen; the student taps 1/0 for
/// each blink, then checks against the real decode.
struct DecodeByEyeView: View {
    private let secret = "SOS"
    private var secretBits: [Int] {
        var b: [Int] = []
        for ch in secret { b += BlinkProtocol.encode(ch) ?? [] }
        return b
    }

    @State private var blinking = false
    @State private var blinkIndex = 0
    @State private var blinkOn = false
    @State private var timer: AnyCancellable?
    @State private var guesses: [Int] = []
    @State private var revealed = false

    var body: some View {
        VStack(spacing: 20) {
            Text("Watch the light. For each blink, tap what you saw — then check yourself.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            // The slow beacon.
            Circle()
                .fill(blinkOn ? Color.yellow : Color.gray.opacity(0.2))
                .frame(width: 120, height: 120)
                .shadow(color: blinkOn ? .yellow : .clear, radius: 30)
                .animation(.easeInOut(duration: 0.2), value: blinkOn)
                .onTapGesture {
                    // Tapping the beacon itself does nothing — tap 1/0 below.
                }

            Text("Blink \(min(blinkIndex + 1, secretBits.count)) of \(secretBits.count)")
                .font(.caption).foregroundColor(.secondary)

            // Guess buttons.
            HStack(spacing: 24) {
                Button("0 — dark") {
                    guesses.append(0)
                    advance()
                }
                .buttonStyle(.bordered)
                .disabled(!blinking || revealed)

                Button("1 — bright") {
                    guesses.append(1)
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!blinking || revealed)
            }

            // Progress: your guesses vs actual.
            if !guesses.isEmpty {
                VStack(spacing: 6) {
                    Text("Your read:").font(.caption).bold()
                    Text(guesses.map(String.init).joined(separator: " "))
                        .font(.system(.body, design: .monospaced))
                }
            }

            if revealed {
                let score = zip(guesses, secretBits).filter { $0 == $1 }.count
                VStack(spacing: 6) {
                    Text(score == secretBits.count ? "🎉 Perfect — you ARE the decoder!" : "You got \(score)/\(secretBits.count) bits right.")
                        .font(.headline)
                    Text("Answer: \(secretBits.map(String.init).joined(separator: " ")) → \"\(secret)\"")
                        .font(.caption).foregroundColor(.secondary)
                    Text("The phone does this 30×/second without getting tired. Now you know why parity bits exist.")
                        .font(.caption).foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
            }

            Spacer()

            HStack(spacing: 16) {
                Button(blinking ? "Stop" : "Start blinking") {
                    blinking ? stop() : start()
                }
                .buttonStyle(.borderedProminent)

                if blinking && !revealed && guesses.count >= secretBits.count {
                    Button("Check me") { revealed = true }
                        .buttonStyle(.bordered)
                }
                if revealed {
                    Button("Try again") { reset() }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .navigationTitle("Decode by eye")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { timer?.cancel() }
    }

    private func start() {
        reset()
        blinking = true
        // 1.2s per bit: on for 0.8s, off gap 0.4s.
        timer = Timer.publish(every: 1.2, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                guard blinkIndex < secretBits.count else {
                    blinkOn = false
                    return
                }
                blinkOn = secretBits[blinkIndex] == 1
                // Turn off mid-cycle so blinks are distinct.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    blinkOn = false
                }
            }
    }

    private func advance() {
        blinkIndex += 1
        if blinkIndex >= secretBits.count {
            // Let the last blink finish, then auto-stop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if guesses.count >= secretBits.count { revealed = true }
            }
        }
    }

    private func stop() {
        timer?.cancel()
        blinking = false
        blinkOn = false
    }

    private func reset() {
        stop()
        blinkIndex = 0
        guesses = []
        revealed = false
    }
}

// MARK: - Helpers

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
