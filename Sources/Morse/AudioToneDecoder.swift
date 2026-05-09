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

    /// Rolling noise estimate (per-sample squared magnitude in the
    /// target bin). Threshold floats above this so a loud room doesn't
    /// blind the detector, but never drops below the absolute floor —
    /// otherwise a dead-quiet booth collapses noise estimate to zero and
    /// the first faint breath of the target tone already reads as "on".
    private var noiseFloor: Double = 0.0005
    private static let minNoiseFloor: Double = 0.0002
    private var onThreshold: Double { max(noiseFloor * 4, 0.003) }
    private var offThreshold: Double { max(noiseFloor * 2, 0.0015) }

    /// Goertzel coefficient = 2·cos(2π·f/Fs). Recomputed when we learn
    /// the hardware's real sample rate at start.
    private var goertzelCoeff: Double =
        2.0 * cos(2.0 * .pi * AudioToneDecoder.toneHz / 48_000)

    /// Main-actor task that drains captured samples into the Goertzel +
    /// demodulator at a fixed cadence. Replaces an earlier `Timer` +
    /// `MainActor.assumeIsolated` approach that was crashing with
    /// dispatch_assert_queue_fail — the timer block was being scheduled
    /// on AVAudioEngine's internal service queue (not main), and
    /// `assumeIsolated` panics when that assumption fails. A `Task`
    /// pinned to the main actor doesn't have that issue.
    private var tickTask: Task<Void, Never>?
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

    /// True when the binary was built for an iOS simulator. Simulators
    /// lack real mic hardware; installing a tap on the input node trips
    /// an internal AVAudioEngine precondition the moment render starts.
    private static let isSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    func start() async {
        guard !isRunning else { return }

        if Self.isSimulator {
            log.error("Audio listen unavailable in the simulator — use a real device")
            return
        }

        // Mic permission — the PTT flow already asks, so this is a
        // defensive check in case the user opened the listen sheet
        // without ever hitting PTT.
        let granted = await AudioSessionManager.shared.requestMicrophonePermission()
        guard granted else {
            log.error("Microphone denied")
            return
        }

        // Only (re)configure the session if it isn't already in a
        // mic-capable category. PTT may already have it set up; a
        // reconfigure on an actively-rendering session can trip the
        // other engine's graph.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            do {
                try AudioSessionManager.shared.configureForPTT()
                try AudioSessionManager.shared.activate()
            } catch {
                log.error("Audio session configure/activate failed: \(String(describing: error))")
                return
            }
        }

        let input = engine.inputNode
        // `outputFormat(forBus: 0)` is the format the tap callback
        // receives. It can come back zeroed-out if the session isn't
        // actually routed to the mic yet — installing a tap with a
        // zero sample rate throws "required condition is false:
        // format.sampleRate != 0" and crashes hard. Guard on all the
        // fields that matter, not just sampleRate.
        let hwFormat = input.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            log.error("Audio input format invalid (sr=\(hwFormat.sampleRate) ch=\(hwFormat.channelCount)); aborting listen")
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
        input.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
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
        tickTask?.cancel()
        tickTask = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRunning = false
        signalIsOn = false
        currentLevel = 0
        windowBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Private

    private func startTick() {
        tickTask?.cancel()
        // Task with @MainActor inheritance — Swift concurrency
        // guarantees the body runs on the main-actor executor, so we
        // don't need (and can't use) `MainActor.assumeIsolated` here.
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
                guard let self else { return }
                self.drainPendingSamples()
                self.demod.tick(at: Date().timeIntervalSince1970 * 1000)
            }
        }
    }

    /// Pending samples produced on the render thread, drained on the
    /// main-actor tick. Never mutate from two places at once — writes
    /// from `processBuffer` and reads from `drainPendingSamples` both
    /// go through `pendingLock`.
    private let pendingLock = NSLock()
    nonisolated(unsafe) private var pendingSamples: [Float] = []

    nonisolated private func processBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frameLength = Int(buffer.frameLength)
        // Copy into a Swift array so the render thread doesn't hand off
        // a raw pointer that AVAudioEngine might recycle.
        var samples: [Float] = []
        samples.reserveCapacity(frameLength)
        for i in 0..<frameLength {
            samples.append(channelData[i])
        }
        // Creating a Task from the real-time render thread can trip
        // EXC_BREAKPOINT in the Swift concurrency runtime when the
        // executor setup races with engine teardown. Stash into a
        // lock-protected buffer instead; the main-thread tick drains it.
        pendingLock.lock()
        pendingSamples.append(contentsOf: samples)
        pendingLock.unlock()
    }

    /// Called from the main-thread tick timer. Moves any samples the
    /// render thread has buffered into the Goertzel path.
    private func drainPendingSamples() {
        pendingLock.lock()
        let fresh = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        pendingLock.unlock()
        if !fresh.isEmpty {
            appendAndEvaluate(fresh)
        }
    }

    /// Counter used to log a sample of frames for diagnostics rather
    /// than every single one (300 fps would flood the log).
    private var tapFrameCount: Int = 0

    private func appendAndEvaluate(_ newSamples: [Float]) {
        windowBuffer.append(contentsOf: newSamples)
        while windowBuffer.count >= windowSamples {
            let window = Array(windowBuffer.prefix(windowSamples))
            windowBuffer.removeFirst(windowSamples)
            let power = goertzelPower(window)
            // Scale for display: the bar should be visible at ambient
            // levels, not just when the detector has crossed threshold.
            // 40× puts typical room-quiet power around 0.02 and a clear
            // 600 Hz tone well past the bar's top.
            currentLevel = min(1.0, power * 40)
            updateNoiseFloor(power)
            let nowMs = Date().timeIntervalSince1970 * 1000
            if !signalIsOn && power >= onThreshold {
                signalIsOn = true
                demod.signalDidGoOn(at: nowMs)
            } else if signalIsOn && power <= offThreshold {
                signalIsOn = false
                demod.signalDidGoOff(at: nowMs)
            }
            // Diagnostic trail — one line per ~500 ms so the log stays
            // skimmable. Shows whether the tap is firing AND what power
            // we're computing. If this never appears, the tap isn't
            // running; if it shows flat zeros, the Goertzel input is
            // silent (session routed away from the mic).
            //
            // Hand-formatted via String(format:) rather than OSLog's
            // `.fixed(precision:)` interpolation — that path crashed
            // on some device/OS combos (EXC_BREAKPOINT inside the
            // log interpolation machinery) and none of this is worth
            // crashing the app over a debug line.
            tapFrameCount += 1
            if tapFrameCount % 25 == 0 {
                let msg = String(format: "tap frame %d pwr=%.5f noise=%.5f on=%@",
                                 tapFrameCount, power, noiseFloor,
                                 signalIsOn ? "YES" : "no")
                log.debug("\(msg, privacy: .public)")
            }
        }
    }

    private func updateNoiseFloor(_ power: Double) {
        // Only adapt when we're in the off state — don't let a long
        // dah drag the floor up and kill subsequent detection.
        guard !signalIsOn else { return }
        let adapted = 0.9 * noiseFloor + 0.1 * power
        noiseFloor = max(Self.minNoiseFloor, adapted)
    }

    /// Classic Goertzel: single-bin DFT via a 2-tap IIR resonator.
    ///
    /// Returns the raw bin magnitude-squared divided by window size
    /// so thresholds are invariant to the specific window length we
    /// end up at on different hardware sample rates. The previous
    /// implementation divided by `N²`, which squashed even clear
    /// tones (~0.05 amplitude) below any usable threshold.
    ///
    /// For a pure sine at the target frequency with peak amplitude A
    /// sampled over N points: `s1² + s2² - coeff·s1·s2 ≈ (N·A/2)²`,
    /// so dividing by N yields roughly `N·A²/4`. A 0.05-amplitude tone
    /// over a 960-sample window at 48 kHz → ≈0.6 — comfortably above
    /// the 0.003 "on" threshold and below "clipped".
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
        return power / Double(samples.count)
    }
}
