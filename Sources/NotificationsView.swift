import SwiftUI
import UIKit

struct NotificationsView: View {
    @EnvironmentObject var app: AppState
    @State private var items: [NotifItem] = []
    @State private var loading = false
    @State private var error: String?
    @State private var toast: String?
    @State private var lastSync: Date?
    @State private var filter = ""
    @State private var pollTask: Task<Void, Never>?

    private let appNames: [String: String] = [
        "tv.danmaku.bili": "哔哩哔哩",
        "com.tencent.mm": "微信",
        "com.tencent.mobileqq": "QQ",
        "com.android.mms": "短信",
        "com.miui.player": "音乐",
        "com.xiaomi.mipicks": "小米应用商店",
        "com.miui.systemAdSolution": "系统推广",
        "com.ss.android.ugc.aweme": "抖音",
        "com.taobao.taobao": "淘宝",
        "com.jingdong.app.mall": "京东",
        "com.eg.android.AlipayGphone": "支付宝",
        "com.netease.cloudmusic": "网易云音乐",
        "com.ximalaya.ting.android": "喜马拉雅"
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = error {
                Text(e).font(.system(size: 11)).foregroundColor(Theme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.orange.opacity(0.08))
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(filtered) { n in
                        card(n)
                    }
                    if filtered.isEmpty && !loading {
                        VStack(spacing: 8) {
                            Image(systemName: "bell.slash")
                                .font(.system(size: 30)).foregroundColor(Theme.dim)
                            Text(filter.isEmpty ? "手机当前没有通知" : "没有匹配的通知")
                                .font(.system(size: 12)).foregroundColor(Theme.dim)
                        }.padding(.top, 60)
                    }
                }
                .padding(12)
            }
            .refreshable { await load() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { startPolling() }
        .onDisappear { pollTask?.cancel(); pollTask = nil }
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
                    TextField("搜索应用或内容…", text: $filter)
                        .font(.system(size: 12)).textFieldStyle(.plain)
                        .autocapitalization(.none).disableAutocorrection(true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 9))

                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Theme.card).foregroundColor(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
            }
            HStack {
                Text("\(items.count) 条通知")
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
                if loading { ProgressView().scaleEffect(0.5) }
                Spacer()
                if let d = lastSync {
                    Text("更新于 " + d.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 10)).foregroundColor(Theme.dim)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.card)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.line), alignment: .bottom)
    }

    private func card(_ n: NotifItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    Circle().fill(Theme.accent.opacity(0.12)).frame(width: 22, height: 22)
                    Text(String(displayName(n.pkg).prefix(1)))
                        .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.accent)
                }
                Text(displayName(n.pkg))
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                if n.ongoing == true { TagView(text: "常驻", color: Theme.blue) }
                Spacer()
                Text(timeText(n.time))
                    .font(.system(size: 10)).foregroundColor(Theme.dim)
            }
            if !n.title.isEmpty {
                Text(n.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.text)
                    .lineLimit(2)
            }
            if !n.text.isEmpty {
                Text(n.text)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.sub)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                Button {
                    Task {
                        try? await Agent.shared.launch(n.pkg)
                        toast = "已打开 \(displayName(n.pkg))"
                    }
                } label: {
                    Label("打开应用", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.accent.opacity(0.10))
                        .foregroundColor(Theme.accent)
                        .clipShape(Capsule())
                }
                Button {
                    UIPasteboard.general.string = "\(n.title)\n\(n.text)"
                    toast = "已复制"
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Theme.fill)
                        .foregroundColor(Theme.sub)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(n.pkg).font(.system(size: 9)).foregroundColor(Theme.dim).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line, lineWidth: 1))
    }

    private var filtered: [NotifItem] {
        let s = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(s) || $0.text.lowercased().contains(s)
                || $0.pkg.lowercased().contains(s) || displayName($0.pkg).contains(s)
        }
    }

    private func displayName(_ pkg: String) -> String {
        if let n = appNames[pkg] { return n }
        let parts = pkg.split(separator: ".")
        return String(parts.last ?? Substring(pkg))
    }

    private func timeText(_ ms: Int64?) -> String {
        guard let ms = ms, ms > 0 else { return "" }
        let d = Date(timeIntervalSince1970: Double(ms) / 1000)
        let f = DateFormatter()
        if Calendar.current.isDateInToday(d) { f.dateFormat = "HH:mm" }
        else { f.dateFormat = "MM-dd HH:mm" }
        return f.string(from: d)
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
        }
    }

    private func load() async {
        if loading { return }
        loading = true
        defer { loading = false }
        do {
            let list = try await Agent.shared.notifications()
            await MainActor.run {
                items = list
                lastSync = Date()
                error = nil
            }
        } catch {
            await MainActor.run { self.error = app.friendly(error) }
        }
    }
}
