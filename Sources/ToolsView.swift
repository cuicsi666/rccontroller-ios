import SwiftUI
import UIKit

struct ToolsView: View {
    @EnvironmentObject var app: AppState
    @State private var apps: [AppItem] = []
    @State private var loadingApps = false
    @State private var search = ""
    @State private var brightness: Double = 128
    @State private var toast: String?
    @State private var confirmReboot = false
    @State private var actionBusy = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                deviceCard
                tunnelCard
                actionsCard
                appsCard
            }
            .padding(12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .refreshable { await reload() }
        .task { await reload() }
        .alert("确认重启手机？", isPresented: $confirmReboot) {
            Button("取消", role: .cancel) {}
            Button("重启", role: .destructive) { act { try await Agent.shared.power("reboot") } }
        } message: {
            Text("重启后模块会自动拉起，隧道约 30-60 秒恢复。")
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Theme.card)
                    .foregroundColor(Theme.text)
                    .clipShape(Capsule())
                    .padding(.bottom, 16)
            }
        }
    }

    // MARK: 设备

    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("设备")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(Theme.text)
                    Spacer()
                    if let v = app.deviceInfo?.version {
                        Text("agent \(v)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
                    }
                }
                if let info = app.deviceInfo {
                    row("型号", info.displayModel)
                    row("Android", "\(info.android ?? "?") (SDK \(info.sdk ?? "?"))")
                    row("序列号", info.serial?.isEmpty == false ? info.serial! : "—")
                    row("屏幕", info.screen.map { "\($0.width) × \($0.height)" } ?? "—")
                    row("运行时长", fmtDuration(info.uptime_s ?? 0))
                    HStack(spacing: 14) {
                        if let b = info.battery, let lv = b.level {
                            HStack(spacing: 5) {
                                Image(systemName: "battery.75")
                                    .foregroundColor(lv < 20 ? Theme.red : Theme.green)
                                Text("\(lv)%").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                            }
                        }
                        if let t = info.battery?.temperature_c {
                            Text("\(String(format: "%.1f", t))°C")
                                .font(.system(size: 12)).foregroundColor(Theme.sub)
                        }
                        if info.root == true { TagView(text: "uid 0 · root") }
                    }
                } else {
                    Text("尚未获取到设备信息").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
            }
        }
    }

    // MARK: 隧道

    private var tunnelCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("隧道").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                    Spacer()
                    if let t = app.deviceInfo?.tunnel, t.connected == true {
                        TagView(text: "在线")
                    } else {
                        TagView(text: "离线", color: Theme.red)
                    }
                }
                if let t = app.deviceInfo?.tunnel {
                    row("服务器", t.server ?? "—")
                    row("远端端口", t.remote ?? "—")
                    if let e = t.error, !e.isEmpty {
                        Text(e).font(.system(size: 11)).foregroundColor(Theme.orange)
                    }
                }
                row("网关", app.baseURL)
                Button {
                    actionBusy = true
                    Task {
                        defer { actionBusy = false }
                        do {
                            _ = try await Agent.shared.reconnectTunnel()
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await app.refreshInfo()
                            flash("已请求重连，状态已刷新")
                        } catch { flash(app.friendly(error)) }
                    }
                } label: {
                    Label("重连隧道", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.blue.opacity(0.15))
                        .foregroundColor(Theme.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    // MARK: 快捷操作

    private var actionsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("快捷操作").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                HStack(spacing: 8) {
                    quick("唤醒", "sun.max") { try await Agent.shared.power("wake") }
                    quick("锁屏", "lock") { try await Agent.shared.power("screen_off") }
                    quick("主页", "house") { try await Agent.shared.key("home") }
                    quick("截图", "camera") { try await Agent.shared.key("camera") }
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("屏幕亮度").font(.system(size: 12)).foregroundColor(Theme.sub)
                        Spacer()
                        Text("\(Int(brightness))").font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.dim)
                    }
                    Slider(value: $brightness, in: 1...255, step: 1, onEditingChanged: { editing in
                        if !editing {
                            act { try await Agent.shared.power("brightness", value: Int(brightness)) }
                        }
                    })
                    .accentColor(Theme.accent)
                }
                HStack(spacing: 8) {
                    Button {
                        confirmReboot = true
                    } label: {
                        Label("重启手机", systemImage: "restart")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Theme.red.opacity(0.14))
                            .foregroundColor(Theme.red)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    Button {
                        withAnimation { toast = nil }
                        Task {
                            do {
                                let log = try await Agent.shared.logcat(lines: 60)
                                toast = "已取日志 \(log.count) 字符"
                                UIPasteboard.general.string = log
                            } catch { flash(app.friendly(error)) }
                        }
                    } label: {
                        Label("复制日志", systemImage: "doc.on.doc")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Theme.card)
                            .foregroundColor(Theme.sub)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }

    private func quick(_ title: String, _ icon: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            act(action)
        } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 16))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Theme.card)
            .foregroundColor(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    // MARK: 应用

    private var appsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("已安装应用").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                    Spacer()
                    if loadingApps { ProgressView().scaleEffect(0.7) }
                    Text("\(filteredApps.count)").font(.system(size: 11)).foregroundColor(Theme.dim)
                }
                TextField("搜索包名…", text: $search)
                    .font(.system(size: 12))
                    .textFieldStyle(.plain)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Theme.bg)
                    .foregroundColor(Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                if apps.isEmpty {
                    Text("下拉刷新或点👇重新加载").font(.system(size: 12)).foregroundColor(Theme.dim)
                    Button("加载应用列表") { loadApps() }
                        .font(.system(size: 12, weight: .semibold))
                }
                ForEach(filteredApps.prefix(80)) { a in
                    HStack {
                        Image(systemName: "app.dashed")
                            .foregroundColor(Theme.dim)
                            .font(.system(size: 13))
                        Text(a.package)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)
                        Spacer()
                        Button("启动") {
                            act { try await Agent.shared.launch(a.package) }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.accent)
                    }
                    .padding(.vertical, 4)
                    Divider().background(Theme.line)
                }
            }
        }
    }

    private var filteredApps: [AppItem] {
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        return s.isEmpty ? apps : apps.filter { $0.package.lowercased().contains(s) }
    }

    // MARK: 工具

    private func reload() async {
        await app.refreshInfo()
        loadApps()
    }

    private func loadApps() {
        guard !loadingApps else { return }
        loadingApps = true
        Task {
            defer { loadingApps = false }
            do { apps = try await Agent.shared.apps() } catch { flash(app.friendly(error)) }
        }
    }

    private func act(_ action: @escaping () async throws -> Void) {
        guard !actionBusy else { return }
        actionBusy = true
        Task {
            defer { actionBusy = false }
            do { try await action() } catch { flash(app.friendly(error)) }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(k).font(.system(size: 12)).foregroundColor(Theme.dim).frame(width: 62, alignment: .leading)
            Text(v).font(.system(size: 12)).foregroundColor(Theme.text).lineLimit(2)
            Spacer()
        }
    }

    private func fmtDuration(_ s: Int64) -> String {
        let d = Int(s) / 86400
        let h = (Int(s) % 86400) / 3600
        let m = (Int(s) % 3600) / 60
        if d > 0 { return "\(d)天 \(h)小时" }
        if h > 0 { return "\(h)小时 \(m)分" }
        return "\(m)分钟"
    }

    private func flash(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if toast == msg { withAnimation { toast = nil } }
        }
    }
}
