import Foundation
import UIKit
import AVFoundation

/// 视频流：4 字节大端长度 + JPEG
final class ScreenStream: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var image: UIImage?
    @Published var connected = false
    @Published var fps: Double = 0
    @Published var error: String?

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var frames = 0
    private var firstFrameMarked = false
    private var retries = 0
    private var config = (max: 720, q: 58, fps: 10)
    private var lastTick = Date()
    private let lock = NSLock()
    private var stopping = false

    func setPreview(_ img: UIImage) {
        if image == nil { DispatchQueue.main.async { self.image = img } }
    }

    func start(max: Int = 720, q: Int = 58, fps: Int = 10) {
        stop()
        stopping = false
        config = (max, q, fps)
        retries = 0
        do {
            let req = try Agent.shared.streamURL(max: max, q: q, fps: fps)
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 600
            cfg.timeoutIntervalForResource = 3600
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            let t = s.dataTask(with: req)
            task = t
            t.resume()
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func stop() {
        stopping = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        DispatchQueue.main.async { self.connected = false }
    }


    // 自签证书放行（推流用的是独立 URLSession，必须自己处理挑战）
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffer.append(data)
        var images: [UIImage] = []
        while buffer.count >= 4 {
            let base = buffer.startIndex
            // 逐字节拼长度：Data 切片不保证 4 字节对齐，用 load(as:) 会崩溃
            let n = (Int(buffer[base]) << 24) | (Int(buffer[base + 1]) << 16)
                | (Int(buffer[base + 2]) << 8) | Int(buffer[base + 3])
            if n <= 0 {
                buffer.removeFirst(4)
                continue
            }
            if buffer.count < 4 + n { break }
            let jpeg = buffer.subdata(in: (base + 4)..<(base + 4 + n))
            buffer.removeFirst(4 + n)
            if let img = UIImage(data: jpeg) { images.append(img) }
        }
        lock.unlock()
        guard let last = images.last else { return }
        DispatchQueue.main.async {
            self.image = last
            self.connected = true
            self.error = nil
            self.frames += 1
            let now = Date()
            let dt = now.timeIntervalSince(self.lastTick)
            if dt >= 1 {
                self.fps = Double(self.frames) / dt
                self.frames = 0
                self.lastTick = now
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            self.connected = false
            if let e = error, !self.stopping {
                self.error = e.localizedDescription
                Diag.err("stream: \(e.localizedDescription)")
            }
            // 意外断开：1.5 秒后自动重连（最多 5 次）
            if !self.stopping && self.retries < 5 {
                self.retries += 1
                let cfg = self.config
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let self = self, !self.stopping else { return }
                    self.start(max: cfg.max, q: cfg.q, fps: cfg.fps)
                }
            }
        }
    }
}

/// 音频流：裸 PCM（s16le 单声道 24k）→ AVAudioEngine 播放
final class AudioStreamer: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var playing = false
    @Published var error: String?
    @Published var level: Double = 0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var pending = Data()
    private let lock = NSLock()
    private var stopping = false
    private let sampleRate: Double = 24000

    func start(mutePhone: Bool = true) {
        stop()
        stopping = false
        do {
            let req = try Agent.shared.audioURL(rate: Int(sampleRate), mute: mutePhone)
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 600
            cfg.timeoutIntervalForResource = 3600
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            setupEngine()
            let t = s.dataTask(with: req)
            task = t
            t.resume()
            DispatchQueue.main.async { self.playing = true }
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func setupEngine() {
        let e = AVAudioEngine()
        let p = AVAudioPlayerNode()
        let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
        e.attach(p)
        e.connect(p, to: e.mainMixerNode, format: fmt)
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try s.setActive(true)
            try e.start()
            p.play()
        } catch {
            self.error = "音频初始化失败：\(error.localizedDescription)"
        }
        engine = e
        player = p
        format = fmt
    }

    func stop() {
        stopping = true
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        pending.removeAll()
        DispatchQueue.main.async {
            self.playing = false
            self.level = 0
        }
    }


    // 自签证书放行（推流用的是独立 URLSession，必须自己处理挑战）
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending.append(data)
        // 累积 0.15s 再送，减少卡顿
        let need = Int(sampleRate * 2 * 0.15)
        var chunks: [Data] = []
        while pending.count >= need {
            chunks.append(pending.prefix(need))
            pending.removeFirst(need)
        }
        lock.unlock()
        for c in chunks { schedule(c) }
    }

    private func schedule(_ data: Data) {
        guard let p = player, let fmt = format else { return }
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            if let dst = buf.int16ChannelData?[0], let src = raw.baseAddress {
                memcpy(dst, src, data.count)
            }
        }
        // 简单电平（逐字节，避免非对齐访问）
        var peak: Int32 = 0
        data.withUnsafeBytes { raw in
            guard let p = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var i = 0
            while i + 1 < raw.count {
                let v = (Int32(Int8(bitPattern: p[i + 1])) << 8) | Int32(p[i])
                peak = max(peak, abs(v))
                i += 2
            }
        }
        let lv = Double(peak) / 32768.0
        DispatchQueue.main.async { self.level = lv }
        p.scheduleBuffer(buf, completionHandler: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        DispatchQueue.main.async {
            if let e = error, !self.stopping {
                self.error = e.localizedDescription
                Diag.err("stream: \(e.localizedDescription)")
            }
        }
    }
}
