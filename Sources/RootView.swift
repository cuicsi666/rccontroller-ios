import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppState
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
            }
            .accentColor(Theme.accent)
        }
        .background(Theme.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .task {
            await app.connect()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9)
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.accent)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(app.deviceInfo?.displayModel ?? "远程被控端")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let a = app.deviceInfo?.android, !a.isEmpty {
                        Text("Android \(a)")
                            .font(.system(size: 10))
                            .foregroundColor(Theme.dim)
                    }
                    if app.deviceInfo?.root == true {
                        TagView(text: "ROOT")
                    }
                    if let t = app.deviceInfo?.tunnel, t.connected == true {
                        TagView(text: "隧道在线", color: Theme.blue)
                    }
                }
            }
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.sub)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.bg)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.line), alignment: .bottom)
    }

    private func errorBar(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(Theme.orange)
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(Theme.text)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                Task { await app.connect() }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Theme.accent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.orange.opacity(0.12))
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
                        Text(r)
                            .font(.system(size: 12))
                            .foregroundColor(ok ? Theme.green : Theme.red)
                    }
                }
                Section(footer: Text("隧道链路：iPhone → 上海云网关(18888) → SSH 反向隧道 → 安卓本机 8787。安卓端只监听 127.0.0.1，不暴露公网。")) {
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
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
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
