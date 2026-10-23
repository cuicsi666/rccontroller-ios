import Foundation
import UIKit

// MARK: - 数据模型

struct ScreenSize: Codable { var width: Int; var height: Int }

struct Battery: Codable {
    var level: Int?
    var status: Int?
    var temperature_c: Double?
    var voltage_mv: Int?
}

struct Tunnel: Codable {
    var enabled: Bool?
    var connected: Bool?
    var remote: String?
    var server: String?
    var since: Int64?
    var error: String?
}

struct DeviceInfo: Codable {
    var version: String?
    var device_name: String?
    var model: String?
    var brand: String?
    var market_name: String?
    var android: String?
    var sdk: String?
    var serial: String?
    var root: Bool?
    var uid: Int?
    var uptime_s: Int64?
    var screen: ScreenSize?
    var battery: Battery?
    var adbkeyboard: Bool?
    var tunnel: Tunnel?
    var time: Int64?

    var displayModel: String {
        let m = [brand, model].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return m.isEmpty ? "安卓设备" : m
    }
}

struct ExecResult: Codable {
    var output: String?
    var exit: Int?
    var method: String?
}

struct AppItem: Codable, Identifiable {
    var package: String
    var id: String { package }
}

struct AppsResult: Codable { var apps: [AppItem] }
struct PingResult: Codable { var pong: Bool?; var version: String? }
struct TunnelResult: Codable {
    var enabled: Bool?
    var connected: Bool?
    var remote: String?
    var server: String?
    var since: Int64?
    var error: String?
}

struct SMSMessage: Codable, Identifiable, Equatable {
    var id: Int64
    var address: String
    var body: String
    var date: Int64
    var type: Int
    var read: Int

    var isInbox: Bool { type == 1 }
    var dateValue: Date { Date(timeIntervalSince1970: Double(date) / 1000) }
}

struct SMSResponse: Codable {
    var messages: [SMSMessage]
    var count: Int
}

struct VolumeEntry: Codable { var index: Int; var max: Int }

struct NotifItem: Codable, Identifiable {
    var pkg: String
    var nid: String
    var key: String?
    var title: String
    var text: String
    var sub: String?
    var time: Int64?
    var ongoing: Bool?
    var category: String?

    var id: String { pkg + "#" + nid }

    enum CodingKeys: String, CodingKey {
        case pkg, key, title, text, sub, time, ongoing, category
        case nid = "id"
    }
}

struct NotifResponse: Codable {
    var notifications: [NotifItem]
    var count: Int
}

struct RemoteFile: Codable, Identifiable {
    var name: String
    var dir: Bool
    var size: Int64?
    var mtime: Int64?
    var id: String { name }
}

struct FileListResult: Codable {
    var path: String
    var items: [RemoteFile]
}

struct CPUStat: Codable {
    var usage: Double?
    var cores: Int?
    var load1: Double?
}

struct MemStat: Codable {
    var total_kb: UInt64?
    var avail_kb: UInt64?
    var used_pct: Double?
}

struct LiveStats: Codable {
    var battery: Battery?
    var cpu: CPUStat?
    var mem: MemStat?
    var temp_c: Double?
    var temp_batt_c: Double?
    var ts: Int64?
}

struct ChargeStatus: Codable {
    var enabled: Bool?
    var stop_at: Int?
    var start_at: Int?
    var level: Int?
    var suspended: Bool?
    var state: String?
    var status: String?
    var supported: Bool?
    var node: String?
    var voltage_v: Double?
    var current_a: Double?
    var power_w: Double?
    var health: Int?
    var temp_batt: Double?
    var temp_soc: Double?
    var message: String?
    var ts: Int64?
}
struct VolumeMap: Codable { }

struct OTAStatus: Codable {
    var state: String?
    var progress: Int?
    var message: String?
    var current: String?
    var latest: String?
    var notes: String?
    var has_update: Bool?
}

private struct Envelope<T: Codable>: Codable {
    var ok: Bool
    var data: T?
    var error: String?
}

private struct RawEnvelope: Codable {
    var ok: Bool
    var error: String?
    var data: AnyCodableJSON?
}

struct AnyCodableJSON: Codable {
    let value: Any
    init(from decoder: Decoder) throws {
        if let c = try? decoder.singleValueContainer() {
            if let b = try? c.decode(Bool.self) { value = b; return }
            if let i = try? c.decode(Int.self) { value = i; return }
            if let d = try? c.decode(Double.self) { value = d; return }
            if let s = try? c.decode(String.self) { value = s; return }
            if let a = try? c.decode([AnyCodableJSON].self) { value = a.map { $0.value }; return }
            if let o = try? c.decode([String: AnyCodableJSON].self) { value = o.mapValues { $0.value }; return }
        }
        value = NSNull()
    }
    func encode(to encoder: Encoder) throws {}
}

// MARK: - 错误

enum AgentError: LocalizedError {
    case badURL
    case http(Int)
    case server(String)
    case decode(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "服务器地址格式不正确"
        case .http(let c): return "HTTP \(c)"
        case .server(let m): return m
        case .decode(let m): return "解析失败：\(m)"
        case .network(let m): return m
        }
    }
}

// MARK: - TLS

final class TrustAllDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}

// MARK: - 客户端

final class Agent {
    static let shared = Agent()

    let session: URLSession
    private let lock = NSLock()
    private var _base: URL?
    private var _token: String = ""

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.timeoutIntervalForResource = 120
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg, delegate: TrustAllDelegate(), delegateQueue: nil)
    }

    var baseURL: URL? { lock.lock(); defer { lock.unlock() }; return _base }
    var token: String { lock.lock(); defer { lock.unlock() }; return _token }

    func configure(base: String, token: String) {
        var s = base.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }
        while s.hasSuffix("/") { s.removeLast() }
        lock.lock()
        _base = URL(string: s)
        _token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
    }

    func makeRequest(_ path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        guard let base = baseURL else { throw AgentError.badURL }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        guard var comp = URLComponents(url: base.appendingPathComponent(parts[0]), resolvingAgainstBaseURL: false) else {
            throw AgentError.badURL
        }
        if parts.count > 1 { comp.query = parts[1] }
        guard let url = comp.url else { throw AgentError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-RC-Token")
        if let body = body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let t = timeout { req.timeoutInterval = t }
        return req
    }


    /// 用 URLQueryItem 构造请求，避免 path 被二次编码（%2F 变 %252F）
    func makeRequest(_ path: String, query: [URLQueryItem], method: String = "GET", timeout: TimeInterval? = nil) throws -> URLRequest {
        guard let base = baseURL else { throw AgentError.badURL }
        guard var comp = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AgentError.badURL
        }
        comp.queryItems = query
        guard let url = comp.url else { throw AgentError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-RC-Token")
        if let t = timeout { req.timeoutInterval = t }
        return req
    }

    private func send<T: Codable>(_ path: String, method: String = "GET", json: [String: Any]? = nil, as type: T.Type, timeout: TimeInterval? = nil) async throws -> T {
        var body: Data?
        if let json = json { body = try JSONSerialization.data(withJSONObject: json) }
        let req = try makeRequest(path, method: method, body: body, timeout: timeout)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AgentError.network("无响应") }
            if http.statusCode != 200 {
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let e = obj["error"] as? String { throw AgentError.server(e) }
                throw AgentError.http(http.statusCode)
            }
            let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
            if let e = env.error { throw AgentError.server(e) }
            guard let d = env.data else { throw AgentError.server("返回为空") }
            return d
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.network(error.localizedDescription)
        }
    }

    /// 返回原始 JSON 对象（结构不固定的接口用）
    func raw(_ path: String, method: String = "GET", json: [String: Any]? = nil) async throws -> [String: Any] {
        var body: Data?
        if let json = json { body = try JSONSerialization.data(withJSONObject: json) }
        let req = try makeRequest(path, method: method, body: body)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AgentError.network("无响应") }
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if http.statusCode != 200 {
            throw AgentError.server((obj["error"] as? String) ?? "HTTP \(http.statusCode)")
        }
        return obj
    }

    // MARK: 基础

    func ping() async throws -> PingResult { try await send("/api/ping", as: PingResult.self) }
    func info() async throws -> DeviceInfo { try await send("/api/info", as: DeviceInfo.self) }

    func exec(_ cmd: String, timeoutMS: Int = 30000) async throws -> ExecResult {
        try await send("/api/exec", method: "POST", json: ["cmd": cmd, "timeout_ms": timeoutMS], as: ExecResult.self)
    }

    func screenshot(max: Int = 720, quality: Int = 62) async throws -> UIImage {
        let req = try makeRequest("/api/screen?max=\(max)&q=\(quality)")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AgentError.network("无响应") }
        if http.statusCode != 200 {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? String { throw AgentError.server(e) }
            throw AgentError.http(http.statusCode)
        }
        guard let img = UIImage(data: data) else { throw AgentError.decode("不是有效图片") }
        return img
    }

    func streamURL(max: Int = 720, q: Int = 58, fps: Int = 10) throws -> URLRequest {
        var req = try makeRequest("/api/screen/stream?max=\(max)&q=\(q)&fps=\(fps)", timeout: 600)
        // V4.7.1：流式请求禁缓存/禁压缩，防止被 URLCache 或中间层拦截缓冲
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return req
    }

    func audioURL(rate: Int = 24000, mute: Bool = true) throws -> URLRequest {
        var req = try makeRequest("/api/audio?rate=\(rate)&mute=\(mute ? 1 : 0)", timeout: 600)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        return req
    }

    // MARK: 输入

    func tap(x: Int, y: Int) async throws { _ = try await send("/api/input/tap", method: "POST", json: ["x": x, "y": y], as: ExecResult.self, timeout: 4) }
    func swipe(x1: Int, y1: Int, x2: Int, y2: Int, ms: Int = 300) async throws {
        _ = try await send("/api/input/swipe", method: "POST", json: ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": ms], as: ExecResult.self, timeout: 5)
    }
    func longPress(x: Int, y: Int, ms: Int = 800) async throws {
        _ = try await send("/api/input/longpress", method: "POST", json: ["x": x, "y": y, "ms": ms], as: ExecResult.self, timeout: 5)
    }
    func pinch(cx: Int, cy: Int, from: Int, to: Int, ms: Int = 320) async throws {
        _ = try await raw("/api/input/pinch", method: "POST",
                          json: ["CX": cx, "CY": cy, "Dist1": from, "Dist2": to, "MS": ms])
    }

    func key(_ name: String) async throws { _ = try await send("/api/input/key", method: "POST", json: ["name": name], as: ExecResult.self, timeout: 4) }
    func text(_ s: String) async throws -> ExecResult { try await send("/api/input/text", method: "POST", json: ["text": s], as: ExecResult.self, timeout: 6) }

    // MARK: 应用

    func apps(system: Bool = false) async throws -> [AppItem] {
        let r = try await send("/api/apps?system=\(system ? 1 : 0)", as: AppsResult.self)
        return r.apps
    }
    func launch(_ pkg: String) async throws { _ = try await send("/api/app/launch", method: "POST", json: ["package": pkg], as: ExecResult.self) }
    func appCtl(_ pkg: String, _ action: String) async throws -> ExecResult {
        try await send("/api/app/ctl", method: "POST", json: ["package": pkg, "action": action], as: ExecResult.self)
    }
    func install(apk: Data, name: String) async throws -> ExecResult {
        var req = try makeRequest("/api/app/install?name=\(name)", method: "POST", timeout: 300)
        req.httpBody = apk
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw AgentError.http(500) }
        let env = try JSONDecoder().decode(Envelope<ExecResult>.self, from: data)
        return env.data ?? ExecResult(output: env.error, exit: -1)
    }

    // MARK: 文件

    func files(path: String) async throws -> FileListResult {
        let req = try makeRequest("/api/files", query: [URLQueryItem(name: "path", value: path)])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentError.http((resp as? HTTPURLResponse)?.statusCode ?? 500)
        }
        let env = try JSONDecoder().decode(Envelope<FileListResult>.self, from: data)
        if let e = env.error { throw AgentError.server(e) }
        guard let d = env.data else { throw AgentError.server("返回为空") }
        return d
    }

    func fileData(path: String) async throws -> Data {
        var req = try makeRequest("/api/file", query: [URLQueryItem(name: "path", value: path)], timeout: 300)
        req.httpMethod = "GET"
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentError.http((resp as? HTTPURLResponse)?.statusCode ?? 500)
        }
        return data
    }

    @discardableResult
    func upload(to path: String, data: Data) async throws -> Int {
        var req = try makeRequest("/api/file", query: [URLQueryItem(name: "path", value: path)], method: "POST", timeout: 600)
        req.httpBody = data
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (respData, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw AgentError.http((resp as? HTTPURLResponse)?.statusCode ?? 500)
        }
        if let obj = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
           let d = obj["data"] as? [String: Any], let n = d["bytes"] as? Int {
            return n
        }
        return data.count
    }

    func fileOp(_ op: String, path: String, to: String? = nil) async throws {
        var body: [String: Any] = ["op": op, "path": path]
        if let to = to { body["to"] = to }
        _ = try await raw("/api/file/op", method: "POST", json: body)
    }

    // MARK: 电源 / 音量 / 存储 / 进程 / 网络

    func power(_ action: String, value: Int = 0) async throws {
        _ = try await send("/api/power", method: "POST", json: ["action": action, "value": value], as: ExecResult.self)
    }

    func volumes() async throws -> [String: VolumeEntry] {
        let obj = try await raw("/api/volume")
        guard let d = obj["data"] as? [String: Any] else { return [:] }
        var out: [String: VolumeEntry] = [:]
        for (k, v) in d {
            if let m = v as? [String: Any], let i = m["index"] as? Int, let mx = m["max"] as? Int {
                out[k] = VolumeEntry(index: i, max: mx)
            }
        }
        return out
    }

    func setVolume(stream: Int, index: Int) async throws {
        _ = try await raw("/api/volume", method: "POST", json: ["stream": stream, "index": index])
    }

    func storage() async throws -> String {
        let obj = try await raw("/api/storage")
        let d = obj["data"] as? [String: Any] ?? [:]
        return "\(d["df"] as? String ?? "")\n\(d["usage"] as? String ?? "")"
    }

    func processes(limit: Int = 20) async throws -> String {
        let obj = try await raw("/api/processes?limit=\(limit)")
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    func network() async throws -> String {
        let obj = try await raw("/api/network")
        let d = obj["data"] as? [String: Any] ?? [:]
        let a = d["addr"] as? String ?? ""
        let r = d["route"] as? String ?? ""
        let w = d["wifi"] as? String ?? ""
        return "\(a)\n\(r)\n\(w)"
    }

    func pingHost(_ host: String) async throws -> String {
        let obj = try await raw("/api/pingtest", method: "POST", json: ["host": host])
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    func display() async throws -> String {
        let obj = try await raw("/api/display")
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    func setDisplay(width: Int, height: Int, density: Int, reset: Bool) async throws -> String {
        var body: [String: Any] = ["reset": reset]
        if width > 0 { body["Width"] = width; body["Height"] = height }
        if density > 0 { body["Density"] = density }
        let obj = try await raw("/api/display", method: "POST", json: body)
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    func props(filter: String = "") async throws -> String {
        let obj = try await raw("/api/props?filter=\(filter.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    func getSetting(ns: String = "system", key: String) async throws -> String {
        let obj = try await raw("/api/settings?ns=\(ns)&key=\(key)")
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    func putSetting(ns: String = "system", key: String, value: String) async throws -> String {
        let obj = try await raw("/api/settings", method: "POST", json: ["ns": ns, "key": key, "value": value])
        return (obj["data"] as? [String: Any])?["output"] as? String ?? ""
    }

    // MARK: 短信

    func notifications() async throws -> [NotifItem] {
        let r = try await send("/api/notifications", as: NotifResponse.self)
        return r.notifications
    }

    func sms(limit: Int = 100, sinceID: Int64 = 0) async throws -> [SMSMessage] {
        let r = try await send("/api/sms?limit=\(limit)&since_id=\(sinceID)", as: SMSResponse.self)
        return r.messages
    }

    // MARK: 隧道 / OTA

    func tunnelStatus() async throws -> TunnelResult { try await send("/api/tunnel", as: TunnelResult.self) }
    func reconnectTunnel() async throws -> TunnelResult { try await send("/api/tunnel", method: "POST", as: TunnelResult.self) }

    func logcat(lines: Int = 200) async throws -> String {
        let r = try await send("/api/logcat?lines=\(lines)", as: ExecResult.self)
        return r.output ?? ""
    }

    func stats() async throws -> LiveStats { try await send("/api/stats", as: LiveStats.self) }

    // MARK: 充电控制

    /// 充电控制在手机端由 root 脚本 charge.sh 完成（agent 3.x/4.x 都兼容，不依赖新接口）
    func charge() async throws -> ChargeStatus {
        let r = try await exec("sh /data/adb/rc-agent/charge.sh status", timeoutMS: 15000)
        let out = (r.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let line = out.split(separator: "\n").last.map(String.init) ?? out
        guard let data = line.data(using: .utf8), !line.isEmpty else {
            throw AgentError.server("充电状态读取失败")
        }
        do { return try JSONDecoder().decode(ChargeStatus.self, from: data) }
        catch { throw AgentError.decode("充电状态") }
    }

    func setCharge(enabled: Bool? = nil, stopAt: Int? = nil, startAt: Int? = nil, action: String? = nil) async throws -> ChargeStatus {
        var parts = ["sh", "/data/adb/rc-agent/charge.sh"]
        if let act = action {
            parts.append(act)
        } else {
            parts.append("set")
            if let e = enabled { parts += ["enabled", e ? "1" : "0"] }
            if let s = stopAt { parts += ["stop_at", "\(s)"] }
            if let a = startAt { parts += ["start_at", "\(a)"] }
        }
        _ = try await exec(parts.joined(separator: " "), timeoutMS: 20000)
        return try await charge()
    }

    func otaStatus() async throws -> OTAStatus { try await send("/api/ota/status", as: OTAStatus.self) }
    func otaCheck() async throws -> OTAStatus { try await send("/api/ota/check", as: OTAStatus.self) }
    func otaApply() async throws -> OTAStatus { try await send("/api/ota/apply", method: "POST", as: OTAStatus.self) }
}
