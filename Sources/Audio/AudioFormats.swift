import AVFoundation

enum AudioFormats {
    static let sampleRate: Double = 48_000
    static let channels: AVAudioChannelCount = 1
    /// 20 ms at 48 kHz — matches Opus frame size in plan.md.
    static let frameSize: AVAudioFrameCount = 960

    /// Float32, mono, non-interleaved — native format for AVAudioEngine tap output.
    static let pcm: AVAudioFormat = {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channels,
            interleaved: false
        ) else {
            fatalError("Failed to construct PCM AVAudioFormat")
        }
        return fmt
    }()

    /// Opus container format for use with AVAudioConverter (iOS 15+).
    static let opus: AVAudioFormat = {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: frameSize,
            mBytesPerFrame: 0,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 0,
            mReserved: 0
        )
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else {
            fatalError("Failed to construct Opus AVAudioFormat")
        }
        return fmt
    }()
}
