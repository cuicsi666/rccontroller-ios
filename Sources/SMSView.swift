import SwiftUI
import UIKit
import UserNotifications

// MARK: - 短信同步

@MainActor
final class SMSStore: ObservableObject {
    @Published var messages: [SMSMessage] = []
    @Published var unread = 0
    @Published var lastError: String?
    @Published var lastSync: Date?

    private var loopTask: Task<Void, Never>?
    private var seen = Set<Int64>()
    private var started = false
    private var notified = Set<Int64>()

    func start() {
        guard !started else { return }
        started = true
        requestAuth()
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(nanoseconds: 8_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        started = false
    }

    func markAllRead() { unread = 0 }

    func refresh() async {
        do {
            let list = try await Agent.shared.sms(limit: 100, sinceID: 0)
            let incoming = list.filter { $0.isInbox }
            var newOnes: [SMSMessage] = []
            for m in incoming where !seen.contains(m.id) {
                if !seen.isEmpty { newOnes.append(m) }
            }
            for m in incoming { seen.insert(m.id) }
            messages = list.sorted { $0.id > $1.id }
            lastSync = Date()
            lastError = nil
            if !newOnes.isEmpty {
                unread += newOnes.filter { $0.read == 0 }.count
                for m in newOnes.prefix(3) where !notified.contains(m.id) {
                    notified.insert(m.id)
                    notify(m)
                }
            }
        } catch {
            if let e = error as? AgentError, let d = e.errorDescription {
                lastError = d
            } else {
                lastError = error.localizedDescription
            }
        }
    }

    private func requestAuth() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func notify(_ m: SMSMessage) {
        let content = UNMutableNotificationContent()
        content.title = "新短信 · \(m.address)"
        content.body = m.body.prefix(120).description
        content.sound = .default
        let req = UNNotificationRequest(identifier: "sms-\(m.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}

// MARK: - 短信页

struct SMSView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: SMSStore
    @State private var search = ""
    @State private var selected: SMSMessage?
    @State private var onlyUnread = false
    @State private var toast: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = store.lastError {
                Text(e).font(.system(size: 11)).foregroundColor(Theme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.orange.opacity(0.08))
            }
            List {
                ForEach(filtered) { m in
                    Button { selected = m } label: {
                        row(m)
                    }
                    .listRowBackground(Theme.card)
                    .swipeActions(edge: .trailing) {
                        Button {
                            UIPasteboard.general.string = m.body
                            flash("已复制")
                        } label: { Label("复制", systemImage: "doc.on.doc") }
                        .tint(Theme.blue)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await store.refresh() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task {
            await store.refresh()
            store.markAllRead()
        }
        .sheet(item: $selected) { m in detail(m) }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.black.opacity(0.8)).foregroundColor(.white)
                    .clipShape(Capsule()).padding(.bottom, 16)
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundColor(Theme.dim)
                    TextField("搜索号码或内容…", text: $search)
                        .font(.system(size: 12)).textFieldStyle(.plain)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 9))

                Button {
                    onlyUnread.toggle()
                } label: {
                    Image(systemName: onlyUnread ? "envelope.badge.fill" : "envelope")
                        .font(.system(size: 14))
                        .frame(width: 34, height: 34)
                        .background(onlyUnread ? Theme.accent.opacity(0.12) : Theme.card)
                        .foregroundColor(onlyUnread ? Theme.accent : Theme.sub)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            HStack {
                Text("共 \(store.messages.count) 条 · 未读 \(store.messages.filter { $0.isInbox && $0.read == 0 }.count)")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
                Spacer()
                if let d = store.lastSync {
                    Text("同步于 " + d.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10)).foregroundColor(Theme.dim)
                }
                Button {
                    Task { await store.refresh(); flash("已刷新") }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).foregroundColor(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.line), alignment: .bottom)
    }

    private var filtered: [SMSMessage] {
        var list = store.messages
        if onlyUnread { list = list.filter { $0.isInbox && $0.read == 0 } }
        let s = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !s.isEmpty {
            list = list.filter { $0.address.lowercased().contains(s) || $0.body.lowercased().contains(s) }
        }
        return list
    }

    private func row(_ m: SMSMessage) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(m.address)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                if m.read == 0 && m.isInbox {
                    Circle().fill(Theme.red).frame(width: 6, height: 6)
                }
                Spacer()
                Text(m.dateValue.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
            }
            Text(m.body)
                .font(.system(size: 12))
                .foregroundColor(Theme.sub)
                .lineLimit(2)
            HStack(spacing: 6) {
                TagView(text: typeName(m.type), color: m.isInbox ? Theme.blue : Theme.dim)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func typeName(_ t: Int) -> String {
        switch t {
        case 1: return "收件"
        case 2: return "已发送"
        case 3: return "草稿"
        case 4: return "发件箱"
        case 5: return "失败"
        default: return "其他"
        }
    }

    private func detail(_ m: SMSMessage) -> some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.address).font(.system(size: 18, weight: .bold)).foregroundColor(Theme.text)
                        Text(m.dateValue.formatted(date: .long, time: .standard))
                            .font(.system(size: 11)).foregroundColor(Theme.dim)
                    }
                    Text(m.body)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.text)
                        .textSelection(.enabled)
                    HStack(spacing: 10) {
                        Button {
                            UIPasteboard.general.string = m.body
                            flash("已复制")
                        } label: {
                            Label("复制内容", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity).padding(.vertical, 11)
                                .background(Theme.accent.opacity(0.1)).foregroundColor(Theme.accent)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        if m.isInbox {
                            Button {
                                UIPasteboard.general.string = m.address
                                flash("号码已复制")
                            } label: {
                                Label("复制号码", systemImage: "phone")
                                    .font(.system(size: 13, weight: .semibold))
                                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                                    .background(Theme.fill).foregroundColor(Theme.text)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                    }
                    Spacer()
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("短信详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { selected = nil }
                }
            }
        }
    }

    private func flash(_ s: String) {
        toast = s
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if toast == s { toast = nil }
        }
    }
}
