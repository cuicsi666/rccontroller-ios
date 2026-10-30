import Foundation
import AVFoundation
import SwiftUI
import UIKit

/// 实验性：把手机 screenrecord 出来的 H.264 裸流解码显示
final class H264Stream: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var ready = false
    @Published var error: String?
    @Published var fps: Double = 0

    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMVideoFormatDescription?
    private var frames = 0
    private var lastTick = Date()
    /// V4.7.4：数据饥饿看门狗——记录最近一次收到网络数据的时间
    private var lastDataAt = Date()
    private var stallTask: Task<Void, Never>?
    private var pts: Int64 = 0
    private var streamStart: Date?
    private var lastFlushAt = Date.distantPast
    private var stopping = false

    lazy var layer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        return l
    }()

    func start(size: String = "480x1066", bitrate: Int = 1_200_000) {
        stop()
        stopping = false
        DispatchQueue.main.async { self.lastDataAt = Date() }
        startStallWatchdog()
        do {
            var req = try Agent.shared.makeRequest("/api/h264", query: [
                URLQueryItem(name: "size", value: size),
                URLQueryItem(name: "bitrate", value: String(bitrate))
            ], timeout: 600)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
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
        stallTask?.cancel()
        stallTask = nil
        buffer.removeAll()
        sps = nil
        pps = nil
        formatDesc = nil
        DispatchQueue.main.async { self.ready = false }
    }

    // MARK: 网络

    /// V5.0：数据饥饿看门狗（放宽到 45 秒）
    /// 关键：H.264 是差分编码，手机画面**静止时不会产生新帧**，原来 15 秒阈值会把"静止"误判成"断流"，
    /// 导致每 15~20 秒重连一次、画面黑一下 —— 这是持续卡顿的主要来源之一。
    private func startStallWatchdog() {
        stallTask?.cancel()
        stallTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self = self, !self.stopping else { return }
                let idle = await MainActor.run { Date().timeIntervalSince(self.lastDataAt) }
                if idle > 45 {
                    Diag.err("h264: \(Int(idle))s 无画面变化，主动重连")
                    await MainActor.run {
                        self.task?.cancel()
                        self.task = nil
                        self.session?.invalidateAndCancel()
                        self.session = nil
                        self.ready = false
                        // 标记为数据饥饿重连（ScreenView 无限重试）
                        NotificationCenter.default.post(name: .rcH264Died, object: "stall")
                    }
                    return
                }
            }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        DispatchQueue.main.async { self.lastDataAt = Date() }
        buffer.append(data)
        parseAndDecode()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task !== self.task { return }
        DispatchQueue.main.async {
            self.ready = false
            if let e = error, !self.stopping {
                self.error = e.localizedDescription
                // V4.7 修复：H.264 意外断流后通知 ScreenView 自动重启（原来永久黑屏卡死）
                if !self.stopping {
                    NotificationCenter.default.post(name: .rcH264Died, object: nil)
                }
            }
        }
    }

    // MARK: 解析 Annex-B

    private func parseAndDecode() {
        // V4.7 修复：缓冲加 2MB 硬上限（原来垃圾数据会让内存无限增长），同时清参数集迫使重新握手
        if buffer.count > 2_000_000 {
            buffer.removeAll()
            sps = nil
            pps = nil
            formatDesc = nil
            DispatchQueue.main.async { self.ready = false }
            return
        }
        while true {
            guard let range = nextStartCode(in: buffer) else { return }
            let after = range.upperBound
            guard let next = nextStartCode(in: buffer, from: after) else { return }
            let nal = buffer.subdata(in: after..<next.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<next.lowerBound)
            handleNAL(nal)
        }
    }

    private func nextStartCode(in data: Data, from: Data.Index? = nil) -> Range<Data.Index>? {
        let start = from ?? data.startIndex
        var i = start
        let end = data.endIndex
        while i + 3 < end {
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
                return i..<(i + 3)
            }
            if data[i] == 0, data[i + 1] == 0, data[i + 2] == 0, data[i + 3] == 1 {
                return i..<(i + 4)
            }
            i += 1
        }
        return nil
    }

    private func handleNAL(_ nal: Data) {
        guard let first = nal.first else { return }
        let type = first & 0x1F
        switch type {
        case 7:
            sps = nal
            formatDesc = nil   // V4.7：SPS 变化时强制重建 formatDesc（分辨率/码率切换不花屏）
            tryMakeFormat()
        case 8:
            pps = nal
            tryMakeFormat()
        case 1, 5:
            enqueue(nal)
        default:
            break
        }
    }

    private func tryMakeFormat() {
        guard let s = sps, let p = pps, formatDesc == nil else { return }
        s.withUnsafeBytes { sptr in
            p.withUnsafeBytes { pptr in
                guard let sb = sptr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let pb = pptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var desc: CMVideoFormatDescription?
                let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: [sb, pb],
                    parameterSetSizes: [s.count, p.count],
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &desc)
                if status == noErr, let d = desc {
                    formatDesc = d
                    DispatchQueue.main.async { self.ready = true }
                }
            }
        }
    }

    private func enqueue(_ nal: Data) {
        guard let fmt = formatDesc else { return }
        var avcc = Data()
        var len = UInt32(nal.count).bigEndian
        withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
        avcc.append(nal)

        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let bb = block else { return }
        avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(with: base, blockBuffer: bb,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }

        var sample: CMSampleBuffer?
        var sizeArray = [avcc.count]
        // 真实时间戳：避免低帧率时时间轴滞后造成画面越看越延迟
        if streamStart == nil { streamStart = Date() }
        let nowMs = Int64(Date().timeIntervalSince(streamStart!) * 1000)
        let durMs = max(20, nowMs - pts)
        pts = nowMs
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: durMs, timescale: 1000),
            presentationTimeStamp: CMTime(value: nowMs, timescale: 1000),
            decodeTimeStamp: .invalid)
        let sStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: bb,
            formatDescription: fmt,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sizeArray,
            sampleBufferOut: &sample)
        guard sStatus == noErr, let sb = sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        let l = layer
        DispatchQueue.main.async {
            if l.status == .failed { l.flush() }
            // 低延迟关键：显示层来不及消化时直接丢弃积压帧，保证看到的是最新画面
            if !l.isReadyForMoreMediaData {
                let now = Date()
                if now.timeIntervalSince(self.lastFlushAt) > 0.4 {
                    self.lastFlushAt = now
                    l.flush()
                }
            }
            l.enqueue(sb)
            self.frames += 1
            let now = Date()
            let dt = now.timeIntervalSince(self.lastTick)
            if dt >= 3 {
                self.fps = Double(self.frames) / dt
                self.frames = 0
                self.lastTick = now
            }
        }
    }
}

/// 把 AVSampleBufferDisplayLayer 包成 SwiftUI 视图
final class LayerHostView: UIView {
    var hosted: CALayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

struct H264View: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHostView {
        let v = LayerHostView()
        v.backgroundColor = .black
        v.hosted = layer
        layer.frame = v.bounds
        v.layer.addSublayer(layer)
        return v
    }
    func updateUIView(_ uiView: LayerHostView, context: Context) {
        layer.frame = uiView.bounds
    }
}
