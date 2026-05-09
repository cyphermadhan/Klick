@preconcurrency import AVFoundation
import Foundation
import os

/// Decodes Morse code carried by a 600 Hz beep (the sidetone
/// `MorseTone` emits on send). Mirrors `FlashlightDecoder`: samples
/// audio, detects on/off transitions, feeds a `MorseDemodulator`.
///
/// Detection approach: Goertzel filter tuned to
/// `MorseTone.defaultFrequency` (600 Hz). Runs per 20 ms window (960
/// samples at 48 kHz), produces a scalar power, compared against a
/// rolling noise floor + threshold. Cheaper than an FFT and needs only
/// three coefficients, which is exactly the right tool when we care
/// about one frequency.
@MainActor
final class AudioToneDecoder: NSObject, ObservableObject {
    /// 0…1-ish normalized tone power as of the last window. Feeds a
    /// level meter in the UI.
    @Published private(set) var currentLevel: Double = 0
    @Published private(set) var signalIsOn: Bool = false
    @Published private(set) var isRunning: Bool = false
    var onCharacter: ((Character) -> Void)?

    private let engine = AVAudioEngine()
    private let demod = MorseDemodulator()
    private let log = Logger(subsystem: "world.madhans.klick", category: "ToneDecoder")

    /// Target 20 ms window — same granularity as Opus frames, fine
    /// enough for reliable pulse classification at typical WPM. Actual
    /// window size is computed from the hardware's real sample rate
    /// at start (48 kHz on iPhone, 44.1 kHz on some macs).
    private static let windowMs: Double = 20
    private static let toneHz: Double = MorseTone.defaultFrequency

    /// Hardware sample rate captured once at start. Used to size the
    /// Goertzel window and recompute the filter coefficient.
    private var sampleRate: Double = 48_000
    private var windowSamples: Int = 960

    /// Rolling noise estimate. Threshold floats above this so a loud
    /// room doesn't blind the detector.
    private var noiseFloor: Double = 0.001
    private var onThreshold: Double { noiseFloor * 8 + 0.005 }
    private var offThreshold: Double { noiseFloor * 4 + 0.002 }

    /// Goertzel coefficient = 2·cos(2π·f/Fs). Recomputed when we learn
    /// the hardware's real sample rate at start.
    private var goertzelCoeff: Double =
        2.0 * cos(2.0 * .pi * AudioToneDecoder.toneHz / 48_000)

    private var tickTimer: Timer?
    /// Accumulator for partial windows when the tap buffer length
    /// doesn't line up with our window size.
    private var windowBuffer: [Float] = []

    override init() {
        super.init()
        demod.onCharacter = { [weak self] char in
            self?.onCharacter?(char)
        }
        windowBuffer.reserveCapacity(4096) // generous upper bound
    }

    func start() async {
        guard !isRunning else { return }

        // Mic permission — the PTT flow already asks, so this is a
        // defensive check in case the user opened the listen sheet
        // without ever hitting PTT.
        let granted = await AudioSessionManager.shared.requestMicrophonePermission()
        guard granted else {
            log.error("Microphone denied")
            return
        }

        do {
            try AudioSessionManager.shared.configureForPTT()
            try AudioSessionManager.shared.activate()
        } catch {
            log.error("Audio session configure/activate failed: \(String(describing: error))")
            return
        }

        let input = engine.inputNode
        // `inputNode.outputFormat(forBus:0)` can return a zeroed-out
        // format before the session is fully up — installing a tap with
        // that throws "required condition is false: format.sampleRate != 0"
        // and crashes. Use the hardware's actual input format, falling
        // back to nil (which tells AVAudioEngine to pick for itself).
        let hwFormat = input.inputFormat(forBus: 0)
        let tapFormat: AVAudioFormat? = hwFormat.sampleRate > 0 ? hwFormat : nil
        if tapFormat == nil {
            log.error("Audio input format unavailable; aborting listen")
            return
        }
        // Capture the real sample rate, recompute Goertzel coefficient
        // and window size. Otherwise a 44.1 kHz hardware tap against a
        // 48 kHz-tuned filter would miss the 600 Hz tone entirely.
        sampleRate = hwFormat.sampleRate
        windowSamples = max(64, Int(sampleRate * Self.windowMs / 1000))
        goertzelCoeff = 2.0 * cos(2.0 * .pi * Self.toneHz / sampleRate)

        // Defensive remove in case a prior start() left a tap behind
        // (can happen if engine.start threw after installTap succeeded).
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            self?.processBuffer(buffer)
        }
        do {
            try engine.start()
        } catch {
            log.error("Engine start failed: \(String(describing: error))")
            input.removeTap(onBus: 0)
            return
        }

        demod.reset()
        startTick()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        tickTimer?.invalidate()
        tickTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        signalIsOn = false
        currentLevel = 0
        windowBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Private

    private func startTick() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.demod.tick(at: Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    nonisolated private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        // Copy into a Swift array so we can append across buffer
        // boundaries without racing the CoreAudio thread.
        var samples: [Float] = []
        samples.reserveCapacity(frameLength)
        for i in 0..<frameLength {
            samples.append(channelData[i])
        }
        Task { @MainActor in
            self.appendAndEvaluate(samples)
        }
    }

    private func appendAndEvaluate(_ newSamples: [Float]) {
        windowBuffer.append(contentsOf: newSamples)
        while windowBuffer.count >= windowSamples {
            let window = Array(windowBuffer.prefix(windowSamples))
            windowBuffer.removeFirst(windowSamples)
            let power = goertzelPower(window)
            currentLevel = min(1.0, power * 4) // scale for display
            updateNoiseFloor(power)
            let nowMs = Date().timeIntervalSince1970 * 1000
            if !signalIsOn && power >= onThreshold {
                signalIsOn = true
                demod.signalDidGoOn(at: nowMs)
            } else if signalIsOn && power <= offThreshold {
                signalIsOn = false
                demod.signalDidGoOff(at: nowMs)
            }
        }
    }

    private func updateNoiseFloor(_ power: Double) {
        // Only adapt when we're in the off state — don't let a long
        // dah drag the floor up and kill subsequent detection.
        guard !signalIsOn else { return }
        noiseFloor = 0.9 * noiseFloor + 0.1 * power
    }

    /// Classic Goertzel: single-bin DFT via a 2-tap IIR resonator.
    /// Returns power normalized to window size so thresholds are
    /// invariant to window length.
    private func goertzelPower(_ samples: [Float]) -> Double {
        var s0: Double = 0
        var s1: Double = 0
        var s2: Double = 0
        for s in samples {
            s0 = Double(s) + goertzelCoeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - goertzelCoeff * s1 * s2
        return power / Double(samples.count * samples.count)
    }
}
