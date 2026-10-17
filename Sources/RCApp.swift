import SwiftUI

@main
struct RCApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            Group {
                if state.token.isEmpty {
                    ConnectView()
                } else {
                    RootView()
                }
            }
            .environmentObject(state)
            .preferredColorScheme(.dark)
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
                            .fill(Theme.accent.opacity(0.16))
                            .frame(width: 52, height: 52)
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(Theme.accent)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("远程控制")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundColor(Theme.text)
                        Text("iPhone → 上海云隧道 → 安卓被控端")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.dim)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("网关地址").font(.system(size: 12)).foregroundColor(Theme.dim)
                    TextField("https://110.42.185.227:18888", text: $app.baseURL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 14, design: .monospaced))
                        .padding(12)
                        .background(Theme.card)
                        .foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("访问令牌").font(.system(size: 12)).foregroundColor(Theme.dim)
                    TextField("agent.conf 里的 TOKEN", text: $app.token)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(12)
                        .background(Theme.card)
                        .foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button {
                    connect()
                } label: {
                    HStack {
                        if checking { ProgressView().tint(.black) }
                        Text(checking ? "连接中…" : "连接手机")
                            .font(.system(size: 15, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent)
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(checking)

                if let r = result {
                    Text(r)
                        .font(.system(size: 12))
                        .foregroundColor(ok ? Theme.green : Theme.red)
                }

                Spacer()

                Text("前提：安卓已刷入「安卓被控端」Magisk 模块并联网，模块会自动与上海云建立隧道。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.dim)
            }
            .padding(.horizontal, 22)
        }
    }

    private func connect() {
        guard !app.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ok = false
            result = "请先填写访问令牌（安卓端 /data/adb/rc-agent/agent.conf 里的 TOKEN）"
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
