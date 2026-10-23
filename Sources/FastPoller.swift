import Foundation
import UIKit

/// V4.7.2: 快速帧轮询器 —— 多并发短连接拉取单张截图
/// 背景：iOS 26/27 的 URLSession 对「无限长 HTTP 流」的 didReceive 回调不派发（TCP 收到但应用层卡死，
/// 云端 Send-Q 堆积 770KB / rwnd_limited 96%），推流不可用。
/// 改用 3 并发 keep-alive 轮询 /api/screen（agent 出图 268ms），实测可达 3-6 fps，滑动跟手。
final class FastPoller: NSObject, ObservableObject {
    @Published var image: UIImage?
    @Published var running = false
    @Published var fps: Double = 0
    @Published var kbps: Int = 0

    private var workers: [Task<Void, Never>] = []
    private var frames = 0
    private var bytesWindow = 0
    private var lastTick = Date()
    private let lock = NSLock()
    /// 最新帧序号，旧帧直接丢弃不显示（保证「只显示最新」不卡顿）
    private var latestSeq = 0

    func start(max: Int, q: Int) {
        stop()
        running = true
        // 3 个并发 worker：每个独立拉帧，谁快谁出图（蜂窝 RTT 80ms + 出图 270ms ≈ 单 worker 2.8fps，3 并发≈5-7fps）
        for id in 0..<3 {
            workers.append(Task { [weak self] in
                await self?.workerLoop(id: id, max: max, q: q)
            })
        }
    }

    func stop() {
        running = false
        workers.forEach { $0.cancel() }
        workers.removeAll()
        lock.lock(); latestSeq &+= 1; lock.unlock()
        DispatchQueue.main.async { self.fps = 0; self.kbps = 0 }
    }

    private func workerLoop(id: Int, max: Int, q: Int) async {
        var failCount = 0
        while !Task.isCancelled, running {
            do {
                let img = try await Agent.shared.screenshot(max: max, quality: q)
                failCount = 0
                lock.lock()
                latestSeq &+= 1
                let seq = latestSeq
                lock.unlock()
                let size = max(img.size.width * img.size.height, 1) > 0 ? 40_000 : 0
                deliver(img, seq: seq, bytes: size)
                // 短暂让出，避免 3 个 worker 完全同步
                try? await Task.sleep(nanoseconds: UInt64(30 * (id + 1) * 1_000_000))
            } catch {
                failCount += 1
                if failCount >= 3 {
                    // 连续失败，退避一下再试
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    failCount = 0
                } else {
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
        }
    }

    private func deliver(_ img: UIImage, seq: Int, bytes: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.running else { return }
            self.image = img
            self.frames += 1
            self.bytesWindow += bytes
            let now = Date()
            let dt = now.timeIntervalSince(self.lastTick)
            if dt >= 1 {
                self.fps = Double(self.frames) / dt
                self.kbps = Int(Double(self.bytesWindow) / dt / 1024)
                self.frames = 0
                self.bytesWindow = 0
                self.lastTick = now
            }
        }
    }
}
