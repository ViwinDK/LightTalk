import AVFoundation
import SwiftUI
import Combine
import Speech
import CoreLocation

/// One-shot location fetch for the SOS beacon.
final class SOSLocator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    @Published var statusText = ""
    var onLocation: ((String) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    func request() {
        statusText = "Getting GPS…"
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            statusText = "No GPS fix."
            return
        }
        let lat = String(format: "%.4f", loc.coordinate.latitude)
        let lon = String(format: "%.4f", loc.coordinate.longitude)
        statusText = ""
        onLocation?("SOS \(lat) \(lon)")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        statusText = "GPS unavailable."
    }
}

/// Speech-to-text for "say it, flash it": dictate the beacon message.
final class VoiceTyper: NSObject, ObservableObject {
    @Published var isListening = false
    @Published var statusText = ""
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    var onText: ((String) -> Void)?

    func toggle() {
        isListening ? stop() : start()
    }

    private func start() {
        SFSpeechRecognizer.requestAuthorization { [weak self] auth in
            DispatchQueue.main.async {
                guard auth == .authorized else {
                    self?.statusText = "Speech recognition not allowed."
                    return
                }
                self?.begin()
            }
        }
    }

    private func begin() {
        // Guard against re-entry: if we're already listening, stop first.
        if isListening { stop() }
        recognizer = SFSpeechRecognizer(locale: Locale.current)
        guard let recognizer, recognizer.isAvailable else {
            statusText = "Speech recognizer unavailable."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusText = "Microphone unavailable."
            return
        }
        request = SFSpeechAudioBufferRecognitionRequest()
        guard let request else { return }
        request.shouldReportPartialResults = true
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        do { try audioEngine.start() } catch {
            statusText = "Microphone unavailable."
            return
        }
        isListening = true
        statusText = "Listening… speak the message."
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                DispatchQueue.main.async { self.onText?(text.uppercased()) }
            }
            if result?.isFinal == true || error != nil {
                DispatchQueue.main.async { self.stop() }
            }
        }
    }

    private func stop() {
        audioEngine.stop()
        // removeTap can throw if the tap was never installed — guard it.
        if audioEngine.inputNode.numberOfInputs > 0 {
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        // Release the audio hardware so other tabs/apps can use it.
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Best effort — the session may already be inactive.
        }
        isListening = false
        statusText = ""
    }

    deinit {
        // Safety net: never leave the microphone claimed if the view goes away.
        audioEngine.stop()
        task?.cancel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// Turns THIS phone into the beacon: the flashlight blinks the LightTalk
/// protocol, and a second phone running the Decode tab reads it.
///
/// This is not a simulation — it's real optical transmission, just with a
/// phone torch instead of an Arduino LED. It means the full demo works with
/// two phones and no extra hardware: no network, no pairing, no Bluetooth,
/// just light between two devices.
final class TorchTransmitter: ObservableObject {
    @Published var isTransmitting = false
    @Published var progress = 0.0       // 0..1 through the current frame
    @Published var currentBit = 0       // 1 = light on, 0 = off
    @Published var loopsCompleted = 0

    var message = "WTR 1400"

    private var timer: Timer?
    private var bits: [Int] = []
    private var index = 0

    var hasTorch: Bool {
        AVCaptureDevice.default(for: .video)?.hasTorch ?? false
    }

    func start() {
        guard hasTorch, !isTransmitting else { return }
        bits = BlinkProtocol.bitStream(for: message)
        index = 0
        loopsCompleted = 0
        isTransmitting = true
        setTorch(false)
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isTransmitting = false
        progress = 0
        setTorch(false)
    }

    private func scheduleTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: BlinkProtocol.bitDuration,
                                     repeats: true) { [weak self] _ in self?.step() }
    }

    private func step() {
        guard isTransmitting else { return }
        if index >= bits.count {
            // End of frame: dark gap, then loop again (like the Arduino).
            timer?.invalidate()
            setTorch(false)
            currentBit = 0
            loopsCompleted += 1
            progress = 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + BlinkProtocol.interFrameGap) { [weak self] in
                guard let self, self.isTransmitting else { return }
                self.index = 0
                self.progress = 0
                self.scheduleTimer()
            }
            return
        }
        let b = bits[index]
        index += 1
        currentBit = b
        setTorch(b == 1)
        progress = Double(index) / Double(bits.count)
    }

    private func setTorch(_ on: Bool) {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return }
        do {
            try d.lockForConfiguration()
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
        } catch {
            // If the torch can't be driven, stop rather than blink wrongly.
            DispatchQueue.main.async { self.stop() }
        }
    }
}

struct BeaconTransmitView: View {
    @StateObject private var tx = TorchTransmitter()
    @StateObject private var sos = SOSLocator()
    @ObservedObject private var customStore = CustomCodeStore.shared
    @State private var selectedCustomCode = ""
    @State private var selectedCode = BeaconPresets.camp[0].code
    @State private var customMessage = ""
    @State private var useCustom = false
    // ✨ AI: natural language → beacon code.
    @State private var isConverting = false
    @State private var convertError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(spacing: 16) {
                Text("This phone becomes the beacon.\nIts flashlight blinks the message;\na second phone decodes it.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundColor(.secondary)

                // Preset picker or custom message.
                if !useCustom {
                    Picker("Message", selection: $selectedCode) {
                        ForEach(BeaconPresets.all) { preset in
                            Text("\(preset.code)").tag(preset.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(tx.isTransmitting)

                    if let preset = BeaconPresets.all.first(where: { $0.code == selectedCode }) {
                        Text(preset.detail)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                } else {
                    HStack {
                        TextField("Custom message", text: $customMessage)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                            .disabled(tx.isTransmitting)
                        // Mic disabled (iOS 26 speech stack hangs) — type instead.
                    }
                    .padding(.horizontal)
                    // ✨ AI: describe what you want to say, get a beacon code.
                    Button {
                        convertError = nil
                        isConverting = true
                        let input = customMessage
                        // Deterministic fallback: uppercase + sanitize. Always works.
                        let valid = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 :-./?")
                        let fallback = String(input.uppercased().filter { valid.contains($0) })
                            .trimmingCharacters(in: .whitespaces)
                        // Validate AI output: must contain a word from input OR match a known code.
                        let knownPrefixes = ["WTR", "MED", "FOOD", "CRFW", "SHL", "ALCLR", "T23", "FNFLT", "BATLO", "PMP"]
                        let inputWords = Set(input.uppercased().components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
                        func isValidAIOutput(_ code: String) -> Bool {
                            let upper = code.uppercased()
                            // Known code pattern?
                            if knownPrefixes.contains(where: { upper.hasPrefix($0) }) { return true }
                            // Contains a word from the input?
                            let codeWords = Set(upper.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty })
                            return !inputWords.isDisjoint(with: codeWords)
                        }
                        // Try AI with a 5-second timeout; fall back to deterministic.
                        var didComplete = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                            if !didComplete {
                                didComplete = true
                                isConverting = false
                                if !fallback.isEmpty {
                                    customMessage = fallback
                                } else {
                                    convertError = "Couldn't convert that — try simpler words."
                                }
                            }
                        }
                        MessageIntelligence.naturalLanguageToCode(
                            input,
                            customCodes: CustomCodeStore.shared.codes
                        ) { code in
                            guard !didComplete else { return }
                            didComplete = true
                            isConverting = false
                            if let code, !code.isEmpty, isValidAIOutput(code) {
                                customMessage = code
                            } else if !fallback.isEmpty {
                                // AI hallucinated — use deterministic instead.
                                customMessage = fallback
                            } else {
                                convertError = "AI couldn't convert that — try simpler words, or type the code directly."
                            }
                        }
                    } label: {
                        HStack {
                            if isConverting { ProgressView().scaleEffect(0.8) }
                            Text(isConverting ? "Converting…" : "✨ Describe it, get the code")
                        }
                        .font(.caption).bold()
                    }
                    .buttonStyle(.bordered)
                    .tint(.purple)
                    .disabled(tx.isTransmitting || isConverting || customMessage.isEmpty)
                    if let err = convertError {
                        Text(err).font(.caption2).foregroundColor(.orange)
                    }
                    Text("Say it, flash it: tap the mic and speak — or type plain English above and tap ✨ to get the beacon code.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Toggle("Custom message", isOn: $useCustom)
                    .font(.caption)
                    .padding(.horizontal, 40)
                    .disabled(tx.isTransmitting)

                // Your codes: custom codes from the Codes tab, in a dropdown.
                if !customStore.codes.isEmpty {
                    Picker("Your codes", selection: $selectedCustomCode) {
                        Text("Your codes…").tag("")
                        ForEach(customStore.codes) { entry in
                            Text("\(entry.code) — \(entry.meaning)").tag(entry.code)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(tx.isTransmitting)
                    .onChange(of: selectedCustomCode) { _, newValue in
                        guard !newValue.isEmpty else { return }
                        customMessage = newValue
                        useCustom = true
                        selectedCustomCode = ""
                    }
                    .padding(.horizontal)
                }

                // SOS: flash GPS coordinates as light. No network needed.
                Button("🆘 SOS — flash my location") {
                    sos.onLocation = { msg in
                        customMessage = msg
                        useCustom = true
                        tx.message = msg
                        tx.start()
                    }
                    sos.request()
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(tx.isTransmitting)
                if !sos.statusText.isEmpty {
                    Text(sos.statusText).font(.caption).foregroundColor(.secondary)
                }

                // Big status lamp mirroring the torch.
                Circle()
                    .fill(tx.currentBit == 1 ? Color.yellow : Color.gray.opacity(0.3))
                    .frame(width: 120, height: 120)
                    .overlay(Circle().stroke(Color.secondary, lineWidth: 2))
                    .shadow(color: tx.currentBit == 1 ? .yellow : .clear, radius: 30)

                ProgressView(value: tx.progress)
                    .padding(.horizontal, 40)

                Text(tx.isTransmitting
                     ? "Broadcasting… loop \(tx.loopsCompleted + 1)"
                     : "Idle")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button(tx.isTransmitting ? "Stop beacon" : "Start beacon") {
                    if tx.isTransmitting { tx.stop() }
                    else {
                        let msg = useCustom ? customMessage : selectedCode
                        tx.message = msg.isEmpty ? selectedCode : msg
                        tx.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(tx.isTransmitting ? .red : .blue)
                .disabled(!tx.hasTorch)

                if !tx.hasTorch {
                    Text("This device has no torch.").foregroundColor(.red)
                }

                Spacer()
                Text("Hold this phone's flashlight 1–3 feet from the decoding phone's camera, indoors. Don't stare into the light.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
            }
            .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Beacon")
            .navigationBarTitleDisplayMode(.inline)
            .onDisappear { tx.stop() }
        }
    }
}
