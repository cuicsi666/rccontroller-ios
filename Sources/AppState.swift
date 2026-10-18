import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "rc.base") }
    }
    @Published var token: String {
        didSet { UserDefaults.standard.set(token, forKey: "rc.token") }
    }
    @Published var deviceInfo: DeviceInfo?
    @Published var connected = false
    @Published var lastError: String?
    @Published var busy = false
    /// 0=流畅 540p 1=均衡 720p 2=高清 1080p
    @Published var quality: Int {
        didSet { UserDefaults.standard.set(quality, forKey: "rc.quality") }
    }

    init() {
        baseURL = UserDefaults.standard.string(forKey: "rc.base") ?? "https://110.42.185.227:18888"
        token = UserDefaults.standard.string(forKey: "rc.token") ?? "dc37f94344820df49639306cf9eae76c99e195d3a417ad36"
        quality = UserDefaults.standard.object(forKey: "rc.quality") as? Int ?? 0
        Agent.shared.configure(base: baseURL, token: token)
    }

    var configured: Bool { !token.isEmpty && URL(string: baseURL) != nil }

    var streamMaxWidth: Int {
        switch quality { case 0: return 540; case 2: return 1080; default: return 720 }
    }
    var streamQualityParam: Int {
        switch quality { case 0: return 52; case 2: return 70; default: return 58 }
    }
    var streamFPS: Int {
        switch quality { case 0: return 12; case 2: return 10; default: return 10 }
    }

    func apply() { Agent.shared.configure(base: baseURL, token: token) }

    func connect() async {
        apply()
        busy = true
        defer { busy = false }
        do {
            let info = try await Agent.shared.info()
            deviceInfo = info
            connected = true
            lastError = nil
        } catch {
            connected = false
            lastError = friendly(error)
            Diag.err("connect: \(lastError ?? "")")
        }
    }

    func refreshInfo() async {
        do {
            deviceInfo = try await Agent.shared.info()
            connected = true
        } catch {
            connected = false
            lastError = friendly(error)
        }
    }

    func friendly(_ error: Error) -> String {
        if let e = error as? AgentError, let d = e.errorDescription { return d }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case -1004: return "连不上网关（端口不通或服务未启动）"
            case -1001: return "连接超时，检查手机网络或隧道状态"
            case -1200, -1202, -9807: return "TLS 握手失败"
            case -1003: return "域名/IP 解析失败"
            case -1005: return "连接被断开"
            default: return "网络错误：\(ns.localizedDescription)"
            }
        }
        return error.localizedDescription
    }
}
