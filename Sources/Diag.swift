import SwiftUI
import Foundation
import UIKit

/// 启动阶段探针：把关键节点写本地 + 打到安卓被控端日志（/data/adb/rc-agent/ios.log）
enum Diag {
    private static let q = DispatchQueue(label: "rc.diag")
    private static var pending: [String] = []
    private static var lastErr = ""
    private static var lastErrAt = Date.distantPast

    private static let stageKey = "rc.stage"
    private static let launchingKey = "rc.launching"
    private static let logPath = "/data/adb/rc-agent/ios.log"

    static func mark(_ s: String) {
        let line = "\(ts()) \(s)"
        UserDefaults.standard.set(line, forKey: stageKey)
        UserDefaults.standard.set(true, forKey: launchingKey)
        UserDefaults.standard.synchronize()
        post(line, sync: s == "app-init")
    }

    static func finishLaunch() {
        UserDefaults.standard.set(false, forKey: launchingKey)
        UserDefaults.standard.synchronize()
    }

    static var lastStage: String { UserDefaults.standard.string(forKey: stageKey) ?? "（无记录）" }
    static var crashedLastTime: Bool { UserDefaults.standard.bool(forKey: launchingKey) }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: stageKey)
        UserDefaults.standard.removeObject(forKey: launchingKey)
        UserDefaults.standard.removeObject(forKey: "rc.lastCrash")
    }

    /// 记录错误，每 10 秒批量上报一次到安卓端日志
    static func err(_ s: String) {
        q.sync {
            if lastErr == s && Date().timeIntervalSince(lastErrAt) < 60 { return }
            lastErr = s
            lastErrAt = Date()
            pending.append("\(ts()) ERR \(s)")
            if pending.count > 40 { pending.removeFirst(pending.count - 40) }
        }
    }

    static func startReporter() {
        Task.detached {
            while true {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                flushErrors()
            }
        }
    }

    private static func flushErrors() {
        var lines: [String] = []
        q.sync {
            lines = pending
            pending.removeAll()
        }
        guard !lines.isEmpty else { return }
        post(lines.joined(separator: " || "))
    }

    static func reportNow(_ extra: String = "") {
        let text = "\(ts()) manual-report \(extra) last=\(lastStage) crash=\(UserDefaults.standard.string(forKey: "rc.lastCrash") ?? "-")"
        post(text)
    }

    private static func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return "[" + f.string(from: Date()) + "]"
    }

    private static func post(_ line: String, sync: Bool = false) {
        guard let base = Agent.shared.baseURL else { return }
        guard var comp = URLComponents(url: base.appendingPathComponent("/api/exec"), resolvingAgainstBaseURL: false) else { return }
        guard let url = comp.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Agent.shared.token, forHTTPHeaderField: "X-RC-Token")
        let b64 = Data(line.utf8).base64EncodedString()
        let cmd = "echo \(b64) | base64 -d >> \(logPath)"
        let body: [String: Any] = ["cmd": cmd]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        req.httpBody = data
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
        let task = s.dataTask(with: req)
        task.resume()
        if sync {
            // 首次启动同步上报，保证崩溃前也能落盘
            let sem = DispatchSemaphore(value: 0)
            let obs = s.dataTask(with: req) { _, _, _ in sem.signal() }
            obs.resume()
            _ = sem.wait(timeout: .now() + 1.8)
            obs.cancel()
        }
        _ = comp
    }
}

struct DiagView: View {
    var onEnter: () -> Void = {}
    @State private var reported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "stethoscope")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(Theme.orange)
                Text("上次启动未完成")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Theme.text)
            }
            Card {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最后阶段").font(.system(size: 11)).foregroundColor(Theme.dim)
                    Text(Diag.lastStage)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(Theme.text)
                        .textSelection(.enabled)
                    if let c = UserDefaults.standard.string(forKey: "rc.lastCrash") {
                        Divider()
                        Text("异常").font(.system(size: 11)).foregroundColor(Theme.dim)
                        Text(c)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Theme.red)
                            .lineLimit(8)
                            .textSelection(.enabled)
                    }
                }
            }
            Text("可以把上面这段发给小龙虾；也可以点「上报到手机」，日志会写到安卓端 /data/adb/rc-agent/ios.log")
                .font(.system(size: 11))
                .foregroundColor(Theme.dim)
            HStack(spacing: 10) {
                Button {
                    Diag.reportNow("diag-view")
                    reported = true
                } label: {
                    Label(reported ? "已上报" : "上报到手机", systemImage: "paperplane")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Theme.fill).foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    onEnter()
                } label: {
                    Text("仍要进入主界面")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(Theme.accent).foregroundColor(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            Button("清除崩溃标记") { Diag.clear() }
                .font(.system(size: 11)).foregroundColor(Theme.dim)
            Spacer()
        }
        .padding(20)
        .background(Theme.bg.ignoresSafeArea())
    }
}
