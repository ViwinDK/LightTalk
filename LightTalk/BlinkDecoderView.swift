import SwiftUI
import AVFoundation
import Combine

/// The main screen: point the phone at a blinking beacon and watch the
/// message arrive letter by letter. Auto-aim finds the blink by itself;
/// tapping aims manually (useful when several beacons blink at once).
struct BlinkDecoderView: View {
    @ObservedObject private var decoder = BlinkDecoder.shared
    @StateObject private var speaker = Speaker()
    @State private var showGuide = false
    @State private var inspectChar: Character?
    @State private var inspectUncertain = false
    @State private var showingInspector = false
    @State private var flashPoint: CGPoint? = nil
    @State private var flashVisible = false
    @State private var shareText: String = ""
    @State private var showingShare = false
    @AppStorage("lighttalk.targetLanguage") private var targetLanguage = "system"

    private struct LanguageOption {
        let code: String
        let label: String
    }
    private var languageOptions: [LanguageOption] {
        [
            LanguageOption(code: "system", label: "System"),
            LanguageOption(code: "en", label: "EN"),
            LanguageOption(code: "es", label: "ES"),
            LanguageOption(code: "fr", label: "FR"),
            LanguageOption(code: "hi", label: "HI"),
            LanguageOption(code: "ta", label: "TA"),
            LanguageOption(code: "ar", label: "AR"),
        ]
    }

    var body: some View {
        NavigationStack {
            ZStack {
                CameraPreview(decoder: decoder)
                    .ignoresSafeArea()

                // Tap confirmation: a brief ripple where the finger landed, then
                // gone. No persistent box — the status line shows the aim mode.
                if flashVisible, let fp = flashPoint {
                    GeometryReader { geo in
                        Circle()
                            .stroke(Color.yellow, lineWidth: 3)
                            .frame(width: 70, height: 70)
                            .position(x: fp.x * geo.size.width, y: fp.y * geo.size.height)
                    }
                    .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    controlPanel
                }
            }
            .navigationTitle("LightTalk")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("How it works") { showGuide = true }
                }
            }
            .sheet(isPresented: $showGuide) { GuideView() }
            .sheet(isPresented: $showingShare) {
                ShareSheet(text: shareText)
            }
            .sheet(isPresented: $showingInspector) {
                if let ch = inspectChar {
                    BitInspectorView(character: ch, wasUncertain: inspectUncertain)
                }
            }
            .onAppear {
                decoder.cancelPendingCameraStop()
                decoder.startCamera()
            }
            .onDisappear {
                decoder.stopDecoding()
                // Warm handoff: if Scanner appears next, it cancels this stop.
                decoder.scheduleCameraStop()
            }
            .onChange(of: decoder.aimFlash) {
                // Brief ripple confirming the tap registered, then fade.
                flashPoint = decoder.roiCenter
                flashVisible = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    flashVisible = false
                }
            }
            // (AI enhancement now happens inside the decoder at message
            // completion — the entry carries its own 💡 line. No view race.)
        }
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            // Status line
            statusLine
            
            // Live decoded text — the money shot.
            if !decoder.liveText.isEmpty || isActive {
                Text(decoder.liveText.isEmpty ? "…" : decoder.liveText)
                    .font(.system(.title2, design: .monospaced))
                    .foregroundColor(.green)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.72))
                    .cornerRadius(12)
            }
            
            // Signal meter
            HStack {
                Text("SIGNAL").font(.caption2).foregroundColor(.white.opacity(0.7))
                ProgressView(value: decoder.signalMeter)
                    .progressViewStyle(.linear)
                    .tint(decoder.signalMeter > 0.6 ? .green : .yellow)
                engineBadge
            }
            // AI language chips: what language the 💡 line speaks.
            // (Chips instead of a menu picker — always tappable, always visible.)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("AI language").font(.caption2).foregroundColor(.white.opacity(0.7))
                    ForEach(languageOptions, id: \.code) { opt in
                        Button(opt.label) {
                            targetLanguage = opt.code
                        }
                        .font(.caption2).bold()
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(targetLanguage == opt.code ? Color.blue : Color.white.opacity(0.15))
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                }
            }
            .onChange(of: targetLanguage) {
                // Re-run the enhancement on existing messages in the new language.
                decoder.retranslateAll()
            }
            // Tiny field-diagnosis readout: what the decoder is hearing.
            if !decoder.debugInfo.isEmpty {
                Text(decoder.debugInfo)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.white.opacity(0.55))
            }
            
            // Completed messages: most recent expanded, older ones compact.
            // (Saves screen space — the camera preview is the star.)
            if !decoder.messages.isEmpty {
                VStack(alignment: .leading, spacing: 4) {                    ForEach(Array(decoder.messages.prefix(3).enumerated()), id: \.element.id) { idx, entry in
                    if idx == 0 {
                        // Newest: full display with tappable characters.
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                // Tappable characters — tap any letter to inspect its bits.
                                WrappingCharRow(
                                    text: entry.raw,
                                    onTap: { ch in
                                        inspectChar = ch
                                        inspectUncertain = entry.uncertainCount > 0
                                        showingInspector = true
                                    }
                                )
                                if let em = entry.enhanced, em != entry.raw {
                                    Text("💡 " + em)
                                        .font(.callout)
                                        .foregroundColor(.yellow)
                                        .lineLimit(4)
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let src = entry.meaningSource {
                                        Text(src.label)
                                            .font(.caption2)
                                            .foregroundColor(.white.opacity(0.45))
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                speaker.speak(entry.displayText)
                            } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(.blue)
                            }
                            Button {
                                shareText = entry.displayText
                                showingShare = true
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .foregroundColor(.blue)
                            }
                        }
                        if entry.uncertainCount > 0 {
                            Text("⚠️ \(entry.uncertainCount) character\(entry.uncertainCount == 1 ? "" : "s") failed parity — AI repair attempted.")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    } else {
                        // Older: one compact line, tap to hear it.
                        // Keeps the 💡 so the meaning stays visible.
                        Button {
                            speaker.speak(entry.displayText)
                        } label: {
                            HStack {
                                Image(systemName: "checkmark.circle")
                                    .foregroundColor(.green.opacity(0.7))
                                    .font(.caption)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(entry.raw)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.8))
                                        .lineLimit(1)
                                    if let em = entry.enhanced, em != entry.raw {
                                        Text("💡 " + em)
                                            .font(.caption2)
                                            .foregroundColor(.yellow.opacity(0.9))
                                            .lineLimit(2)
                                        if let src = entry.meaningSource {
                                            Text(src.label)
                                                .font(.caption2)
                                                .foregroundColor(.white.opacity(0.4))
                                        }
                                    }
                                }
                                Spacer()
                            }
                        }
                    }
                }
                }
                .padding(8)
                .background(Color.black.opacity(0.6))
                .cornerRadius(10)
            }
            
            HStack(spacing: 12) {
                // Start is gated on auto-aim lock (or a manual tap): pressing
                // Start before the app has found the blink just wastes a loop.
                let aimReady = decoder.autoScore > 0.1 || decoder.hasManualTap
                Button(isActive ? "Stop" : (aimReady ? "Start decoding" : "Finding beacon…")) {
                    if isActive { decoder.stopDecoding() }
                    else { decoder.startDecoding() }
                }
                .buttonStyle(.borderedProminent)
                .tint(isActive ? .red : .blue)
                .disabled(!isActive && !aimReady)
                
                // Manual aim is active: offer one-tap return to auto-aim.
                if decoder.hasManualTap && !isActive {
                    Button("🎯 Re-aim") { decoder.hasManualTap = false }
                        .font(.caption).bold()
                        .foregroundColor(.yellow)
                }
                
                Toggle("Simulate (no beacon needed)", isOn: $decoder.simulate)
                    .toggleStyle(.switch)
                    .foregroundColor(.white)
                    .font(.caption)
                    .fixedSize()
                    .onChange(of: decoder.simulate) {
                        if isActive { decoder.stopDecoding() }
                    }
            }
            .padding()
            .background(Color.black.opacity(0.72))
            .cornerRadius(16)
        }
    }

    private var isActive: Bool {
        switch decoder.phase {
        case .idle, .done, .error: return false
        default: return true
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let (text, color): (String, Color) = {
            switch decoder.phase {
            case .idle:
                if decoder.hasManualTap {
                    return ("Aiming at your tap — Start decoding. (🎯 Re-aim for auto)", .white)
                } else if decoder.autoScore > 0.1 {
                    return ("Auto-aim found the blink — tap Start decoding.", .green)
                } else {
                    return ("Point the camera at the flashing square…", .white)
                }
            case .listening: return ("Listening for the beacon preamble…", .yellow)
            case .calibrating(let p): return ("Calibrating to this light… \(Int(p * 100))%", .yellow)
            case .decoding:
                let n = decoder.charsReceived
                return ("Decoding… \(n) character\(n == 1 ? "" : "s") so far", .green)
            case .done(let m): return ("Received: \(m)", .green)
            case .error(let e): return (e, .red)
            }
        }()
        HStack {
            if decoder.simulate {
                Text("SIMULATE").font(.caption2).bold()
                    .padding(4).background(Color.orange).cornerRadius(6)
            }
            Text(text).font(.subheadline).foregroundColor(color)
            Spacer()
        }
        .padding(8)
        .background(Color.black.opacity(0.6))
        .cornerRadius(10)
    }

    private var engineBadge: some View {
        Text(MessageIntelligence.engineLabel)
            .font(.caption2).bold()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.blue.opacity(0.85))
            .foregroundColor(.white)
            .cornerRadius(8)
    }
}

// MARK: - Share sheet

struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Camera preview

/// Offline speech for reading decoded messages aloud (accessibility + demo).
final class Speaker: ObservableObject {
    // No @Published state — the publisher is explicit so conformance holds.
    let objectWillChange = ObservableObjectPublisher()
    private let synth = AVSpeechSynthesizer()
    func speak(_ text: String) {
        synth.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        synth.speak(utterance)
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject var decoder: BlinkDecoder

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        decoder.bindPreviewLayer(view.previewLayer)
        // Taps set the region of interest.
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.decoder = decoder
        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var decoder: BlinkDecoder?
        weak var previewView: PreviewView?

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let point = g.location(in: view)
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            // Manual aim override: normalized to the portrait preview; the
            // decoder's pixel buffer is portrait too, so this lands on the
            // right pixels. Auto-aim yields to the tap until Re-aim.
            decoder?.roiCenter = CGPoint(x: point.x / size.width,
                                         y: point.y / size.height)
            decoder?.hasManualTap = true
            decoder?.aimFlash += 1
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}

/// A row of individually tappable characters (wraps to multiple lines).
/// Each character opens the Bit Inspector.
struct WrappingCharRow: View {
    let text: String
    let onTap: (Character) -> Void

    var body: some View {
        // Simple flow layout using flexible wrapping via LazyVGrid is overkill;
        // a horizontal scroll of characters is clear and always works.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(Array(text.enumerated()), id: \.offset) { _, ch in
                    Button(String(ch)) {
                        onTap(ch)
                    }
                    .font(.body.monospaced())
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(4)
                }
            }
        }
    }
}
