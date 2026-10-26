import SwiftUI
import Foundation

// MARK: - 自动化任务（宏 + 定时，统一存在手机端）

struct AutoTask: Identifiable, Equatable {
    var id: String
    var name: String
    var time: String          // "" = 仅手动
    var days: String          // 留空=每天；"12345" = 周一到周五
    var enabled: Bool
    var lastRun: String
    var lastStatus: String
    var script: String

    var hasSchedule: Bool { !time.trimmingCharacters(in: .whitespaces).isEmpty }
}

extension Agent {

    /// 读取手机端任务列表（/data/adb/rc-agent/tasksd.sh list）
    func autoTasks() async throws -> [AutoTask] {
        let r = try await exec("sh /data/adb/rc-agent/tasksd.sh list", timeoutMS: 20000)
        let out = r.output ?? ""
        var list: [AutoTask] = []
        for line in out.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 7 else { continue }
            let id = String(f[0])
            guard !id.isEmpty else { continue }
            var name = id
            if let d = Data(base64Encoded: f[1]), let s = String(data: d, encoding: .utf8), !s.isEmpty {
                name = s
            }
            list.append(AutoTask(
                id: id,
                name: name,
                time: f[2],
                days: f[3],
                enabled: f[4] == "1",
                lastRun: f[5],
                lastStatus: f[6],
                script: ""
            ))
        }
        return list
    }

    func autoTaskScript(_ id: String) async throws -> String {
        let r = try await exec("cat /data/adb/rc-agent/tasks/\(id).sh 2>/dev/null", timeoutMS: 15000)
        return r.output ?? ""
    }

    func saveAutoTask(_ t: AutoTask) async throws {
        let nameB64 = Data(t.name.utf8).base64EncodedString()
        let scriptB64 = Data(t.script.utf8).base64EncodedString()
        let time = t.time.trimmingCharacters(in: .whitespaces)
        let days = t.days.trimmingCharacters(in: .whitespaces)
        let cmd = "sh /data/adb/rc-agent/tasksd.sh save \(t.id) \(nameB64) '\(time)' '\(days)' \(t.enabled ? "1" : "0") \(scriptB64)"
        let r = try await exec(cmd, timeoutMS: 25000)
        if let o = r.output, o.contains("失败") { throw AgentError.server(o) }
    }

    func deleteAutoTask(_ id: String) async throws {
        _ = try await exec("sh /data/adb/rc-agent/tasksd.sh delete \(id)", timeoutMS: 15000)
    }

    /// 立即执行，返回执行日志
    func runAutoTask(_ id: String) async throws -> String {
        let r = try await exec("sh /data/adb/rc-agent/tasksd.sh run \(id)", timeoutMS: 180000)
        return r.output ?? ""
    }

    func autoTaskLog(_ id: String) async throws -> String {
        let r = try await exec("sh /data/adb/rc-agent/tasksd.sh log \(id) 100", timeoutMS: 15000)
        return r.output ?? ""
    }
}

// MARK: - 任务状态仓库

final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published var tasks: [AutoTask] = []
    @Published var runningId: String?
    @Published var logTask: AutoTask?
    @Published var logText: String = ""
    @Published var loading = false
    @Published var error: String?

    private var lastRefresh = Date.distantPast

    func refresh(force: Bool = false) async {
        if !force && Date().timeIntervalSince(lastRefresh) < 3 { return }
        lastRefresh = Date()
        do {
            let list = try await Agent.shared.autoTasks()
            await MainActor.run {
                self.tasks = list
                self.error = nil
            }
        } catch {
            await MainActor.run { self.error = "读取任务失败：\(error.localizedDescription)" }
        }
    }

    func run(_ t: AutoTask) {
        guard runningId == nil else { return }
        runningId = t.id
        logText = ""
        Task {
            var text = ""
            do {
                text = try await Agent.shared.runAutoTask(t.id)
            } catch {
                text = "执行失败：\(error.localizedDescription)"
            }
            await MainActor.run {
                self.runningId = nil
                self.logText = text
                self.logTask = t
            }
            await refresh(force: true)
        }
    }

    func runScript(_ id: String) { if let t = tasks.first(where: { $0.id == id }) { run(t) } }

    func save(_ t: AutoTask) {
        Task {
            do {
                try await Agent.shared.saveAutoTask(t)
                await refresh(force: true)
            } catch {
                await MainActor.run { self.error = "保存失败：\(error.localizedDescription)" }
            }
        }
    }

    func delete(_ t: AutoTask) {
        Task {
            try? await Agent.shared.deleteAutoTask(t.id)
            await refresh(force: true)
        }
    }
}

// MARK: - 主页面任务条

struct AutoBar: View {
    @EnvironmentObject var app: AppState
    @StateObject private var store = TaskStore.shared
    @State private var showManager = false
    @State private var editing: AutoTask?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.tasks) { t in
                        taskPill(t)
                    }
                    Button { showManager = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 11, weight: .semibold))
                            Text("管理").font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Theme.fill)
                        .foregroundColor(Theme.sub)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
            }
            Divider().background(Theme.line)
        }
        .background(Theme.card)
        .task {
            await store.refresh(force: true)
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        .sheet(isPresented: $showManager) {
            TasksView()
                .environmentObject(app)
                .environmentObject(store)
        }
        .sheet(item: $store.logTask) { t in
            TaskLogSheet(task: t, text: store.logText)
        }
        .sheet(item: $editing) { e in
            TaskEditor(task: e) { saved in store.save(saved) }
        }
    }

    private func taskPill(_ t: AutoTask) -> some View {
        let running = store.runningId == t.id
        return Button {
            store.run(t)
        } label: {
            HStack(spacing: 6) {
                if running {
                    ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                } else {
                    Image(systemName: t.hasSchedule ? "clock.fill" : "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(t.enabled ? Theme.accent : Theme.dim)
                }
                Text(t.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(running ? Theme.accent : Theme.text)
                    .lineLimit(1)
                if t.hasSchedule && !running {
                    Text(t.time)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(Theme.dim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(running ? Theme.accent.opacity(0.14) : Theme.fill)
            .overlay(Capsule().stroke(running ? Theme.accent.opacity(0.4) : Theme.line, lineWidth: 1))
            .clipShape(Capsule())
        }
        .disabled(store.runningId != nil && !running)
        .contextMenu {
            Button("运行") { store.run(t) }
            Button("查看日志") {
                Task {
                    let log = (try? await Agent.shared.autoTaskLog(t.id)) ?? ""
                    await MainActor.run {
                        store.logText = log.isEmpty ? "暂无日志" : log
                        store.logTask = t
                    }
                }
            }
            Button("编辑") { editing = t }
            Button("删除", role: .destructive) { store.delete(t) }
        }
    }
}

// MARK: - 运行日志

struct TaskLogSheet: View {
    @Environment(\.dismiss) var dismiss
    var task: AutoTask
    var text: String

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(text.split(separator: "\n").enumerated()), id: \.offset) { _, l in
                        Text(String(l))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(String(l).hasPrefix("✓") ? Theme.green :
                                             String(l).hasPrefix("✗") ? Theme.red : Theme.sub)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if text.isEmpty {
                        Text("暂无输出").font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                }
                .padding(14)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("\(task.name) · 执行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() } }
            }
        }
    }
}

// MARK: - 管理页（宏 + 定时合一）

struct TasksView: View {
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var app: AppState
    @StateObject private var store = TaskStore.shared
    @State private var editing: AutoTask?
    @State private var creating = false

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("任务（点击名称编辑，右滑删除）")) {
                    if store.tasks.isEmpty {
                        Text("还没有任务，点右上角 + 新建。\n脚本指令：launch 包名 / tap x y / swipe x1 y1 x2 y2 ms / key home / text 文字 / wait 毫秒 / shell 命令")
                            .font(.system(size: 12)).foregroundColor(Theme.dim)
                    }
                    ForEach(store.tasks) { t in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(t.name).font(.system(size: 13, weight: .semibold))
                                HStack(spacing: 6) {
                                    Text(t.hasSchedule ? "定时 \(t.time)" : "仅手动")
                                        .font(.system(size: 10)).foregroundColor(Theme.dim)
                                    if !t.days.isEmpty {
                                        Text("周 \(t.days)").font(.system(size: 10)).foregroundColor(Theme.dim)
                                    }
                                    if !t.lastRun.isEmpty {
                                        Text("上次 \(t.lastRun)").font(.system(size: 9)).foregroundColor(Theme.dim)
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                store.run(t)
                            } label: {
                                Image(systemName: store.runningId == t.id ? "hourglass" : "play.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(store.runningId == nil ? Theme.accent : Theme.dim)
                            }
                            .buttonStyle(.plain)
                            Toggle("", isOn: Binding(
                                get: { t.enabled },
                                set: { v in
                                    var c = t
                                    c.enabled = v
                                    loadScriptThenSave(c)
                                }))
                            .labelsHidden()
                            .scaleEffect(0.8)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { editTask(t) }
                        .swipeActions {
                            Button(role: .destructive) { store.delete(t) } label: { Label("删除", systemImage: "trash") }
                        }
                    }
                }
                if let e = store.error {
                    Section { Text(e).font(.system(size: 11)).foregroundColor(Theme.red) }
                }
                Section(header: Text("说明")) {
                    Text("任务保存在手机 /data/adb/rc-agent/tasks/，由手机端 tasksd.sh 每 20 秒检查定时并执行；App 关掉也会跑。也可远程添加：sh tasksd.sh save ...")
                        .font(.system(size: 10)).foregroundColor(Theme.dim)
                }
            }
            .navigationTitle("自动化任务")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $creating) {
                TaskEditor(task: AutoTask(id: UUID().uuidString.prefix(8).lowercased(), name: "", time: "", days: "", enabled: true, lastRun: "", lastStatus: "", script: "key wake\nwait 400\nlaunch tv.danmaku.bili")) { saved in
                    store.save(saved)
                }
            }
            .sheet(item: $editing) { t in
                TaskEditor(task: t) { saved in store.save(saved) }
            }
            .overlay(alignment: .bottom) {
                if store.runningId != nil {
                    HStack(spacing: 8) {
                        ProgressView().scaleEffect(0.7)
                        Text("正在手机端执行…").font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Color.black.opacity(0.82)).foregroundColor(.white)
                    .clipShape(Capsule()).padding(.bottom, 18)
                }
            }
        }
        .task { await store.refresh(force: true) }
    }

    private func editTask(_ t: AutoTask) {
        Task {
            var c = t
            c.script = (try? await Agent.shared.autoTaskScript(t.id)) ?? ""
            await MainActor.run { editing = c }
        }
    }

    private func loadScriptThenSave(_ t: AutoTask) {
        Task {
            var c = t
            if c.script.isEmpty {
                c.script = (try? await Agent.shared.autoTaskScript(t.id)) ?? ""
            }
            store.save(c)
        }
    }
}

// MARK: - 任务编辑

struct TaskEditor: View {
    @Environment(\.dismiss) var dismiss
    @State var task: AutoTask
    var onSave: (AutoTask) -> Void

    var body: some View {
        NavigationView {
            Form {
                Section("名称 / 触发") {
                    TextField("任务名称", text: $task.name)
                    HStack {
                        Text("定时")
                        Spacer()
                        TextField("留空=仅手动 (HH:MM)", text: $task.time)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    TextField("星期（留空=每天，12345=周一至周五）", text: $task.days)
                    Toggle("启用（定时生效）", isOn: $task.enabled)
                }
                Section(header: Text("脚本（每行一条）")) {
                    TextEditor(text: $task.script)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 220)
                }
                Section(footer: Text("指令：launch 包名 / tap x y / swipe x1 y1 x2 y2 ms / key home|back|enter|wake / text 文字 / wait 毫秒 / shell 命令")) {
                    EmptyView()
                }
            }
            .navigationTitle(task.name.isEmpty ? "新建任务" : "编辑任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        var c = task
                        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { c.name = "未命名任务" }
                        onSave(c)
                        dismiss()
                    }
                }
            }
        }
    }
}
