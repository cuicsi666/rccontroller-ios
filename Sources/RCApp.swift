import SwiftUI

@main
struct RCApp: App {
    @StateObject private var state = AppState()
    @StateObject private var smsStore = SMSStore()

    var body: some Scene {
        WindowGroup {
            Group {
                if state.token.isEmpty {
                    ConnectView()
                } else {
                    RootView()
                        .environmentObject(smsStore)
                }
            }
            .environmentObject(state)
            .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var sms: SMSStore
    @State private var tab = 0
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = app.lastError, !app.connected {
                errorBar(err)
            }
            TabView(selection: $tab) {
                ScreenView()
                    .tabItem { Label("屏幕", systemImage: "iphone.gen3") }
                    .tag(0)
                TerminalView()
                    .tabItem { Label("终端", systemImage: "terminal") }
                    .tag(1)
                ToolsView()
                    .tabItem { Label("工具", systemImage: "square.grid.2x2") }
                    .tag(2)
                SMSView()
                    .tabItem { Label("短信", systemImage: "message") }
                    .badge(sms.unread > 0 ? sms.unread : 0)
                    .tag(3)
            }
            .accentColor(Theme.accent)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.light)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .task {
            await app.connect()
            sms.start()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.accent.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(app.deviceInfo?.displayModel ?? "远程被控端")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let a = app.deviceInfo?.android, !a.isEmpty {
                        Text("Android \(a)").font(.system(size: 10)).foregroundColor(Theme.dim)
                    }
                    if app.deviceInfo?.root == true { TagView(text: "ROOT") }
                    if let t = app.deviceInfo?.tunnel, t.connected == true {
                        TagView(text: "隧道在线", color: Theme.blue)
                    }
                }
            }
            Spacer()
            Circle()
                .fill(app.connected ? Theme.green : Theme.red)
                .frame(width: 8, height: 8)
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.sub)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.card)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.line), alignment: .bottom)
    }

    private func errorBar(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Theme.orange)
            Text(msg).font(.system(size: 12)).foregroundColor(Theme.text).lineLimit(2)
            Spacer()
            Button("重试") { Task { await app.connect() } }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.orange.opacity(0.10))
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) var dismiss
    @State private var testing = false
    @State private var testResult: String?
    @State private var ok = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("网关地址")) {
                    TextField("https://110.42.185.227:18888", text: $app.baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }
                Section(header: Text("访问令牌")) {
                    TextField("与安卓端 agent.conf 的 TOKEN 一致", text: $app.token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.footnote, design: .monospaced))
                }
                Section(header: Text("画质")) {
                    Picker("画质", selection: $app.quality) {
                        Text("流畅 540p").tag(0)
                        Text("均衡 720p").tag(1)
                        Text("高清 1080p").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    Button {
                        test()
                    } label: {
                        HStack {
                            Text(testing ? "测试中…" : "测试连接")
                            Spacer()
                            if testing { ProgressView() }
                        }
                    }
                    if let r = testResult {
                        Text(r).font(.system(size: 12)).foregroundColor(ok ? Theme.green : Theme.red)
                    }
                }
                Section(footer: Text("链路：iPhone → 上海云网关(18888) → SSH 反向隧道 → 安卓本机 8787。安卓端只监听 127.0.0.1，不暴露公网。")) {
                    Button("重新连接隧道") {
                        Task {
                            app.apply()
                            _ = try? await Agent.shared.reconnectTunnel()
                            await app.connect()
                        }
                    }
                }
            }
            .navigationTitle("连接设置")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        app.apply()
        Task {
            defer { testing = false }
            do {
                let info = try await Agent.shared.info()
                ok = true
                testResult = "连接成功：\(info.displayModel) · Android \(info.android ?? "?") · root=\(info.root == true ? "是" : "否")"
                app.deviceInfo = info
                app.connected = true
                app.lastError = nil
            } catch {
                ok = false
                testResult = app.friendly(error)
                app.connected = false
            }
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject var app: AppState
    @State private var checking = false
    @State private var result: String?
    @State private var ok = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 22) {
                Spacer().frame(height: 30)
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.accent.opacity(0.12))
                            .frame(width: 52, height: 52)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("远程控制").font(.system(size: 24, weight: .bold)).foregroundColor(Theme.text)
                        Text("iPhone → 上海云隧道 → 安卓被控端")
                            .font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("网关地址").font(.system(size: 12)).foregroundColor(Theme.dim)
                    TextField("https://110.42.185.227:18888", text: $app.baseURL)
                        .keyboardType(.URL).autocapitalization(.none).disableAutocorrection(true)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(12).background(Theme.card)
                        .foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("访问令牌").font(.system(size: 12)).foregroundColor(Theme.dim)
                    TextField("agent.conf 里的 TOKEN", text: $app.token)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(12).background(Theme.card)
                        .foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button { connect() } label: {
                    HStack {
                        if checking { ProgressView().tint(.white) }
                        Text(checking ? "连接中…" : "连接手机")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Theme.accent).foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(checking)
                if let r = result {
                    Text(r).font(.system(size: 12)).foregroundColor(ok ? Theme.green : Theme.red)
                }
                Spacer()
                Text("前提：安卓已刷入「安卓被控端」Magisk 模块并联网，模块会自动与上海云建立隧道。")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 22)
        }
    }

    private func connect() {
        guard !app.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ok = false
            result = "请先填写访问令牌"
            return
        }
        checking = true
        result = nil
        app.apply()
        Task {
            defer { checking = false }
            do {
                let info = try await Agent.shared.info()
                app.deviceInfo = info
                app.connected = true
                app.lastError = nil
                ok = true
                result = "连接成功：\(info.displayModel)"
            } catch {
                ok = false
                result = app.friendly(error)
            }
        }
    }
}
