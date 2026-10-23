import SwiftUI
import UIKit
import AVFoundation

// MARK: - V4.7 新功能合集
// ① 剪贴板双向同步 ② 多设备管理 ③ 语音遥控 ④ tasksd 任务面板
// （宏面板/文件流式/截图直出等入口分别嵌在原有页面）

// MARK: ① 剪贴板双向同步

enum ClipboardSync {
    /// 取手机剪贴板内容（root 读 /dev/clipboard 不通用，走 service call）
    static func get() async throws -> String {
        let r = try await Agent.shared.exec("su -c 'service call clipboard 1' 2>/dev/null | tr -d '\n'")
        // service call 返回形如 Result: Parcel(00000000 0000000d '...text...')，取引号内
        let out = r.output ?? ""
        if let start = out.firstIndex(of: "'"), let end = out.lastIndex(of: "'"), start < end {
            let text = String(out[out.index(after: start)..<end])
            // 处理 unicode 转义
            return text.replacingOccurrences(of: "\\u", with: "\\u")
        }
        return out
    }

    /// 推送 iPhone 剪贴板到手机（ADBKeyboard 剪贴板广播）
    static func push(_ text: String) async throws {
        let b64 = Data(text.utf8).base64EncodedString()
        _ = try await Agent.shared.exec("su -c 'am broadcast -a ADB_INPUT_B64 --es msg \(b64)' >/dev/null 2>&1; " +
                                        "su -c 'input keyevent 279' >/dev/null 2>&1")
    }
}

struct ClipboardSyncView: View {
    @State private var phoneClip = ""
    @State private var busy = false
    @State private var msg = ""
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(text: "剪贴板双向同步", icon: "doc.on.clipboard")
            Text("取回来：把手机剪贴板内容拿到 iPhone。推过去：把 iPhone 剪贴板内容写进手机（适合验证码/链接）。")
                .font(.system(size: 11)).foregroundColor(Theme.dim)
            TextEditor(text: $phoneClip)
                .font(.system(size: 13)).frame(height: 100)
                .padding(8).background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 10))
            HStack(spacing: 10) {
                Button {
                    act { phoneClip = try await ClipboardSync.get() }
                } label: { pill("取手机剪贴板", "arrow.down.doc") }
                Button {
                    act { try await ClipboardSync.push(phoneClip) }
                } label: { pill("推送到手机", "arrow.up.doc") }
                Button {
                    UIPasteboard.general.string = phoneClip
                    msg = "已复制到 iPhone"
                } label: { pill("复制", "doc.on.doc") }
            }
            if !msg.isEmpty { Text(msg).font(.system(size: 11)).foregroundColor(Theme.accent) }
            Spacer()
        }
        .padding(16)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { Task { phoneClip = (try? await ClipboardSync.get()) ?? "" } }
    }

    private func pill(_ t: String, _ icon: String) -> some View {
        Label(t, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Theme.accent.opacity(0.12)).foregroundColor(Theme.accent)
            .clipShape(Capsule())
    }

    private func act(_ op: @escaping () async throws -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do { try await op(); msg = "完成" } catch { msg = app.friendly(error) }
        }
    }
}

// MARK: ② 多设备管理

struct DeviceProfile: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var base: String
    var token: String
}

@MainActor
final class DeviceStore: ObservableObject {
    static let key = "rc.devices"
    @Published var profiles: [DeviceProfile] = [] { didSet { save() } }
    @Published var activeName: String {
        didSet { UserDefaults.standard.set(activeName, forKey: "rc.activeDevice") }
    }

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let list = try? JSONDecoder().decode([DeviceProfile].self, from: d) {
            profiles = list
        }
        activeName = UserDefaults.standard.string(forKey: "rc.activeDevice") ?? ""
        // 首次：把当前单设备配置导入为第一个 profile
        if profiles.isEmpty,
           let base = UserDefaults.standard.string(forKey: "rc.base"),
           let token = UserDefaults.standard.string(forKey: "rc.token") {
            let p = DeviceProfile(name: "小米 11 Pro", base: base, token: token)
            profiles = [p]
            activeName = p.name
        }
    }

    var active: DeviceProfile? { profiles.first { $0.name == activeName } ?? profiles.first }

    func save() {
        if let d = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(d, forKey: Self.key)
        }
    }

    func applyActive(to app: AppState) {
        guard let p = active else { return }
        app.baseURL = p.base
        app.token = p.token
        app.apply()
    }
}

struct DeviceSwitcher: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var store: DeviceStore
    var onSwitch: () -> Void

    var body: some View {
        Menu {
            ForEach(store.profiles) { p in
                Button {
                    store.activeName = p.name
                    store.applyActive(to: app)
                    onSwitch()
                } label: {
                    Label(p.name, systemImage: p.name == store.activeName ? "checkmark" : "iphone.gen3")
                }
            }
            Menu("管理设备") {
                ForEach(store.profiles) { p in
                    Button("删除 \(p.name)", role: .destructive) {
                        store.profiles.removeAll { $0.id == p.id }
                    }
                }
                AddDeviceButton(store: store, app: app)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold))
                Text(store.active?.name ?? "选择设备").font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(Theme.sub)
        }
    }
}

struct AddDeviceButton: View {
    @ObservedObject var store: DeviceStore
    @ObservedObject var app: AppState
    @State private var show = false
    @State private var name = ""
    @State private var base = ""
    @State private var token = ""

    var body: some View {
        Button("添加设备…") { show = true }
            .sheet(isPresented: $show) {
                NavigationView {
                    Form {
                        TextField("名称（如：小米 12）", text: $name)
                        TextField("网关地址 https://…", text: $base)
                            .keyboardType(.URL).autocapitalization(.none)
                        TextField("Token", text: $token).autocapitalization(.none)
                        Section {
                            Button("保存") {
                                let p = DeviceProfile(name: name.isEmpty ? "设备\(store.profiles.count + 1)" : name,
                                                      base: base, token: token)
                                store.profiles.append(p)
                                store.activeName = p.name
                                store.applyActive(to: app)
                                show = false
                            }.disabled(base.isEmpty || token.isEmpty)
                        }
                    }
                    .navigationTitle("添加设备")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { show = false } } }
                }
            }
    }
}

// MARK: ③ 语音遥控

import Speech

@MainActor
final class VoiceController: NSObject, ObservableObject, SFSpeechRecognizerDelegate {
    @Published var listening = false
    @Published var transcript = ""
    @Published var result: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    func requestAuth() async -> Bool {
        let s = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let m = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
        }
        return s && m
    }

    func toggle() async {
        if listening { stop() } else { await start() }
    }

    func start() async {
        guard await requestAuth() else {
            result = "需要麦克风和语音识别权限"
            return
        }
        stop()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            request = SFSpeechAudioBufferRecognitionRequest()
            request?.shouldReportPartialResults = true
            let input = audioEngine.inputNode
            let fmt = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
                self?.request?.append(buf)
            }
            audioEngine.prepare()
            try audioEngine.start()
            listening = true
            result = nil
            task = recognizer?.recognitionTask(with: request!) { [weak self] r, _ in
                if let r = r {
                    Task { @MainActor in
                        self?.transcript = r.bestTranscription.formattedString
                    }
                }
                if r?.isFinal == true { Task { @MainActor in await self?.executeAndStop() } }
            }
        } catch {
            result = "启动失败：\(error.localizedDescription)"
            listening = false
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        request = nil
        task?.cancel()
        task = nil
        listening = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 把识别文本映射成远程指令并执行
    func executeAndStop() async {
        let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        stop()
        guard !t.isEmpty else { return }
        result = await VoiceRouter.route(t)
    }
}

enum VoiceRouter {
    static func route(_ t: String) async -> String {
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        do {
            if has(["返回", "后退"]) { try await Agent.shared.key("back"); return "已按返回" }
            if has(["主页", "桌面", "home"]) { try await Agent.shared.key("home"); return "已回主页" }
            if has(["多任务", "后台"]) { try await Agent.shared.key("recents"); return "已开多任务" }
            if has(["音量加", "音量+", "大声"]) { try await Agent.shared.key("volume_up"); return "已加音量" }
            if has(["音量减", "音量-", "小声"]) { try await Agent.shared.key("volume_down"); return "已减音量" }
            if has(["息屏", "锁屏", "关屏"]) { try await Agent.shared.power("screen_off"); return "已息屏" }
            if has(["亮屏", "唤醒"]) { try await Agent.shared.key("wake"); return "已唤醒" }
            if has(["截图", "截屏"]) {
                let img = try await Agent.shared.screenshot(max: 0, quality: 92)
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                return "截图已存 iPhone 相册"
            }
            if has(["回微信", "打开微信"]) { try await Agent.shared.launch("com.tencent.mm"); return "已打开微信" }
            if has(["哔哩", "b站", "B站"]) { try await Agent.shared.launch("tv.danmaku.bili"); return "已打开哔哩" }
            if has(["抖音"]) { try await Agent.shared.launch("com.ss.android.ugc.aweme"); return "已打开抖音" }
            // 其余当作文字输入
            _ = try await Agent.shared.text(t)
            return "已输入：\(t)"
        } catch {
            return "执行失败：\(error.localizedDescription)"
        }
    }
}

struct VoiceRemoteView: View {
    @StateObject private var voice = VoiceController()

    var body: some View {
        VStack(spacing: 18) {
            SectionTitle(text: "语音遥控", icon: "mic.fill")
            ZStack {
                Circle()
                    .fill(voice.listening ? Color.red.opacity(0.16) : Theme.accent.opacity(0.12))
                    .frame(width: 120, height: 120)
                Button {
                    Task { await voice.toggle() }
                } label: {
                    Image(systemName: voice.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 40))
                        .foregroundColor(voice.listening ? .red : Theme.accent)
                }
            }
            Text(voice.listening ? "正在聆听…" : "点按说话")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.sub)
            if !voice.transcript.isEmpty {
                Text(voice.transcript)
                    .font(.system(size: 15, weight: .medium)).foregroundColor(Theme.text)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }
            if let r = voice.result {
                Text(r).font(.system(size: 13)).foregroundColor(Theme.accent)
            }
            Text("试试：「返回」「主页」「打开微信」「截图」「音量加」，其他内容会作为文字输入到手机")
                .font(.system(size: 11)).foregroundColor(Theme.dim)
                .multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
        }
        .padding(.top, 30)
        .background(Theme.bg.ignoresSafeArea())
        .onDisappear { voice.stop() }
    }
}

// MARK: ④ tasksd.sh 任务面板

struct TaskdEntry: Identifiable {
    let id: String
    let name: String
    let enabled: Bool
    let time: String
}

struct TaskdPanelView: View {
    @State private var tasks: [TaskdEntry] = []
    @State private var loading = false
    @State private var logText = ""
    @State private var msg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionTitle(text: "自动化任务（手机端）", icon: "timer")
                Spacer()
                Button { load() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundColor(Theme.accent)
                }
            }
            if loading { ProgressView().tint(Theme.accent) }
            if tasks.isEmpty && !loading {
                Text("手机上没有 tasksd 任务（或 tasksd.sh 不存在）")
                    .font(.system(size: 12)).foregroundColor(Theme.dim)
            }
            ForEach(tasks) { t in
                HStack {
                    Image(systemName: t.enabled ? "checkmark.circle.fill" : "pause.circle")
                        .foregroundColor(t.enabled ? Theme.green : Theme.dim)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.system(size: 14, weight: .medium))
                        Text(t.enabled ? "定时 \(t.time)" : "已停用")
                            .font(.system(size: 11)).foregroundColor(Theme.dim)
                    }
                    Spacer()
                    Button("运行") { run(t.id) }
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12)).foregroundColor(Theme.accent)
                        .clipShape(Capsule())
                }
                .padding(.vertical, 6)
            }
            if !logText.isEmpty {
                ScrollView {
                    Text(logText)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 220)
                .padding(8).background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if !msg.isEmpty { Text(msg).font(.system(size: 11)).foregroundColor(Theme.accent) }
            Spacer()
        }
        .padding(16)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { load() }
    }

    private func load() {
        loading = true
        Task {
            defer { loading = false }
            guard let out = try? await Agent.shared.exec("su -c 'sh /data/adb/rc-agent/tasksd.sh list'").output else { return }
            var list: [TaskdEntry] = []
            for line in out.split(separator: "\n") {
                // 兼容格式：<id> <b64名> <HH:MM> <星期> <0|1> 或可读格式
                let parts = line.split(separator: " ").map(String.init)
                guard parts.count >= 3 else { continue }
                let name = parts[1].count == 40 || parts[1].allSatisfy { $0.isLetter || $0.isNumber }
                    ? (String(base64Decoded: parts[1]) ?? parts[1])
                    : parts[1]
                let enabled = parts.count >= 5 ? parts[4] == "1" : true
                let time = parts.count >= 3 ? parts[2] : ""
                list.append(TaskdEntry(id: parts[0], name: name, enabled: enabled, time: time))
            }
            await MainActor.run { tasks = list }
        }
    }

    private func run(_ id: String) {
        msg = "执行中…"
        Task {
            let out = try? await Agent.shared.exec("su -c 'sh /data/adb/rc-agent/tasksd.sh run \(id)'").output
            await MainActor.run {
                logText = out ?? "（无输出）"
                msg = "已完成"
            }
        }
    }

    private func runLog(_ id: String) {
        Task {
            let out = try? await Agent.shared.exec("su -c 'sh /data/adb/rc-agent/tasksd.sh log \(id)'").output
            await MainActor.run { logText = out ?? "（无日志）" }
        }
    }
}

extension String {
    init?(base64Decoded: String) {
        guard let d = Data(base64Encoded: base64Decoded) else { return nil }
        self = String(data: d, encoding: .utf8) ?? String(decoding: d, as: UTF8.self)
    }
}
