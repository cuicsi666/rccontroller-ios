import SwiftUI

struct TerminalLine: Identifiable {
    let id = UUID()
    let command: String
    let output: String
    let exit: Int
    let date = Date()
}

struct TerminalView: View {
    @EnvironmentObject var app: AppState
    @State private var cmd = ""
    @State private var lines: [TerminalLine] = []
    @State private var running = false
    @FocusState private var focused: Bool

    private let presets: [(String, String)] = [
        ("我是谁", "id"),
        ("设备信息", "getprop ro.product.model; getprop ro.build.version.release"),
        ("电池", "dumpsys battery | head -20"),
        ("已装应用", "pm list packages -3"),
        ("存储", "df -h /data /sdcard"),
        ("网络", "ip addr show wlan0 2>/dev/null | grep inet"),
        ("进程", "ps -A | head -30"),
        ("隧道日志", "tail -n 30 /data/adb/rc-agent/agent.log"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if lines.isEmpty {
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("root 终端")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(Theme.text)
                                    Text("命令以 root（uid 0）身份在安卓手机上执行，等同于 adb shell 的最高权限。")
                                        .font(.system(size: 12))
                                        .foregroundColor(Theme.sub)
                                    HStack(spacing: 6) {
                                        TagView(text: "uid \(app.deviceInfo?.uid ?? -1)")
                                        if app.deviceInfo?.root == true { TagView(text: "SU 可用") }
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                        }
                        ForEach(lines) { line in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("$")
                                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundColor(Theme.accent)
                                    Text(line.command)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(Theme.text)
                                        .textSelection(.enabled)
                                    Spacer()
                                    Text("exit \(line.exit)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(line.exit == 0 ? Theme.dim : Theme.red)
                                }
                                Text(line.output.isEmpty ? "(无输出)" : line.output)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(Theme.sub)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(12)
                            .background(Theme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .padding(.horizontal, 12)
                            .id(line.id)
                        }
                        Color.clear.frame(height: 8).id("bottom")
                    }
                    .padding(.vertical, 12)
                }
                .onChange(of: lines.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(presets, id: \.0) { item in
                        Button(item.0) {
                            run(item.1)
                        }
                        .font(.system(size: 12))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.card)
                        .foregroundColor(Theme.sub)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            HStack(spacing: 8) {
                TextField("输入 shell 命令…", text: $cmd)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Theme.card)
                    .foregroundColor(Theme.text)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onSubmit { run(cmd) }
                Button {
                    run(cmd)
                } label: {
                    Image(systemName: running ? "hourglass" : "arrow.up")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 44, height: 42)
                        .background(Theme.accent)
                        .foregroundColor(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .disabled(running)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .background(Theme.bg.ignoresSafeArea())
    }

    private func run(_ command: String) {
        let c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty, !running else { return }
        running = true
        cmd = ""
        focused = false
        Task {
            defer { running = false }
            do {
                let r = try await Agent.shared.exec(c, timeoutMS: 60000)
                lines.append(TerminalLine(command: c, output: r.output ?? "", exit: r.exit ?? 0))
            } catch {
                lines.append(TerminalLine(command: c, output: "错误：\(app.friendly(error))", exit: -1))
            }
        }
    }
}
