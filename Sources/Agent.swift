import Foundation
import UIKit

// MARK: - 数据模型

struct ScreenSize: Codable {
    var width: Int
    var height: Int
}

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
}

struct AppItem: Codable, Identifiable {
    var package: String
    var id: String { package }
}

struct AppsResult: Codable {
    var apps: [AppItem]
}

struct PingResult: Codable {
    var pong: Bool?
    var version: String?
}

struct TunnelResult: Codable {
    var enabled: Bool?
    var connected: Bool?
    var remote: String?
    var server: String?
    var since: Int64?
    var error: String?
}

private struct Envelope<T: Codable>: Codable {
    var ok: Bool
    var data: T?
    var error: String?
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

// MARK: - 自签名证书放行

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

// MARK: - 控制器客户端

final class Agent {
    static let shared = Agent()

    private let session: URLSession
    private let lock = NSLock()
    private var _base: URL?
    private var _token: String = ""

    init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        cfg.waitsForConnectivity = false
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

    private func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) throws -> URLRequest {
        guard let base = baseURL else { throw AgentError.badURL }
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        guard var comp = URLComponents(url: base.appendingPathComponent(parts[0]), resolvingAgainstBaseURL: false) else {
            throw AgentError.badURL
        }
        if parts.count > 1 {
            comp.query = parts[1]
        }
        guard let url = comp.url else { throw AgentError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-RC-Token")
        if let body = body {
            req.httpBody = body
            req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send<T: Codable>(_ path: String, method: String = "GET", json: [String: Any]? = nil, as type: T.Type) async throws -> T {
        var body: Data?
        if let json = json {
            body = try JSONSerialization.data(withJSONObject: json)
        }
        let req = try makeRequest(path, method: method, body: body)
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AgentError.network("无响应") }
            if http.statusCode != 200 {
                if let env = try? JSONDecoder().decode(Envelope<T>.self, from: data), let e = env.error {
                    throw AgentError.server(e)
                }
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let e = obj["error"] as? String {
                    throw AgentError.server(e)
                }
                throw AgentError.http(http.statusCode)
            }
            do {
                let env = try JSONDecoder().decode(Envelope<T>.self, from: data)
                if let e = env.error { throw AgentError.server(e) }
                guard let d = env.data else { throw AgentError.server("返回为空") }
                return d
            } catch let e as AgentError {
                throw e
            } catch {
                throw AgentError.decode(error.localizedDescription)
            }
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.network(error.localizedDescription)
        }
    }

    // MARK: API

    func ping() async throws -> PingResult {
        try await send("/api/ping", as: PingResult.self)
    }

    func info() async throws -> DeviceInfo {
        try await send("/api/info", as: DeviceInfo.self)
    }

    func exec(_ cmd: String, timeoutMS: Int = 30000) async throws -> ExecResult {
        try await send("/api/exec", method: "POST", json: ["cmd": cmd, "timeout_ms": timeoutMS], as: ExecResult.self)
    }

    func screenshot(max: Int = 720, quality: Int = 62) async throws -> UIImage {
        let path = "/api/screen?max=\(max)&q=\(quality)"
        let req = try makeRequest(path)
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

    func tap(x: Int, y: Int) async throws {
        _ = try await send("/api/input/tap", method: "POST", json: ["x": x, "y": y], as: ExecResult.self)
    }

    func swipe(x1: Int, y1: Int, x2: Int, y2: Int, ms: Int = 300) async throws {
        _ = try await send("/api/input/swipe", method: "POST",
                           json: ["x1": x1, "y1": y1, "x2": x2, "y2": y2, "ms": ms], as: ExecResult.self)
    }

    func longPress(x: Int, y: Int, ms: Int = 800) async throws {
        _ = try await send("/api/input/longpress", method: "POST",
                           json: ["x": x, "y": y, "ms": ms], as: ExecResult.self)
    }

    func key(_ name: String) async throws {
        _ = try await send("/api/input/key", method: "POST", json: ["name": name], as: ExecResult.self)
    }

    func text(_ s: String) async throws -> ExecResult {
        try await send("/api/input/text", method: "POST", json: ["text": s], as: ExecResult.self)
    }

    func apps(system: Bool = false) async throws -> [AppItem] {
        let r = try await send("/api/apps?system=\(system ? 1 : 0)", as: AppsResult.self)
        return r.apps
    }

    func launch(_ pkg: String) async throws {
        _ = try await send("/api/app/launch", method: "POST", json: ["package": pkg], as: ExecResult.self)
    }

    func power(_ action: String, value: Int = 0) async throws {
        _ = try await send("/api/power", method: "POST", json: ["action": action, "value": value], as: ExecResult.self)
    }

    func tunnelStatus() async throws -> TunnelResult {
        try await send("/api/tunnel", as: TunnelResult.self)
    }

    func reconnectTunnel() async throws -> TunnelResult {
        try await send("/api/tunnel", method: "POST", as: TunnelResult.self)
    }

    func logcat(lines: Int = 200) async throws -> String {
        let r = try await send("/api/logcat?lines=\(lines)", as: ExecResult.self)
        return r.output ?? ""
    }
}
