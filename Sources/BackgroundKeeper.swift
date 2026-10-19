import Foundation
import AVFoundation

/// 后台保活：播放一段静音，让 iOS 不冻结进程，回到前台时无需重建。
/// 需要 Info.plist 的 UIBackgroundModes = audio。
final class BackgroundKeeper {
    static let shared = BackgroundKeeper()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var buffer: AVAudioPCMBuffer?

    private init() {}

    func start() {
        guard engine == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try? session.setActive(true)

            let e = AVAudioEngine()
            let p = AVAudioPlayerNode()
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: fmt)
            try e.start()

            let frames = AVAudioFrameCount(44100)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
            buf.frameLength = frames
            // 全零 = 静音
            p.play()
            p.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)

            engine = e
            player = p
            buffer = buf
        } catch {
            engine = nil
            player = nil
        }
    }

    func stop() {
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
        buffer = nil
    }
}
