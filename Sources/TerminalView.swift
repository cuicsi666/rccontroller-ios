import SwiftUI
import UIKit

struct TerminalLine: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let exit: Int
    let at = Date()
}

struct TerminalView: View {
    @EnvironmentObject var app: AppState
    @State private var cmd = ""
    @State private var lines: [TerminalLine] = []
    @State private var running = false
    @State private var filter = ""
    @State private var showFilter = false
    @State private var showHistory = false
    @State private var showScript = false
    @State private var script = ""
    @State private var asShell = false
    @State private var history: [String] = UserDefaults.standard.stringArray(forKey: "rc.history") ?? []
    @State private var favorites: [String] = UserDefaults.standard.stringArray(forKey: "rc.favs") ?? ["id", "df -h /data", "dumpsys battery | head", "pm list packages -3"]
    @State private var exported: String?
    @State private var showShare = false
    @State private var toast: String?
    @State private var bgRunning = 0
    @FocusState private var focused: Bool

    private let presets: [PresetItem] = [
        PresetItem(id: "设备信息", label: "设备信息", value: "getprop ro.product.model; getprop ro.build.version.release"),
        PresetItem(id: "电池", label: "电池", value: "dumpsys battery | head -20"),
        PresetItem(id: "已装应用", label: "已装应用", value: "pm list packages -3"),
        PresetItem(id: "存储", label: "存储", value: "df -h /data /storage/emulated/0"),
        PresetItem(id: "网络", label: "网络", value: "ip -4 addr show | grep inet"),
        PresetItem(id: "进程", label: "进程", value: "ps -A -o PID,NAME,RSS | head -20"),
        PresetItem(id: "隧道日志", label: "隧道日志", value: "tail -n 30 /data/adb/rc-agent/agent.log"),
        PresetItem(id: "唤醒屏幕", label: "唤醒屏幕", value: "input keyevent 224")
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if showFilter {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle").foregroundColor(Theme.dim)
                    TextField("过滤输出内容…", text: $filter)
                        .font(.system(size: 12)).textFieldStyle(.plain)
                        .autocapitalization(.none)
                    if !filter.isEmpty {
                        Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(Theme.dim) }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Theme.fill)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if lines.isEmpty { emptyCard }
                        ForEach(filteredLines) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("$").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(Theme.accent)
                                    Text(line.command)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(Theme.text).textSelection(.enabled)
                                    Spacer()
                                    Text("exit \(line.exit)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(line.exit == 0 ? Theme.dim : Theme.red)
                                    Menu {
                                        Button("复制输出") { UIPasteboard.general.string = line.output; flash("已复制") }
                                        Button("复制命令") { UIPasteboard.general.string = line.command; flash("已复制") }
                                        Button("收藏命令") { addFavorite(line.command) }
                                        Button("再次执行") { run(line.command) }
                                    } label: {
                                        Image(systemName: "ellipsis.circle").font(.system(size: 14)).foregroundColor(Theme.dim)
                                    }
                                }
                                Text(line.output.isEmpty ? "(无输出)" : line.output)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(Theme.sub)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
                            .padding(.horizontal, 12)
                            .id(line.id)
                        }
                        Color.clear.frame(height: 6).id("bottom")
                    }
                    .padding(.vertical, 10)
                }
                .onChange(of: lines.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            quickBar
            inputBar
        }
        .background(Theme.bg.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.8)).foregroundColor(.white)
                    .clipShape(Capsule()).padding(.bottom, 70)
            }
        }
        .sheet(isPresented: $showHistory) { historySheet }
        .sheet(isPresented: $showScript) { scriptSheet }
        .sheet(isPresented: $showShare) { shareSheet }
    }

    private var filteredLines: [TerminalLine] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !f.isEmpty else { return lines }
        return lines.filter { $0.command.lowercased().contains(f) || $0.output.lowercased().contains(f) }
    }

    private var emptyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("root 终端").font(.system(size: 15, weight: .bold)).foregroundColor(Theme.text)
                Text("命令以 uid 0 在安卓手机上执行，等同 adb shell 的最高权限。切到「shell」时以普通 shell 用户执行（su 2000）。")
                    .font(.system(size: 12)).foregroundColor(Theme.sub)
                HStack(spacing: 6) {
                    TagView(text: "uid \(app.deviceInfo?.uid ?? -1)")
                    if app.deviceInfo?.root == true { TagView(text: "SU 可用") }
                    TagView(text: asShell ? "shell 身份" : "root 身份", color: asShell ? Theme.orange : Theme.accent)
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Button { showFilter.toggle() } label: { toolIcon("line.3.horizontal.decrease.circle", "过滤", showFilter) }
            Button { showHistory = true } label: { toolIcon("clock.arrow.circlepath", "历史", false) }
            Button { showScript = true } label: { toolIcon("text.alignleft", "脚本", false) }
            Button { exportLog() } label: { toolIcon("square.and.arrow.up", "导出", false) }
            Button { withAnimation { lines.removeAll() } ; flash("已清屏") } label: { toolIcon("trash", "清屏", false) }
            Spacer()
            Menu {
                Button { asShell = false } label: { Label("root（默认）", systemImage: asShell ? "" : "checkmark") }
                Button { asShell = true } label: { Label("shell 普通用户", systemImage: asShell ? "checkmark" : "") }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "person.badge.key").font(.system(size: 12))
                    Text(asShell ? "shell" : "root").font(.system(size: 11, weight: .semibold))
                }
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background((asShell ? Theme.orange : Theme.accent).opacity(0.12))
                .foregroundColor(asShell ? Theme.orange : Theme.accent)
                .clipShape(Capsule())
            }
            if bgRunning > 0 { ProgressView().scaleEffect(0.6) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.line), alignment: .bottom)
    }

    private func toolIcon(_ icon: String, _ title: String, _ active: Bool) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon).font(.system(size: 15))
            Text(title).font(.system(size: 9))
        }
        .foregroundColor(active ? Theme.accent : Theme.sub)
    }

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(favorites, id: \.self) { f in
                    Button(f) { run(f) }
                        .font(.system(size: 11))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.09))
                        .foregroundColor(Theme.accent)
                        .clipShape(Capsule())
                        .contextMenu {
                            Button("移除收藏", role: .destructive) { removeFavorite(f) }
                        }
                }
                ForEach(presets) { p in
                    Button(p.label) { run(p.value) }
                        .font(.system(size: 11))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(Theme.card)
                        .foregroundColor(Theme.sub)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("输入 shell 命令…", text: $cmd)
                .font(.system(size: 13, design: .monospaced))
                .textFieldStyle(.plain)
                .autocapitalization(.none).disableAutocorrection(true)
                .focused($focused)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(Theme.card)
                .foregroundColor(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                .onSubmit { run(cmd) }
            Button { run(cmd) } label: {
                Image(systemName: running ? "hourglass" : "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 42, height: 40)
                    .background(Theme.accent).foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(running)
        }
        .padding(.horizontal, 12).padding(.bottom, 8)
    }

    // MARK: 执行

    private func run(_ command: String, background: Bool = false) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return }
        if !background && running { return }
        cmd = ""
        focused = false
        addHistory(c)
        let real = asShell ? "su 2000 -c \(shellQuote(c))" : c
        if background {
            bgRunning += 1
            Task {
                defer { bgRunning -= 1 }
                do {
                    let r = try await Agent.shared.exec(real, timeoutMS: 300000)
                    await MainActor.run {
                        lines.append(TerminalLine(command: "（后台）" + c, output: r.output ?? "", exit: r.exit ?? 0))
                        notifyDone(c, ok: (r.exit ?? 0) == 0)
                    }
                } catch {
                    await MainActor.run { flash(app.friendly(error)) }
                }
            }
            flash("已转后台执行")
            return
        }
        running = true
        Task {
            defer { running = false }
            do {
                let r = try await Agent.shared.exec(real, timeoutMS: 60000)
                await MainActor.run {
                    lines.append(TerminalLine(command: c, output: r.output ?? "", exit: r.exit ?? 0))
                }
            } catch {
                await MainActor.run {
                    lines.append(TerminalLine(command: c, output: "错误：\(app.friendly(error))", exit: -1))
                }
            }
        }
    }

    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func notifyDone(_ cmd: String, ok: Bool) {
        flash(ok ? "后台任务完成" : "后台任务失败")
    }

    private func addHistory(_ c: String) {
        history.removeAll { $0 == c }
        history.insert(c, at: 0)
        if history.count > 100 { history = Array(history.prefix(100)) }
        UserDefaults.standard.set(history, forKey: "rc.history")
    }

    private func addFavorite(_ c: String) {
        guard !favorites.contains(c) else { return }
        favorites.append(c)
        UserDefaults.standard.set(favorites, forKey: "rc.favs")
        flash("已收藏")
    }

    private func removeFavorite(_ c: String) {
        favorites.removeAll { $0 == c }
        UserDefaults.standard.set(favorites, forKey: "rc.favs")
    }

    private func exportLog() {
        let text = lines.map { "$ \($0.command)\n\($0.output)" }.joined(separator: "\n\n")
        exported = text.isEmpty ? "（无内容）" : text
        showShare = true
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if toast == msg { toast = nil } }
        }
    }

    // MARK: 弹窗

    private var historySheet: some View {
        NavigationView {
            List {
                Section("历史命令") {
                    if history.isEmpty { Text("暂无历史").foregroundColor(Theme.dim) }
                    ForEach(history, id: \.self) { h in
                        Button {
                            showHistory = false
                            run(h)
                        } label: {
                            Text(h).font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.text)
                        }
                    }
                }
            }
            .navigationTitle("命令历史")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("清空") { history.removeAll(); UserDefaults.standard.set([], forKey: "rc.history") }
                }
                ToolbarItem(placement: .confirmationAction) { Button("关闭") { showHistory = false } }
            }
        }
    }

    private var scriptSheet: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 10) {
                Text("多行脚本（逐行执行，遇到非 0 退出码继续）")
                    .font(.system(size: 12)).foregroundColor(Theme.sub)
                TextEditor(text: $script)
                    .font(.system(size: 13, design: .monospaced))
                    .padding(8)
                    .background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .frame(minHeight: 220)
                Spacer()
            }
            .padding(14)
            .navigationTitle("脚本模式")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showScript = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("执行") {
                        let s = script
                        showScript = false
                        run(s)
                    }
                }
            }
        }
    }

    private var shareSheet: some View {
        ShareSheet(items: [exported ?? ""])
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    var items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
