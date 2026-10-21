import AVFoundation
import Combine
import UIKit

/// Real-time optical receiver: watches a region of the camera frame, detects an
/// LED blinking the BlinkProtocol, and decodes it to text live.
///
/// How it stays robust in daylight:
///  1. The user taps the LED on screen to set a small region of interest (ROI).
///  2. On Start, camera exposure + white balance are LOCKED so the only thing
///     changing in the frame is the LED (auto-exposure hunting is the #1 source
///     of false transitions in bright rooms).
///  3. The preamble (alternating 1/0) is used to measure the actual bright and
///     dim levels in *this* lighting — the decision threshold adapts on the spot.
///  4. Each bit is decided by averaging ~12 frames, with hysteresis, so mains
///     flicker and sensor noise don't flip bits.
///
/// Nothing here is machine learning and that's deliberate: the decode path is
/// deterministic signal processing — fast, explainable, demo-safe. The optional
/// AI layer (MessageIntelligence) only ever touches the *meaning* of decoded
/// text (error repair, translation), never the reading of the light itself.
final class BlinkDecoder: NSObject, ObservableObject {
    /// App-wide shared decoder: Decode, Scanner, and History tabs all watch
    /// the same engine (one camera, one message log).
    static let shared = BlinkDecoder()

    enum Phase: Equatable {
        case idle
        case listening          // watching for the preamble
        case calibrating(Double) // 0..1 progress through the preamble
        case decoding
        case done(String)        // a complete, checksum-validated message
        case error(String)

        static func == (lhs: Phase, rhs: Phase) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.listening, .listening), (.decoding, .decoding): return true
            case (.calibrating(let a), .calibrating(let b)): return abs(a - b) < 0.001
            case (.done(let a), .done(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var phase: Phase = .idle
    @Published var liveText = ""          // characters decoded so far, letter by letter
    @Published var charsReceived = 0     // count, so the UI can show progress
    @Published var uncertainCount = 0    // chars that failed parity (shown, flagged)
    @Published var signalMeter = 0.0     // 0..1 current ROI brightness, for the UI
    @Published var messages: [ReceivedMessage] = [] // completed messages, newest first (persisted)
    @Published var simulate = false
    @Published var debugInfo = ""      // tiny field-diagnosis readout (bits heard)

    /// Normalized ROI center (0..1 in preview coordinates), set by tapping the LED.
    /// Manual tap point (normalized, portrait preview). Only used when the user
    /// has tapped; otherwise the auto-aim below finds the beacon by itself.
    var roiCenter = CGPoint(x: 0.5, y: 0.5)
    @Published var hasManualTap = false

    // MARK: - Auto-aim: find the blinking beacon without tapping.
    // The frame is divided into an 8x6 grid; the cell with the largest
    // brightness swing over ~1.5 s is the beacon. Fractional coordinates, so
    // this works regardless of buffer orientation. A manual tap overrides it.
    private let gridCols = 8, gridRows = 6
    private var cellMin = [Double](repeating: 1.0, count: 48)
    private var cellMax = [Double](repeating: 0.0, count: 48)
    private var scanFrames = 0
    private let scanWindow = 45
    private var scanFrozen = false   // frozen once decoding starts (don't move ROI mid-message)
    @Published var autoCell = 0
    @Published var autoScore = 0.0   // swing of the winning cell, 0..1
    @Published var aimFlash = 0      // increments on every manual tap (drives the tap ripple)

    // MARK: - Daylight robustness: differential measurement.
    // The decoder subtracts the frame's background brightness (median of the
    // auto-aim grid) from the beacon ROI. Ambient light is common-mode — it
    // lifts both equally — so the difference isolates the blink. This is what
    // lets the link survive bright, fluctuating daylight.
    private var frameBackground = 0.0

    // MARK: - Flicker scanner: measure ANY light's blink rate, no protocol needed.
    @Published var flickerHz: Double = 0      // dominant blink frequency of the auto-aim cell
    @Published var flickerConfidence: Double = 0 // 0..1 — how clean the rhythm is
    var scannerActive = false
    private var scanEdgeTimes: [TimeInterval] = []
    private var flickerSamples: [(TimeInterval, Double)] = []

    // MARK: - Beacon census: every blinking cell, not just the strongest.
    struct CensusEntry {
        let cell: Int
        let score: Double  // brightness swing, 0..1
    }
    @Published var census: [CensusEntry] = []

    /// Aim the manual ROI at an auto-aim grid cell (used by the Scanner census).
    func aimAtCell(_ cell: Int) {
        let c = cell % gridCols, r = cell / gridCols
        let center = CGPoint(x: (CGFloat(c) + 0.5) / CGFloat(gridCols),
                             y: (CGFloat(r) + 0.5) / CGFloat(gridRows))
        DispatchQueue.main.async {
            self.roiCenter = center
            self.hasManualTap = true
            self.aimFlash += 1
        }
    }

    /// Fractional rect of a grid cell (for drawing the census overlay).
    func rectForCell(_ cell: Int) -> CGRect {
        let c = cell % gridCols, r = cell / gridCols
        return CGRect(x: CGFloat(c) / CGFloat(gridCols),
                      y: CGFloat(r) / CGFloat(gridRows),
                      width: 1 / CGFloat(gridCols),
                      height: 1 / CGFloat(gridRows))
    }

    /// Fractional ROI rect the decoder actually samples.
    var effectiveROI: CGRect {
        if hasManualTap {
            let s: CGFloat = 0.10
            let x = min(max(roiCenter.x - s / 2, 0), 1 - s)
            let y = min(max(roiCenter.y - s / 2, 0), 1 - s)
            return CGRect(x: x, y: y, width: s, height: s)
        }
        let c = autoCell % gridCols, r = autoCell / gridCols
        return CGRect(x: CGFloat(c) / CGFloat(gridCols),
                      y: CGFloat(r) / CGFloat(gridRows),
                      width: 1 / CGFloat(gridCols),
                      height: 1 / CGFloat(gridRows))
    }

    private var session: AVCaptureSession?
    private var device: AVCaptureDevice?
    private let sampleQueue = DispatchQueue(label: "lighttalk.decoder")

    // Rolling luminance samples: (timestamp, level 0..1)
    private var samples: [(TimeInterval, Double)] = []
    private let maxSamples = 900 // 30 s at 30 fps

    // Decode state
    private var threshold = 0.5
    private var hysteresis = 0.05
    private var preambleEdgeTimes: [TimeInterval] = []
    private var decoding = false
    private var bitStartTime: TimeInterval = 0
    private var pendingBits: [Int] = []
    private var awaitingStart = true
    private var lastEdgeLevel = 0  // last decided bit, for edge detection
    private var lastEdgeTime: TimeInterval = 0
    private var listenDeadline: TimeInterval = 0

    // Stall recovery: bounds how long we hunt for the message start / next char
    // before dropping back to preamble hunt instead of waiting forever.
    private var decodingStartTime: TimeInterval = 0
    private var lastCharTime: TimeInterval = 0
    private var localCharCount = 0
    private var lastSeenCharCount = 0
    private var lastDebugUpdate: TimeInterval = 0
    private var uncertainIdx: Set<Int> = []  // char offsets that failed parity (for AI repair)

    // MARK: - History (persisted)

    private let historyKey = "lighttalk.history.v1"

    override init() {
        super.init()
        loadHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: historyKey),
              let decoded = try? JSONDecoder().decode([ReceivedMessage].self, from: data)
        else { return }
        messages = decoded
    }

    func saveHistory() {
        let trimmed = Array(messages.prefix(200))
        if let data = try? JSONEncoder().encode(trimmed) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
    }

    func clearHistory() {
        messages = []
        UserDefaults.standard.removeObject(forKey: historyKey)
    }

    /// Re-run AI enhancement on all stored messages (e.g. after the user
    /// changes the AI language). Each entry updates itself when done.
    func retranslateAll() {
        let language = UserDefaults.standard.string(forKey: "lighttalk.targetLanguage") ?? "system"
        MessageIntelligence.debugLog("retranslateAll lang='\(language)' messages=\(messages.count)")
        let customs = CustomCodeStore.shared.codes
        for entry in messages {
            let clean = Self.cleanCode(entry.raw)
            // Pass the ORIGINAL uncertain positions so the model can repair again.
            let dm = DecodedMessage(rawText: clean, uncertainIndices: Set(entry.uncertainIndices))
            let id = entry.id
            let oldEnhanced = entry.enhanced
            MessageIntelligence.enhance(dm, language: language, customCodes: customs) { [weak self] out, source in
                guard let self else { return }
                if let idx = self.messages.firstIndex(where: { $0.id == id }) {
                    let newEnhanced: String? = (out != clean) ? out : nil
                    // Never replace a good enhancement with a worse one:
                    // if the new result still has � but the old didn't, keep the old.
                    if let ne = newEnhanced, ne.contains("�"),
                       let oe = oldEnhanced, !oe.contains("�") {
                        MessageIntelligence.debugLog("keeping old enhancement (new has �)")
                    } else {
                        self.messages[idx].enhanced = newEnhanced
                        self.messages[idx].meaningSource = (newEnhanced != nil) ? source : nil
                    }
                    self.saveHistory()
                }
            }
        }
    }

    // MARK: - Simulate mode: drives the identical decode path with synthetic levels.
    private var simTimer: Timer?
    private var simBitIndex = 0
    private var simBits: [Int] = []
    var simulatedMessage = "WTR 1400"

    // MARK: - Session control

    private var boundPreviewLayers: [AVCaptureVideoPreviewLayer] = []

    /// Call from the SwiftUI preview so it shows the live camera feed.
    func bindPreviewLayer(_ layer: AVCaptureVideoPreviewLayer) {
        layer.videoGravity = .resizeAspectFill
        if !boundPreviewLayers.contains(where: { $0 === layer }) {
            boundPreviewLayers.append(layer)
        }
        if let s = session { layer.session = s }
    }

    func startCamera() {
        guard session == nil else { return }
        let s = AVCaptureSession()
        s.sessionPreset = .hd1280x720
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            phase = .error("Camera unavailable.")
            return
        }
        device = dev
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        s.addInput(input)
        s.addOutput(output)
        // Portrait buffers: the tap point (normalized to the portrait preview)
        // maps directly onto these pixels. (90° rotation = portrait.)
        if let conn = output.connection(with: .video), conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        session = s
        for layer in boundPreviewLayers { layer.session = s }
        sampleQueue.async { s.startRunning() }
    }

    func stopCamera() {
        stopDecoding()
        // Capture the session BEFORE nil-ing: the async block must stop the
        // OLD session, or it keeps holding the camera and the next start
        // gets a black preview.
        let s = session
        let layers = boundPreviewLayers
        session = nil
        device = nil
        sampleQueue.async {
            s?.stopRunning()
            DispatchQueue.main.async {
                for layer in layers { layer.session = nil }
            }
        }
    }

    // MARK: - Warm camera handoff between the two camera tabs

    private var pendingCameraStop: DispatchWorkItem?

    /// Call from a camera tab's onDisappear. The stop fires 0.6 s later —
    /// unless a camera tab's onAppear cancels it first (i.e. the user is just
    /// hopping between Decode and Scanner, so the session stays warm).
    func scheduleCameraStop() {
        cancelPendingCameraStop()
        let work = DispatchWorkItem { [weak self] in self?.stopCamera() }
        pendingCameraStop = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func cancelPendingCameraStop() {
        pendingCameraStop?.cancel()
        pendingCameraStop = nil
    }

    // MARK: - Decode control

    func startDecoding() {
        liveText = ""
        charsReceived = 0
        uncertainCount = 0
        localCharCount = 0
        uncertainIdx.removeAll()
        lastSeenCharCount = 0
        debugInfo = ""
        pendingBits = []
        awaitingStart = true
        decoding = false
        scanFrozen = false
        preambleEdgeTimes = []
        samples = []

        if simulate {
            startSimulatedDecode()
            return
        }
        lockCamera()
        listenDeadline = Date().timeIntervalSince1970 + 45
        DispatchQueue.main.async { self.phase = .listening }
    }

    func stopDecoding() {
        simTimer?.invalidate(); simTimer = nil
        decoding = false          // stop the bit sampler immediately
        scanFrozen = false
        unlockCamera()
        DispatchQueue.main.async { self.phase = .idle }
    }

    private func lockCamera() {
        guard let d = device else { return }
        do {
            try d.lockForConfiguration()
            if d.isExposureModeSupported(.locked) { d.exposureMode = .locked }
            if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
            d.unlockForConfiguration()
        } catch { /* proceed unlocked; calibration still adapts */ }
    }

    private func unlockCamera() {
        guard let d = device else { return }
        do {
            try d.lockForConfiguration()
            if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
            if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { d.whiteBalanceMode = .continuousAutoWhiteBalance }
            d.unlockForConfiguration()
        } catch {}
    }

    // MARK: - Frame sampling

    private func roiMeanLuminance(_ pixelBuffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return 0 }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        // ROI in pixels, from the effective (manual or auto-aim) fractional rect.
        let roi = effectiveROI
        let x0 = max(0, Int(roi.minX * CGFloat(width)))
        let x1 = min(width - 1, Int(roi.maxX * CGFloat(width)))
        let y0 = max(0, Int(roi.minY * CGFloat(height)))
        let y1 = min(height - 1, Int(roi.maxY * CGFloat(height)))
        guard x1 > x0, y1 > y0 else { return 0 }

        var sum = 0.0, count = 0.0
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let stride = 4 // sample every 4th pixel for speed
        var y = y0
        while y <= y1 {
            var x = x0
            let row = ptr.advanced(by: y * bytesPerRow)
            while x <= x1 {
                let px = row.advanced(by: x * 4)
                // 32BGRA: B,G,R,A
                let b = Double(px[0]), g = Double(px[1]), r = Double(px[2])
                sum += (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                count += 1
                x += stride
            }
            y += stride
        }
        return count > 0 ? sum / count : 0
    }

    private func averageLevel(from t0: TimeInterval, to t1: TimeInterval) -> Double? {
        let inWindow = samples.filter { $0.0 >= t0 && $0.0 < t1 }
        guard !inWindow.isEmpty else { return nil }
        return inWindow.map(\.1).reduce(0, +) / Double(inWindow.count)
    }

    /// Auto-aim: coarse full-frame scan for the strongest blinking region.
    /// Runs on the sample queue; cheap (~900 pixel reads/frame).
    private func updateAutoScan(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let n = gridCols * gridRows
        var sums = [Double](repeating: 0, count: n)
        var counts = [Double](repeating: 0, count: n)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        let stride = 32
        var y = 0
        while y < height {
            var x = 0
            let row = ptr.advanced(by: y * bytesPerRow)
            while x < width {
                let px = row.advanced(by: x * 4)
                let lum = (0.299 * Double(px[2]) + 0.587 * Double(px[1]) + 0.114 * Double(px[0])) / 255.0
                let c = min(gridCols - 1, x * gridCols / width)
                let r = min(gridRows - 1, y * gridRows / height)
                sums[r * gridCols + c] += lum
                counts[r * gridCols + c] += 1
                x += stride
            }
            y += stride
        }
        for i in 0..<n {
            guard counts[i] > 0 else { continue }
            let m = sums[i] / counts[i]
            if m < cellMin[i] { cellMin[i] = m }
            if m > cellMax[i] { cellMax[i] = m }
        }
        scanFrames += 1
        if scanFrames >= scanWindow {
            scanFrames = 0
            var best = 0, bestScore = 0.0
            var found: [CensusEntry] = []
            for i in 0..<n {
                let s = cellMax[i] - cellMin[i]
                if s > bestScore { bestScore = s; best = i }
                // Census bar is higher than auto-aim's: a cell must swing hard
                // to be listed as a beacon, or camera noise makes phantoms.
                if s > 0.22 { found.append(CensusEntry(cell: i, score: s)) }
            }
            // Background = median cell mean: robust against the beacon cell(s)
            // being outliers. Used for differential daylight decoding.
            var means: [Double] = []
            for i in 0..<n where counts[i] > 0 { means.append(sums[i] / counts[i]) }
            let bg: Double = {
                guard !means.isEmpty else { return 0 }
                let sorted = means.sorted()
                return sorted[sorted.count / 2]
            }()
            let b = best, sc = bestScore
            let censusList = found.sorted { $0.score > $1.score }
            DispatchQueue.main.async {
                self.autoCell = b
                self.autoScore = sc
                self.census = censusList
            }
            self.frameBackground = bg
            cellMin = [Double](repeating: 1.0, count: n)
            cellMax = [Double](repeating: 0.0, count: n)
        }
    }

    // MARK: - Decode state machine (runs on sampleQueue)

    private func ingest(level: Double, at time: TimeInterval) {
        // Simulate mode drives its own path; real frames must not touch it.
        guard !simulate else { return }
        samples.append((time, level))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
        // (Signal meter is driven from the raw ROI level in captureOutput.)

        guard !simulate else { return }

        switch phase {
        case .listening:
            detectPreamble(level: level, at: time)
            if time > listenDeadline {
                setPhase(.error("No beacon found — point at the LED and try again."))
            }
        case .calibrating:
            // Calibration completes inside detectPreamble once enough edges seen.
            detectPreamble(level: level, at: time)
        case .decoding:
            decodeBits(at: time)
        default:
            break
        }
    }

    /// Watches for the alternating preamble; measures bright/dim levels from it.
    private func detectPreamble(level: Double, at time: TimeInterval) {
        // Decide current binary state against a running threshold, with hysteresis.
        let hi = level > threshold + hysteresis
        let lo = level < threshold - hysteresis
        let bit: Int? = hi ? 1 : (lo ? 0 : nil)
        guard let bit else { return }

        if bit != lastEdgeLevel {
            // Edge!
            let dt = time - lastEdgeTime
            lastEdgeLevel = bit
            lastEdgeTime = time
            let expected = BlinkProtocol.bitDuration
            // Preamble edges arrive roughly every bitDuration.
            if dt > expected * 0.6 && dt < expected * 1.6 {
                preambleEdgeTimes.append(time)
                // Use the preamble's observed extremes to set the threshold.
                let recent = samples.suffix(120).map(\.1)
                if let mn = recent.min(), let mx = recent.max(), mx - mn > 0.03 {
                    threshold = (mn + mx) / 2
                    hysteresis = max(0.02, (mx - mn) * 0.15)
                }
                let progress = Double(preambleEdgeTimes.count) / Double(BlinkProtocol.preamble.count)
                setPhase(.calibrating(min(1.0, progress)))
                if preambleEdgeTimes.count >= BlinkProtocol.preamble.count {
                    // Synced. Next expected edge starts the START marker.
                    bitStartTime = time
                    pendingBits = []
                    awaitingStart = true
                    decoding = true
                    scanFrozen = true
                    decodingStartTime = time
                    lastCharTime = time
                    localCharCount = 0
        uncertainIdx.removeAll()
                    lastSeenCharCount = 0
                    setPhase(.decoding)
                }
            } else {
                // Edge at the wrong cadence — restart preamble hunt, keep threshold.
                preambleEdgeTimes = []
                if case .calibrating = phase { setPhase(.listening) }
            }
        }
    }

    /// Samples one bit per bit-window once synced. Called on every frame while decoding.
    private func decodeBits(at time: TimeInterval) {
        guard decoding else { return }
        let bd = BlinkProtocol.bitDuration
        // Sample the middle 60% of each bit window for stability.
        while time >= bitStartTime + bd {
            let w0 = bitStartTime + bd * 0.2
            let w1 = bitStartTime + bd * 0.8
            if let avg = averageLevel(from: w0, to: w1) {
                let bit = avg > threshold ? 1 : 0
                pendingBits.append(bit)
                consumeBits()
            } else {
                pendingBits.append(lastEdgeLevel) // hold last on dropout
                consumeBits()
            }
            bitStartTime += bd
            // Watchdog: a full message + gap with no END marker → resync.
            if pendingBits.count > 400 {
                resync()
                return
            }
        }
        // Progress tracking for the stall watchdog below.
        if localCharCount > lastSeenCharCount {
            lastSeenCharCount = localCharCount
            lastCharTime = time
        }
        // Stall watchdog: synced but no progress (e.g. wrong phase) → drop back
        // to preamble hunt and try again instead of waiting forever.
        // The start marker follows the preamble immediately. If we synced on
        // rhythmic message data by mistake (a false sync), bail out after 6 s
        // instead of burning a whole loop iteration before retrying.
        if awaitingStart && time - decodingStartTime > 6 { resync(); return }
        if !awaitingStart && time - lastCharTime > 25 { resync(); return }
        // Throttled field-diagnosis readout.
        if time - lastDebugUpdate > 1.0 {
            lastDebugUpdate = time
            let tail = pendingBits.suffix(24).map(String.init).joined()
            let info = "bits:\(pendingBits.count) tail:\(tail)"
            DispatchQueue.main.async { self.debugInfo = info }
        }
    }

    private func consumeBits() {
        if awaitingStart {
            guard pendingBits.count >= BlinkProtocol.startMarker.count else { return }
            let head = Array(pendingBits.prefix(BlinkProtocol.startMarker.count))
            if head == BlinkProtocol.startMarker {
                pendingBits.removeFirst(BlinkProtocol.startMarker.count)
                awaitingStart = false
            } else {
                // Slide one bit and keep hunting for the marker.
                pendingBits.removeFirst()
            }
            return
        }
        // Read 7-bit characters.
        while pendingBits.count >= 7 {
            let group = Array(pendingBits.prefix(7))
            // Check for END marker: next 6 bits after a char boundary.
            if pendingBits.count >= 6 {
                let maybeEnd = Array(pendingBits.prefix(6))
                if maybeEnd == BlinkProtocol.endMarker {
                    finishMessage()
                    return
                }
            }
            pendingBits.removeFirst(7)
            let charIndex = localCharCount
            localCharCount += 1
            if let (ch, ok) = BlinkProtocol.decode(group) {
                // First character after START must pass parity — otherwise we
                // synced onto noise mid-message. Resync instead of showing garbage.
                if charIndex == 0 && !ok {
                    resync()
                    return
                }
                if !ok { uncertainIdx.insert(charIndex) }
                let text = String(ch)
                DispatchQueue.main.async {
                    self.liveText += text
                    self.charsReceived += 1
                    if !ok { self.uncertainCount += 1 }
                }
            } else {
                uncertainIdx.insert(charIndex)
                DispatchQueue.main.async {
                    self.liveText += "�"
                    self.charsReceived += 1
                    self.uncertainCount += 1
                }
            }
        }
    }

    /// Shared completion for real and simulated decodes: stores the message,
    /// persists history, fires the AI enhancement, and reports .done.
    /// The enhancement arrives async and attaches itself to the entry —
    /// no view race, and the 💡 line can't get lost.
    /// The "  ⚠️N" suffix is display-only; strip it before any codebook lookup.
    private static func cleanCode(_ raw: String) -> String {
        if let range = raw.range(of: "  ⚠️", options: .backwards) {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func completeMessage(raw msg: String, uncertain: Set<Int>, uncertainCount uCount: Int) {
        let clean = Self.cleanCode(msg)
        guard !clean.isEmpty else {
            setPhase(.done(msg))
            return
        }
        // Display keeps the ⚠️ count; enhancement always uses the clean code.
        let displayRaw = uCount > 0 ? "\(clean)  ⚠️\(uCount)" : clean
        let language = UserDefaults.standard.string(forKey: "lighttalk.targetLanguage") ?? "system"
        let customs = CustomCodeStore.shared.codes
        let dm = DecodedMessage(rawText: clean, uncertainIndices: uncertain)
        MessageIntelligence.enhance(dm, language: language, customCodes: customs) { [weak self] out, source in
            guard let self else { return }
            let entry = ReceivedMessage(id: UUID(), raw: displayRaw,
                                        enhanced: (out != clean) ? out : nil,
                                        meaningSource: (out != clean) ? source : nil,
                                        timestamp: Date(), uncertainCount: uCount,
                                        uncertainIndices: Array(uncertain).sorted())
            DispatchQueue.main.async {
                self.messages.insert(entry, at: 0)
                self.saveHistory()
                self.phase = .done(displayRaw)
            }
        }
    }

    private func finishMessage() {
        decoding = false
        completeMessage(raw: liveText, uncertain: uncertainIdx, uncertainCount: uncertainCount)
        // Keep listening for the next loop of the beacon — unless the user stopped.
        sampleQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let stillDone: Bool = {
                if case .done = self.phase { return true } else { return false }
            }()
            guard stillDone else { return }
            self.pendingBits = []
            self.awaitingStart = true
            self.preambleEdgeTimes = []
            self.localCharCount = 0
            self.uncertainIdx.removeAll()
            self.lastSeenCharCount = 0
            DispatchQueue.main.async {
                self.liveText = ""
                self.charsReceived = 0
                self.uncertainCount = 0
            }
            self.scanFrozen = false
            self.setPhase(.listening)
            self.listenDeadline = Date().timeIntervalSince1970 + 45
        }
    }

    private func resync() {
        pendingBits = []
        awaitingStart = true
        preambleEdgeTimes = []
        decoding = false
        scanFrozen = false
        localCharCount = 0
        uncertainIdx.removeAll()
        lastSeenCharCount = 0
        setPhase(.listening)
        listenDeadline = Date().timeIntervalSince1970 + 45
    }

    private func setPhase(_ p: Phase) {
        DispatchQueue.main.async { self.phase = p }
    }

    // MARK: - Simulate mode (clearly labeled demo path)

    private func startSimulatedDecode() {
        simBits = BlinkProtocol.bitStream(for: simulatedMessage)
        simBitIndex = 0
        setPhase(.listening)
        // Fake a quick calibration, then emit bits on the real schedule.
        sampleQueue.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setPhase(.decoding)
            // Timers must live on the main run loop, not the sample queue.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.simTimer = Timer.scheduledTimer(withTimeInterval: BlinkProtocol.bitDuration,
                                                     repeats: true) { [weak self] _ in
                    self?.simStep()
                }
            }
        }
    }

    private func simStep() {
        guard simBitIndex < simBits.count else {
            simTimer?.invalidate(); simTimer = nil
            let msg = simulatedMessage
            // Simulate has no parity failures; still runs the real enhance path.
            completeMessage(raw: msg, uncertain: [], uncertainCount: 0)
            return
        }
        // Feed the bit through the same consume path as the camera.
        let bit = simBits[simBitIndex]
        simBitIndex += 1
        // Show a lively signal meter.
        DispatchQueue.main.async { self.signalMeter = bit == 1 ? 0.9 : 0.15 }
        pendingBits.append(bit)
        // Skip preamble/marker handling in sim: strip them first for clarity.
        if simBitIndex == BlinkProtocol.preamble.count + BlinkProtocol.startMarker.count {
            pendingBits = []
            awaitingStart = false
        } else if !awaitingStart {
            consumeBits()
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension BlinkDecoder: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let t = Date().timeIntervalSince1970
        let roiLevel = roiMeanLuminance(pb)
        if !scanFrozen { updateAutoScan(pb) }
        // Differential: beacon minus background. Ambient light lifts both, so
        // the difference isolates the blink (daylight robustness).
        let level = roiLevel - frameBackground
        DispatchQueue.main.async { self.signalMeter = min(1.0, max(0.0, roiLevel)) }
        ingest(level: level, at: t)
    }

    /// Flicker scanner: measure the dominant blink rate of whatever the
    /// auto-aim cell is watching — no protocol needed. Reports Hz + confidence.
    private func measureFlicker(level: Double, at time: TimeInterval) {
        // Adaptive threshold from recent history.
        flickerSamples.append((time, level))
        if flickerSamples.count > 240 { flickerSamples.removeFirst(flickerSamples.count - 240) }
        guard flickerSamples.count >= 60 else { return }
        let vals = flickerSamples.map(\.1)
        guard let mn = vals.min(), let mx = vals.max(), mx - mn > 0.02 else {
            setFlicker(hz: 0, confidence: 0)
            return
        }
        let th = (mn + mx) / 2
        let hyst = max(0.15 * (mx - mn), 0.01)
        // Edge times with hysteresis.
        var edges: [TimeInterval] = []
        var lastState = vals[0] > th ? 1 : -1
        for (t, v) in flickerSamples {
            let s: Int = v > th + hyst ? 1 : (v < th - hyst ? -1 : lastState)
            if s != lastState { edges.append(t); lastState = s }
        }
        guard edges.count >= 6 else {
            setFlicker(hz: 0, confidence: 0.2)
            return
        }
        // Intervals between edges; a clean blink has a steady rhythm.
        let intervals = zip(edges, edges.dropFirst()).map { $1 - $0 }.filter { $0 > 0.005 }
        guard intervals.count >= 4 else {
            setFlicker(hz: 0, confidence: 0.2)
            return
        }
        let mean = intervals.reduce(0, +) / Double(intervals.count)
        let variance = intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(intervals.count)
        let cv = sqrt(variance) / mean  // coefficient of variation: 0 = metronome
        // Each on-off cycle has 2 edges, so frequency = 1 / (2 * mean interval).
        let hz = 1.0 / (2.0 * mean)
        let confidence = max(0.0, min(1.0, 1.0 - cv * 2.0))
        setFlicker(hz: hz, confidence: confidence)
    }

    private func setFlicker(hz: Double, confidence: Double) {
        let h = hz, c = confidence
        DispatchQueue.main.async {
            // Smooth the readout so it doesn't jitter.
            self.flickerHz = self.flickerHz * 0.7 + h * 0.3
            self.flickerConfidence = self.flickerConfidence * 0.7 + c * 0.3
        }
    }
}
