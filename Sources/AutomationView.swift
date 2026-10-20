import SwiftUI

// MARK: - 宏（一键脚本）

struct Macro: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var script: String
}

struct MacrosView: View {
    @Environment(\.dismiss) var dismiss
    @State private var macros: [Macro] = []
    @State private var editing: Macro?
    @State private var running = false
    @State private var log: [String] = []
    @State private var toast: String?

    private let presets: [Macro] = [
        Macro(name: "唤醒 + 回主页", script: "key wake\nwait 400\nkey home"),
        Macro(name: "B站搜「丝袜」看第一个", script: "launch tv.danmaku.bili\nwait 3500\ntap 743 234\nwait 1200\ntext 丝袜\nkey enter\nwait 3000\ntap 720 570"),
        Macro(name: "清理后台", script: "key recents\nwait 800\nswipe 720 2400 720 600 300")
    ]

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("我的宏")) {
                    if macros.isEmpty {
                        Text("还没有宏，点右上角 + 新建，或从下面导入模板").font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                    ForEach(macros) { m in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(m.name).font(.system(size: 13, weight: .semibold))
                                Text(m.script.replacingOccurrences(of: "\n", with: " → "))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Theme.dim).lineLimit(1)
                            }
                            Spacer()
                            Button("运行") { run(m) }
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Theme.accent)
                                .disabled(running)
                        }
                        .contextMenu {
                            Button("编辑") { editing = m }
                            Button("删除", role: .destructive) { delete(m) }
                        }
                    }
                }
                Section(header: Text("模板")) {
                    ForEach(presets) { p in
                        Button {
                            macros.append(p)
                            save()
                        } label: {
                            Label(p.name, systemImage: "square.and.arrow.down")
                                .font(.system(size: 12))
                        }
                    }
                }
                if !log.isEmpty {
                    Section(header: Text("运行日志")) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.sub)
                        }
                    }
                }
            }
            .navigationTitle("宏 / 一键脚本")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        editing = Macro(name: "新宏", script: "key wake")
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { m in
                MacroEditor(macro: m) { saved in
                    if let i = macros.firstIndex(where: { $0.id == saved.id }) {
                        macros[i] = saved
                    } else {
                        macros.append(saved)
                    }
                    save()
                }
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.8)).foregroundColor(.white)
                        .clipShape(Capsule()).padding(.bottom, 20)
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        if let d = UserDefaults.standard.data(forKey: "rc.macros"),
           let arr = try? JSONDecoder().decode([Macro].self, from: d) {
            macros = arr
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(macros) {
            UserDefaults.standard.set(d, forKey: "rc.macros")
        }
    }

    private func delete(_ m: Macro) {
        macros.removeAll { $0.id == m.id }
        save()
    }

    private func run(_ m: Macro) {
        guard !running else { return }
        running = true
        log = ["▶ \(m.name)"]
        Task {
            let lines = m.script.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            for line in lines where !line.isEmpty && !line.hasPrefix("#") {
                let parts = line.split(separator: " ").map(String.init)
                guard let cmd = parts.first else { continue }
                do {
                    switch cmd {
                    case "wait":
                        let ms = Int(parts.count > 1 ? parts[1] : "500") ?? 500
                        try? await Task.sleep(nanoseconds: UInt64(max(ms, 0)) * 1_000_000)
                    case "tap":
                        if parts.count >= 3, let x = Int(parts[1]), let y = Int(parts[2]) {
                            try await Agent.shared.tap(x: x, y: y)
                        }
                    case "longpress":
                        if parts.count >= 3, let x = Int(parts[1]), let y = Int(parts[2]) {
                            try await Agent.shared.longPress(x: x, y: y, ms: parts.count > 3 ? (Int(parts[3]) ?? 800) : 800)
                        }
                    case "swipe":
                        if parts.count >= 5, let x1 = Int(parts[1]), let y1 = Int(parts[2]), let x2 = Int(parts[3]), let y2 = Int(parts[4]) {
                            try await Agent.shared.swipe(x1: x1, y1: y1, x2: x2, y2: y2, ms: parts.count > 5 ? (Int(parts[5]) ?? 300) : 300)
                        }
                    case "text":
                        let t = parts.dropFirst().joined(separator: " ")
                        _ = try await Agent.shared.text(t)
                    case "key":
                        if parts.count > 1 { try await Agent.shared.key(parts[1]) }
                    case "launch":
                        if parts.count > 1 { try await Agent.shared.launch(parts[1]) }
                    case "pinch":
                        if parts.count >= 5, let cx = Int(parts[1]), let cy = Int(parts[2]), let d1 = Int(parts[3]), let d2 = Int(parts[4]) {
                            try await Agent.shared.pinch(cx: cx, cy: cy, from: d1, to: d2, ms: 320)
                        }
                    case "exec":
                        let c = parts.dropFirst().joined(separator: " ")
                        _ = try await Agent.shared.exec(c)
                    default:
                        await MainActor.run { log.append("跳过未知指令: \(line)") }
                        continue
                    }
                    await MainActor.run { log.append("✓ \(line)") }
                } catch {
                    await MainActor.run { log.append("✗ \(line) → \(error.localizedDescription)") }
                }
            }
            await MainActor.run {
                running = false
                toast = "宏执行完成"
            }
        }
    }
}

struct MacroEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var macro: Macro
    var onSave: (Macro) -> Void

    var body: some View {
        NavigationView {
            VStack(alignment: .leading, spacing: 10) {
                TextField("宏名称", text: $macro.name)
                    .textFieldStyle(.plain).padding(12)
                    .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 10))
                Text("每行一条指令：tap x y / swipe x1 y1 x2 y2 ms / key home / text 内容 / launch 包名 / wait 毫秒 / pinch cx cy d1 d2 / exec 命令")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
                TextEditor(text: $macro.script)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(14)
            .navigationTitle("编辑宏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(macro)
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 定时任务

struct ScheduledTask: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var time: String = "23:00"
    var days: String = ""
    var action: String = "lock"
    var arg: String = ""
    var enabled: Bool = true
    var last_run: String?
}

struct ScheduleView: View {
    @Environment(\.dismiss) var dismiss
    @State private var tasks: [ScheduledTask] = []
    @State private var loading = false
    @State private var error: String?
    @State private var toast: String?
    @State private var editing: ScheduledTask?

    private let actions = [("lock", "锁屏"), ("wake", "唤醒"), ("screenshot", "截图"), ("open", "打开应用"), ("exec", "执行命令")]

    var body: some View {
        NavigationView {
            List {
                if let e = error {
                    Text(e).font(.system(size: 11)).foregroundColor(Theme.red)
                }
                Section(header: Text("手机端定时任务（守护进程执行，关掉 App 也会跑）")) {
                    if tasks.isEmpty {
                        Text("暂无任务").font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                    ForEach(tasks) { t in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(t.time)  \(actionName(t.action))\(t.arg.isEmpty ? "" : " · \(t.arg)")")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(t.days.isEmpty ? "每天" : "周 \(t.days)")
                                    .font(.system(size: 10)).foregroundColor(Theme.dim)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { t.enabled },
                                set: { v in
                                    var copy = t
                                    copy.enabled = v
                                    replace(copy)
                                }))
                            .labelsHidden()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                tasks.removeAll { $0.id == t.id }
                                push()
                            } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
            }
            .navigationTitle("定时任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { editing = ScheduledTask() } label: { Image(systemName: "plus") }
                }
            }
            .sheet(item: $editing) { t in
                ScheduleEditor(task: t, actions: actions) { saved in
                    replace(saved)
                }
            }
            .overlay(alignment: .bottom) {
                if let t = toast {
                    Text(t).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Color.black.opacity(0.8)).foregroundColor(.white)
                        .clipShape(Capsule()).padding(.bottom, 20)
                }
            }
        }
        .task { await load() }
    }

    private func actionName(_ a: String) -> String {
        actions.first { $0.0 == a }?.1 ?? a
    }

    private func replace(_ t: ScheduledTask) {
        if let i = tasks.firstIndex(where: { $0.id == t.id }) { tasks[i] = t } else { tasks.append(t) }
        push()
    }

    private func load() async {
        do {
            let obj = try await Agent.shared.raw("/api/schedule")
            if let d = obj["data"] as? [String: Any], let arr = d["tasks"] {
                let data = try JSONSerialization.data(withJSONObject: arr)
                tasks = (try? JSONDecoder().decode([ScheduledTask].self, from: data)) ?? []
            }
            error = nil
        } catch { self.error = "读取失败：\(error.localizedDescription)" }
    }

    private func push() {
        Task {
            do {
                let data = try JSONEncoder().encode(tasks)
                let obj = try JSONSerialization.jsonObject(with: data)
                _ = try await Agent.shared.raw("/api/schedule", method: "POST", json: ["tasks": obj])
                toast = "已保存"
            } catch { toast = "保存失败：\(error.localizedDescription)" }
        }
    }
}

struct ScheduleEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var task: ScheduledTask
    var actions: [(String, String)]
    var onSave: (ScheduledTask) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("时间") {
                    TextField("HH:MM", text: $task.time)
                }
                Section("星期（留空=每天）") {
                    TextField("例：12345 表示周一到周五", text: $task.days)
                }
                Section("动作") {
                    Picker("动作", selection: $task.action) {
                        ForEach(actions, id: \.0) { a in Text(a.1).tag(a.0) }
                    }
                    TextField("参数（包名 / 命令）", text: $task.arg)
                }
            }
            .navigationTitle("新建任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(task)
                        dismiss()
                    }
                }
            }
        }
    }
}
