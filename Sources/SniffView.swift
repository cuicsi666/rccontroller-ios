import SwiftUI
import UIKit

// MARK: - 抓包文件模型

struct SniffFile: Identifiable, Equatable {
    var id: String { path }
    var size: String
    var date: String
    var path: String
    var name: String { (path as NSString).lastPathComponent }
}

// MARK: - 系统级抓包（root tcpdump）

struct SniffView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var app: AppState

    @State private var statusText = "读取中…"
    @State private var running = false
    @State private var files: [SniffFile] = []
    @State private var filterKind = 0          // 0 全部 1 HTTPS 2 HTTP 3 DNS
    @State private var customFilter = ""
    @State private var newName = ""
    @State private var busy = false
    @State private var toast: String?
    @State private var shareURL: URL?
    @State private var showShare = false

    private let filterNames = ["全部流量", "HTTPS(443)", "HTTP(80)", "DNS(53)", "自定义"]
    private var filterExpr: String {
        switch filterKind {
        case 1: return "tcp port 443"
        case 2: return "tcp port 80"
        case 3: return "udp port 53 or tcp port 53"
        case 4: return customFilter.trimmingCharacters(in: .whitespaces)
        default: return ""
        }
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    controlCard
                    filesCard
                    tipCard
                }
                .padding(14)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("系统级抓包")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(Color.black.opacity(0.82)).foregroundColor(.white)
                        .clipShape(Capsule()).padding(.bottom, 18)
                }
            }
            .sheet(isPresented: $showShare) {
                if let u = shareURL { ShareSheet(items: [u] as [Any]) }
            }
        }
        .task {
            await refresh()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                await refreshStatusOnly()
            }
        }
    }

    // MARK: 状态

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "抓包状态", icon: "waveform.path.ecg")
                    Spacer()
                    TagView(text: running ? "抓包中" : "空闲", color: running ? Theme.red : Theme.sub)
                }
                Text(statusText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("root 权限 · 内核层 tcpdump · 覆盖全部 App 与全部网络接口（无需 VPN，App 无法绕过）")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
            }
        }
    }

    // MARK: 控制

    private var controlCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "开始 / 停止", icon: "record.circle")

                Picker("过滤", selection: $filterKind) {
                    ForEach(0..<filterNames.count, id: \.self) { i in
                        Text(filterNames[i]).tag(i)
                    }
                }
                .pickerStyle(.menu)
                .tint(Theme.accent)

                if filterKind == 4 {
                    TextField("tcp port 8080 or udp port 53", text: $customFilter)
                        .font(.system(size: 11, design: .monospaced))
                        .padding(10).background(Theme.fill)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .autocapitalization(.none).disableAutocorrection(true)
                }

                TextField("文件名（可留空自动生成）", text: $newName)
                    .font(.system(size: 12))
                    .padding(10).background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Button {
                        start()
                    } label: {
                        Label("开始抓包", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Theme.accent.opacity(running ? 0.35 : 1))
                            .foregroundColor(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(running || busy)

                    Button {
                        stop()
                    } label: {
                        Label("停止并保存", systemImage: "stop.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(running ? Theme.red.opacity(0.12) : Theme.fill)
                            .foregroundColor(running ? Theme.red : Theme.dim)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(!running || busy)
                }
            }
        }
    }

    // MARK: 文件

    private var filesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle(text: "抓包文件", icon: "doc.zipper")
                    Spacer()
                    Button("刷新") { Task { await refresh() } }
                        .font(.system(size: 11)).foregroundColor(Theme.accent)
                    Button("清理 7 天前") { clean() }
                        .font(.system(size: 11)).foregroundColor(Theme.red)
                }
                if files.isEmpty {
                    Text("还没有抓包文件").font(.system(size: 12)).foregroundColor(Theme.dim)
                }
                ForEach(files) { f in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text).lineLimit(1)
                            Text("\(f.size) · \(f.date)").font(.system(size: 10)).foregroundColor(Theme.dim)
                        }
                        Spacer()
                        Button {
                            download(f)
                        } label: {
                            Image(systemName: "arrow.down.circle").font(.system(size: 19)).foregroundColor(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 3)
                    Divider().background(Theme.line)
                }
            }
        }
    }

    private var tipCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(text: "怎么用", icon: "questionmark.circle")
                Text("1. 选过滤条件（不懂就选「全部流量」）→ 开始抓包\n2. 去手机上操作要抓的 App\n3. 回来点「停止并保存」\n4. 点下载箭头，把 .pcap 存到手机/隔空投送到电脑，用 Wireshark 打开")
                    .font(.system(size: 11)).foregroundColor(Theme.sub)
                Text("HTTPS 内容是加密的，能看域名/IP/流量大小/连接时序；要看明文需要装系统 CA + mitmproxy（需要的话跟我说）")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
            }
        }
    }

    // MARK: 操作

    private func start() {
        guard !busy else { return }
        busy = true
        let name = newName.trimmingCharacters(in: .whitespaces)
        let expr = filterExpr
        Task {
            do {
                var cmd = "sh /data/adb/rc-agent/sniffctl start"
                if !name.isEmpty { cmd += " " + name }
                else { cmd += " sniff_$(date +%H%M%S)" }
                cmd += " any"
                if !expr.isEmpty { cmd += " '" + expr + "'" }
                let r = try await Agent.shared.exec(cmd, timeoutMS: 20000)
                let out = (r.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run { toast = out.isEmpty ? "已开始" : out }
                await refresh()
            } catch {
                await MainActor.run { toast = "启动失败：\(error.localizedDescription)" }
            }
            await MainActor.run { busy = false }
        }
    }

    private func stop() {
        guard !busy else { return }
        busy = true
        Task {
            let r = try? await Agent.shared.exec("sh /data/adb/rc-agent/sniffctl stop", timeoutMS: 20000)
            await MainActor.run { toast = (r?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            await refresh()
            await MainActor.run { busy = false }
        }
    }

    private func clean() {
        Task {
            let r = try? await Agent.shared.exec("sh /data/adb/rc-agent/sniffctl clean 7", timeoutMS: 20000)
            await MainActor.run { toast = (r?.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            await refresh()
        }
    }

    private func download(_ f: SniffFile) {
        Task {
            do {
                let data = try await Agent.shared.fileData(path: f.path)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(f.name)
                try data.write(to: tmp)
                await MainActor.run {
                    shareURL = tmp
                    showShare = true
                }
            } catch {
                await MainActor.run { toast = "下载失败：\(error.localizedDescription)" }
            }
        }
    }

    private func refreshStatusOnly() async {
        if let r = try? await Agent.shared.exec("sh /data/adb/rc-agent/sniffctl status", timeoutMS: 15000) {
            let out = (r.output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                statusText = out.isEmpty ? "空闲" : out
                running = out.contains("运行中")
            }
        }
    }

    private func refresh() async {
        await refreshStatusOnly()
        if let r = try? await Agent.shared.exec("sh /data/adb/rc-agent/sniffctl list 20", timeoutMS: 15000) {
            let out = r.output ?? ""
            var arr: [SniffFile] = []
            for line in out.split(separator: "\n") {
                let s = String(line)
                if s.hasPrefix("目录") || s == "EMPTY" || s.isEmpty { continue }
                let parts = s.components(separatedBy: "|")
                guard parts.count >= 3 else { continue }
                arr.append(SniffFile(size: parts[0], date: parts[1], path: parts[2]))
            }
            await MainActor.run { files = arr }
        }
    }
}

// MARK: - 系统分享

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
