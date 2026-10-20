import SwiftUI
import UIKit

struct ToolsView: View {
    var active: Bool = false
    @EnvironmentObject var app: AppState

    // 设备
    @State private var info: DeviceInfo?
    @State private var apps: [AppItem] = []
    @State private var search = ""
    @State private var loadingApps = false

    // 系统
    @State private var volumes: [String: VolumeEntry] = [:]
    @State private var storage = ""
    @State private var processes = ""
    @State private var network = ""
    @State private var display = ""
    @State private var props = ""
    @State private var propsFilter = "ro.product"
    @State private var settingKey = "screen_brightness"
    @State private var settingValue = ""
    @State private var pingResult = ""
    @State private var pingHost = "223.5.5.5"

    // OTA
    @State private var ota: OTAStatus?
    @State private var otaPolling = false

    @State private var brightness: Double = 128
    @State private var toast: String?
    @State private var confirmReboot = false
    @State private var busy = false
    @State private var showTerminal = false
    @State private var showFiles = false
    @State private var loadedOnce = false

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                deviceCard
                terminalCard
                fileCard
                otaCard
                systemCard
                tunnelCard
            }
            .padding(12)
        }
        .background(Theme.bg.ignoresSafeArea())
        .refreshable { await reloadAll() }
        .task(id: active) {
            guard active, !loadedOnce else { return }
            loadedOnce = true
            await reloadAll()
        }
        .sheet(isPresented: $showFiles) {
            NavigationView {
                FilesView()
                    .navigationTitle("文件管理")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { showFiles = false }
                        }
                    }
            }
            .preferredColorScheme(.light)
        }
        .sheet(isPresented: $showTerminal) {
            NavigationView {
                TerminalView()
                    .navigationTitle("root 终端")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("关闭") { showTerminal = false }
                        }
                    }
            }
            .preferredColorScheme(.light)
        }
        .alert("确认重启手机？", isPresented: $confirmReboot) {
            Button("取消", role: .cancel) {}
            Button("重启", role: .destructive) { act { try await Agent.shared.power("reboot") } }
        } message: { Text("重启后模块自动拉起，隧道约 30-60 秒恢复。") }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(Color.black.opacity(0.8)).foregroundColor(.white)
                    .clipShape(Capsule()).padding(.bottom, 16)
            }
        }
    }

    // MARK: 设备

    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "设备", icon: "iphone")
                    if let v = (info ?? app.deviceInfo)?.version {
                        Text("agent \(v)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
                    }
                }
                if let d = info ?? app.deviceInfo {
                    row("型号", d.displayModel)
                    row("Android", "\(d.android ?? "?") (SDK \(d.sdk ?? "?"))")
                    row("序列号", d.serial?.isEmpty == false ? d.serial! : "—")
                    row("屏幕", d.screen.map { "\($0.width) × \($0.height)" } ?? "—")
                    row("运行时长", fmtDuration(d.uptime_s ?? 0))
                    HStack(spacing: 14) {
                        if let b = d.battery, let lv = b.level {
                            HStack(spacing: 5) {
                                Image(systemName: "battery.75").foregroundColor(lv < 20 ? Theme.red : Theme.green)
                                Text("\(lv)%").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                            }
                        }
                        if let t = d.battery?.temperature_c {
                            Text("\(String(format: "%.1f", t))°C").font(.system(size: 12)).foregroundColor(Theme.sub)
                        }
                        if d.root == true { TagView(text: "uid 0 · root") }
                    }
                } else {
                    Text("尚未获取到设备信息").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
            }
        }
    }

    // MARK: 终端入口

    private var terminalCard: some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.text.opacity(0.06))
                        .frame(width: 38, height: 38)
                    Image(systemName: "terminal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.text)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("root 终端")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("uid 0 执行命令 · 历史 / 收藏 / 脚本 / 后台任务")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showTerminal = true
                } label: {
                    Text("打开")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.accent.opacity(0.12))
                        .foregroundColor(Theme.accent)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: 文件入口

    private var fileCard: some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.orange.opacity(0.10))
                        .frame(width: 38, height: 38)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("文件管理")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("浏览 / 编辑文档 / 播放音视频 / 上传下载")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showFiles = true
                } label: {
                    Text("打开")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.orange.opacity(0.12))
                        .foregroundColor(Theme.orange)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: OTA

    private var otaCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "系统升级", icon: "arrow.down.circle")
                    if let s = ota {
                        TagView(text: "当前 \(s.current ?? "-")", color: Theme.sub)
                    }
                }
                if let s = ota {
                    if let m = s.message, !m.isEmpty {
                        Text(m).font(.system(size: 12)).foregroundColor(Theme.sub)
                    }
                    if (s.progress ?? 0) > 0 || ["downloading", "verifying", "installing", "restarting"].contains(s.state ?? "") {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: Double(s.progress ?? 0), total: 100)
                                .tint(Theme.accent)
                            Text("\(s.progress ?? 0)%").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
                        }
                    }
                    if let n = s.notes, !n.isEmpty, s.has_update == true {
                        Text(n).font(.system(size: 11)).foregroundColor(Theme.dim)
                    }
                } else {
                    Text("点击「检查更新」查看是否有新版本").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                HStack(spacing: 8) {
                    Button {
                        checkOTA()
                    } label: {
                        Label("检查更新", systemImage: "magnifyingglass")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Theme.fill).foregroundColor(Theme.text)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    Button {
                        applyOTA()
                    } label: {
                        Label("立即更新", systemImage: "arrow.up.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Theme.accent.opacity(0.12)).foregroundColor(Theme.accent)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .disabled(!(ota?.has_update ?? false))
                }
            }
        }
    }

    // MARK: 声音

    private var soundCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "声音与音量", icon: "speaker.wave.2")
                ForEach(streamItems) { item in
                    if let v = volumes[item.id] {
                        HStack(spacing: 8) {
                            Text(item.label).font(.system(size: 11)).foregroundColor(Theme.sub).frame(width: 30, alignment: .leading)
                            Slider(value: Binding(
                                get: { Double(v.index) },
                                set: { nv in setVol(stream: Int(item.id) ?? 3, index: Int(nv)) }
                            ), in: 0...Double(max(v.max, 1)), step: 1)
                            .tint(Theme.accent)
                            Text("\(v.index)").font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim).frame(width: 28)
                        }
                    }
                }
                Text("提示：开启「同步声音」时会自动把手机扬声器静音（码器级），iPhone 上听声音。")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
            }
        }
    }

    // MARK: 存储

    private var storageCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "存储", icon: "internaldrive")
                Text(storage.isEmpty ? "加载中…" : storage)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.sub)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: 进程

    private var processCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    SectionTitle(text: "进程（CPU Top）", icon: "cpu")
                    Button("刷新") { Task { processes = (try? await Agent.shared.processes()) ?? processes } }
                        .font(.system(size: 11)).foregroundColor(Theme.accent)
                }
                Text(processes.isEmpty ? "加载中…" : processes)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.sub)
                    .lineLimit(14)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: 网络

    private var networkCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "网络", icon: "wifi")
                Text(network.isEmpty ? "加载中…" : network)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.sub).lineLimit(8).textSelection(.enabled)
                HStack(spacing: 8) {
                    TextField("目标地址", text: $pingHost)
                        .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("测延迟") {
                        act {
                            pingResult = try await Agent.shared.pingHost(pingHost)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
                }
                if !pingResult.isEmpty {
                    Text(pingResult).font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Theme.sub).lineLimit(8)
                }
            }
        }
    }

    // MARK: 显示

    private var displayCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "显示（分辨率 / DPI）", icon: "rectangle.on.rectangle")
                Text(display.isEmpty ? "加载中…" : display)
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.sub)
                HStack(spacing: 8) {
                    Button("恢复默认") {
                        act { display = try await Agent.shared.setDisplay(width: 0, height: 0, density: 0, reset: true) }
                    }
                    .font(.system(size: 11)).foregroundColor(Theme.red)
                    Button("1080×2400 / 480dpi") {
                        act { display = try await Agent.shared.setDisplay(width: 1080, height: 2400, density: 480, reset: false) }
                    }
                    .font(.system(size: 11)).foregroundColor(Theme.accent)
                }
            }
        }
    }

    // MARK: 应用

    private var appCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "应用管理", icon: "square.grid.3x3")
                    if loadingApps { ProgressView().scaleEffect(0.6) }
                    Text("\(filteredApps.count)").font(.system(size: 10)).foregroundColor(Theme.dim)
                }
                TextField("搜索包名…", text: $search)
                    .font(.system(size: 12)).textFieldStyle(.plain)
                    .autocapitalization(.none).disableAutocorrection(true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 8))
                if apps.isEmpty {
                    Button("加载应用列表") { loadApps() }.font(.system(size: 12, weight: .semibold))
                }
                ForEach(filteredApps.prefix(40)) { a in
                    HStack {
                        Text(a.package)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(Theme.text).lineLimit(1)
                        Spacer()
                        Button("启动") { act { try await Agent.shared.launch(a.package) } }
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accent)
                        Menu {
                            Button("强制停止") { appAction(a.package, "force-stop") }
                            Button("冻结（停用）") { appAction(a.package, "disable") }
                            Button("解冻（启用）") { appAction(a.package, "enable") }
                            Button("清除数据", role: .destructive) { appAction(a.package, "clear") }
                            Button("卸载", role: .destructive) { appAction(a.package, "uninstall") }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundColor(Theme.dim)
                        }
                    }
                    .padding(.vertical, 3)
                    Divider().background(Theme.line)
                }
            }
        }
    }

    // MARK: 系统设置

    private var systemCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "系统属性 / 设置", icon: "gearshape.2")
                HStack(spacing: 8) {
                    TextField("属性过滤，如 ro.product", text: $propsFilter)
                        .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("查询") {
                        act { props = try await Agent.shared.props(filter: propsFilter) }
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
                }
                if !props.isEmpty {
                    Text(props).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Theme.sub).lineLimit(10).textSelection(.enabled)
                }
                Divider()
                HStack(spacing: 8) {
                    TextField("settings key", text: $settingKey)
                        .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 8))
                    TextField("值", text: $settingValue)
                        .font(.system(size: 11, design: .monospaced)).textFieldStyle(.plain)
                        .padding(.horizontal, 8).padding(.vertical, 7)
                        .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button("写入") {
                        act {
                            _ = try await Agent.shared.putSetting(key: settingKey, value: settingValue)
                            toast = "已写入 \(settingKey)=\(settingValue)"
                        }
                    }
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.accent)
                }
            }
        }
    }

    // MARK: 隧道 / 快捷

    private var tunnelCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "隧道与快捷操作", icon: "point.3.connected.trianglepath.dotted")
                    if let t = (info ?? app.deviceInfo)?.tunnel, t.connected == true {
                        TagView(text: "在线")
                    } else {
                        TagView(text: "离线", color: Theme.red)
                    }
                }
                if let t = (info ?? app.deviceInfo)?.tunnel {
                    row("服务器", t.server ?? "—")
                    row("远端端口", t.remote ?? "—")
                }
                HStack(spacing: 8) {
                    quick("唤醒", "sun.max") { try await Agent.shared.power("wake") }
                    quick("锁屏", "lock") { try await Agent.shared.power("screen_off") }
                    quick("主页", "house") { try await Agent.shared.key("home") }
                    quick("日志", "doc.text") {
                        let l = try await Agent.shared.logcat(lines: 80)
                        UIPasteboard.general.string = l
                        toast = "日志已复制"
                    }
                }
                HStack(spacing: 8) {
                    Button { confirmReboot = true } label: {
                        Label("重启手机", systemImage: "restart")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Theme.red.opacity(0.10)).foregroundColor(Theme.red)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                    Button {
                        act {
                            _ = try await Agent.shared.reconnectTunnel()
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            await app.refreshInfo()
                            toast = "已请求重连"
                        }
                    } label: {
                        Label("重连隧道", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Theme.blue.opacity(0.10)).foregroundColor(Theme.blue)
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }
                }
            }
        }
    }

    private func quick(_ title: String, _ icon: String, action: @escaping () async throws -> Void) -> some View {
        Button { act(action) } label: {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 15))
                Text(title).font(.system(size: 10))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 9)
            .background(Theme.card).foregroundColor(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        }
    }

    private let streamItems = [
        PresetItem(id: "3", label: "媒体", value: ""),
        PresetItem(id: "2", label: "铃声", value: ""),
        PresetItem(id: "4", label: "闹钟", value: ""),
        PresetItem(id: "5", label: "通知", value: "")
    ]

    private var filteredApps: [AppItem] {
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        return s.isEmpty ? apps : apps.filter { $0.package.lowercased().contains(s) }
    }

    // MARK: 数据

    private func reloadAll() async {
        await app.refreshInfo()
        info = app.deviceInfo
        loadApps()
        volumes = (try? await Agent.shared.volumes()) ?? [:]
        storage = (try? await Agent.shared.storage()) ?? ""
        processes = (try? await Agent.shared.processes()) ?? ""
        network = (try? await Agent.shared.network()) ?? ""
        display = (try? await Agent.shared.display()) ?? ""
        ota = try? await Agent.shared.otaStatus()
    }

    private func loadApps() {
        guard !loadingApps else { return }
        loadingApps = true
        Task {
            defer { loadingApps = false }
            apps = (try? await Agent.shared.apps()) ?? apps
        }
    }

    private func appAction(_ pkg: String, _ action: String) {
        act {
            let r = try await Agent.shared.appCtl(pkg, action)
            toast = "\(action) → \(r.output?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40) ?? "")"
            if action == "uninstall" { apps.removeAll { $0.package == pkg } }
        }
    }

    private func setVol(stream: Int, index: Int) {
        guard let cur = volumes[String(stream)], cur.index != index else { return }
        volumes[String(stream)] = VolumeEntry(index: index, max: cur.max)
        Task { try? await Agent.shared.setVolume(stream: stream, index: index) }
    }

    // MARK: 文件入口

    private var fileCard: some View {
        Card {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.orange.opacity(0.10))
                        .frame(width: 38, height: 38)
                    Image(systemName: "folder.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(Theme.orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("文件管理")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.text)
                    Text("浏览 / 编辑文档 / 播放音视频 / 上传下载")
                        .font(.system(size: 10))
                        .foregroundColor(Theme.dim)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    showFiles = true
                } label: {
                    Text("打开")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Theme.orange.opacity(0.12))
                        .foregroundColor(Theme.orange)
                        .clipShape(Capsule())
                }
            }
        }
    }

    // MARK: OTA 操作

    private func checkOTA() {
        Task {
            do {
                let s = try await Agent.shared.otaCheck()
                ota = s
                toast = s.has_update == true ? "发现新版本 \(s.latest ?? "")" : "已是最新版本"
            } catch { toast = app.friendly(error) }
        }
    }

    private func applyOTA() {
        Task {
            do {
                _ = try await Agent.shared.otaApply()
                startOTAPolling()
            } catch { toast = app.friendly(error) }
        }
    }

    private func startOTAPolling() {
        guard !otaPolling else { return }
        otaPolling = true
        Task {
            for _ in 0..<240 {
                if let s = try? await Agent.shared.otaStatus() {
                    await MainActor.run { ota = s }
                    let st = s.state ?? ""
                    if st == "restarting" || st == "error" {
                        if st == "restarting" {
                            toast = "升级完成，等待服务重启…"
                            try? await Task.sleep(nanoseconds: 6_000_000_000)
                            await app.connect()
                        }
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
            await MainActor.run { otaPolling = false }
        }
    }

    // MARK: 工具

    private func act(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await action() } catch { toast = app.friendly(error) }
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
}
