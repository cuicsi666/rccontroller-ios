import Foundation
import UIKit
import AVFoundation

/// 视频流：4 字节大端长度 + JPEG
final class ScreenStream: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var image: UIImage?
    @Published var connected = false
    @Published var fps: Double = 0
    @Published var kbps: Int = 0
    @Published var error: String?
    /// V4.7：当前是否处于自动重连等待中（用于「重连中」水印）
    @Published var reconnecting = false

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var frames = 0
    private var bytesWindow = 0
    private var retries = 0
    private var config = (max: 720, q: 58, fps: 10)
    private var lastTick = Date()
    private let lock = NSLock()
    private var stopping = false
    /// V4.7：帧率自适应加速——连续高产帧时临时提高解码线程优先级
    private var lastFrameAt = Date.distantPast

    /// V4.7：供外部显示的连接文案
    var statusText: String {
        if connected { return "实时" }
        if reconnecting { return "重连中…" }
        return "连接中…"
    }

    func setPreview(_ img: UIImage) {
        DispatchQueue.main.async { if self.image == nil { self.image = img } }
    }

    /// 兜底轮询用：推流没接上时持续刷新
    func setPolled(_ img: UIImage) {
        DispatchQueue.main.async { if !self.connected { self.image = img } }
    }

    func start(max: Int = 720, q: Int = 58, fps: Int = 10) {
        stop()
        stopping = false
        config = (max, q, fps)
        // 注意：retries 不在这里清零（否则重连风暴），只在收到首帧时清零
        do {
            let req = try Agent.shared.streamURL(max: max, q: q, fps: fps)
            let cfg = URLSessionConfiguration.ephemeral  // V4.7.1: ephemeral 禁缓存禁 cookie，防止推流请求被 URLCache 拦截
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
        DispatchQueue.main.async {
            self.connected = false
            self.reconnecting = false
        }
        lock.lock(); buffer.removeAll(); lock.unlock()
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
        bytesWindow += data.count
        var latest: UIImage?
        lock.lock()
        buffer.append(data)
        // V4.7 优化：只保留最后一个完整 JPEG，前面的帧直接跳过不解码（原来每帧都 UIImage 解码，CPU 白烧）
        var lastRange: Range<Data.Index>?
        var scan = buffer.startIndex
        while buffer.count - (scan - buffer.startIndex) >= 4 {
            let n = (Int(buffer[scan]) << 24) | (Int(buffer[scan + 1]) << 16)
                | (Int(buffer[scan + 2]) << 8) | Int(buffer[scan + 3])
            if n <= 0 { scan += 4; continue }
            if buffer.count < (scan - buffer.startIndex) + 4 + n { break }
            lastRange = scan..<(scan + 4 + n)
            scan += 4 + n
        }
        if let r = lastRange {
            let jpeg = buffer.subdata(in: r)
            buffer.removeFirst(r.upperBound - buffer.startIndex)
            // 解码放在锁外，避免慢解码反压网络回调
            lock.unlock()
            latest = UIImage(data: jpeg)
            lock.lock()
        }
        lock.unlock()
        guard let img = latest else { return }
        DispatchQueue.main.async {
            self.image = img
            let first = !self.connected
            self.connected = true
            self.reconnecting = false
            self.error = nil
            // V4.7 修复：retries 只在真正连上（首帧到达）时清零，指数退避才生效
            if first { self.retries = 0 }
            self.frames += 1
            let now = Date()
            let dt = now.timeIntervalSince(self.lastTick)
            if dt >= 3 {
                self.fps = Double(self.frames) / dt
                self.kbps = Int(Double(self.bytesWindow) / dt / 1024)
                self.frames = 0
                self.bytesWindow = 0
                self.lastTick = now
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // 旧会话被主动 cancel 时不要触发重连
        if task !== self.task { return }
        DispatchQueue.main.async {
            self.connected = false
            if let e = error, !self.stopping {
                self.error = e.localizedDescription
                Diag.err("stream: \(e.localizedDescription)")
            }
            // V4.7 修复：指数退避重连（1.5s/3s/6s/12s，封顶 12s），不再固定 1.5s 死循环
            if !self.stopping && self.retries < 6 {
                self.retries += 1
                let delay = min(1.5 * pow(2, Double(self.retries - 1)), 12)
                self.reconnecting = true
                let cfg = self.config
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self = self, !self.stopping else { return }
                    self.start(max: cfg.max, q: cfg.q, fps: cfg.fps)
                }
            } else if !self.stopping {
                self.reconnecting = false
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
    private var gotFirstByte = false
    private let sampleRate: Double = 24000

    func start(mutePhone: Bool = true) {
        stop()
        stopping = false
        gotFirstByte = false
        do {
            let req = try Agent.shared.audioURL(rate: Int(sampleRate), mute: mutePhone)
            let cfg = URLSessionConfiguration.ephemeral  // V4.7.1: ephemeral 禁缓存禁 cookie，防止推流请求被 URLCache 拦截
            cfg.timeoutIntervalForRequest = 600
            cfg.timeoutIntervalForResource = 3600
            let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
            session = s
            setupEngine()
            let t = s.dataTask(with: req)
            task = t
            t.resume()
            // V4.7 修复：收到首包才算 playing（原来连接失败也显示「声音已同步」）
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
        if !gotFirstByte {
            gotFirstByte = true
            DispatchQueue.main.async { if !self.stopping { self.playing = true } }
        }
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
            self.playing = false
            if let e = error, !self.stopping {
                self.error = e.localizedDescription
                Diag.err("stream: \(e.localizedDescription)")
            }
        }
    }
}
