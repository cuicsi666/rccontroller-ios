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
    private var pts: Int64 = 0
    private var stopping = false

    lazy var layer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspect
        return l
    }()

    func start(size: String = "480x1066", bitrate: Int = 1_200_000) {
        stop()
        stopping = false
        do {
            let req = try Agent.shared.makeRequest("/api/h264", query: [
                URLQueryItem(name: "size", value: size),
                URLQueryItem(name: "bitrate", value: String(bitrate))
            ], timeout: 600)
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
        buffer.removeAll()
        sps = nil
        pps = nil
        formatDesc = nil
        DispatchQueue.main.async { self.ready = false }
    }

    // MARK: 网络

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        parseAndDecode()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if task !== self.task { return }
        DispatchQueue.main.async {
            self.ready = false
            if let e = error, !self.stopping { self.error = e.localizedDescription }
        }
    }

    // MARK: 解析 Annex-B

    private func parseAndDecode() {
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
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMTime(value: pts, timescale: 1000),
            decodeTimeStamp: .invalid)
        pts += 33
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
            l.enqueue(sb)
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
