import SwiftUI
import UIKit
import AVKit
import UniformTypeIdentifiers

// MARK: - 文件页

struct FilesView: View {
    @EnvironmentObject var app: AppState
    @State private var path = "/sdcard"
    @State private var items: [RemoteFile] = []
    @State private var loading = false
    @State private var error: String?
    @State private var toast: String?
    @State private var showNewFolder = false
    @State private var newName = ""
    @State private var showImporter = false
    @State private var uploading = false
    @State private var editingFile: RemoteFile?
    @State private var playingFile: RemoteFile?
    @State private var previewImage: UIImage?
    @State private var showPreview = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var deleteTarget: RemoteFile?

    private let quickPaths = [
        PresetItem(id: "/sdcard", label: "内部存储", value: "/sdcard"),
        PresetItem(id: "/sdcard/Download", label: "下载", value: "/sdcard/Download"),
        PresetItem(id: "/sdcard/DCIM", label: "相册", value: "/sdcard/DCIM"),
        PresetItem(id: "/sdcard/Music", label: "音乐", value: "/sdcard/Music"),
        PresetItem(id: "/sdcard/Movies", label: "视频", value: "/sdcard/Movies")
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            if let e = error {
                Text(e).font(.system(size: 11)).foregroundColor(Theme.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Theme.red.opacity(0.06))
            }
            QuickPathBar(paths: quickPaths, current: path) { p in
                path = p
                Task { await load() }
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(sortedItems) { f in
                        Button { open(f) } label: { row(f) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { download(f) } label: { Label("下载到 iPhone", systemImage: "arrow.down.circle") }
                                Button(role: .destructive) { deleteTarget = f } label: { Label("删除", systemImage: "trash") }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { deleteTarget = f } label: { Label("删除", systemImage: "trash") }
                                Button { download(f) } label: { Label("下载", systemImage: "square.and.arrow.down") }.tint(Theme.blue)
                            }
                        Divider().background(Theme.line).padding(.leading, 52)
                    }
                    if items.isEmpty && !loading {
                        VStack(spacing: 8) {
                            Image(systemName: "folder").font(.system(size: 28)).foregroundColor(Theme.dim)
                            Text("这个文件夹是空的").font(.system(size: 12)).foregroundColor(Theme.dim)
                        }.padding(.top, 50)
                    }
                }
            }
            .refreshable { await load() }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await load() }
        .overlay(alignment: .top) { toastView }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名称", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("创建") { createFolder() }
        }
        .alert("删除", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
            Button("取消", role: .cancel) { deleteTarget = nil }
            Button("删除", role: .destructive) { if let f = deleteTarget { doDelete(f) } }
        } message: { Text("确定删除「\(deleteTarget?.name ?? "")」？此操作不可恢复。") }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        .sheet(item: $editingFile) { f in TextEditorSheet(file: f) { await load() } }
        .sheet(item: $playingFile) { f in MediaPlayerSheet(file: f) }
        .sheet(isPresented: $showShare) { if let u = shareURL { ShareSheet(items: [u] as [Any]) } }
        .sheet(isPresented: $showPreview) {
            if let img = previewImage {
                VStack {
                    HStack {
                        Text("图片预览").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button("关闭") { showPreview = false }
                    }.padding()
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: img).resizable().scaledToFit().frame(maxWidth: .infinity)
                    }
                }
                .background(Theme.bg.ignoresSafeArea())
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(path == "/sdcard" ? Theme.dim : Theme.accent)
                }
                .disabled(path == "/sdcard")

                Text(path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if loading || uploading { ProgressView().scaleEffect(0.6) }
                Menu {
                    Button { newName = ""; showNewFolder = true } label: { Label("新建文件夹", systemImage: "folder.badge.plus") }
                    Button { showImporter = true } label: { Label("上传文件到手机", systemImage: "arrow.up.doc") }
                    Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 17))
                        .foregroundColor(Theme.accent)
                }
            }
            HStack(spacing: 8) {
                Button { newName = ""; showNewFolder = true } label: {
                    Label("新建文件夹", systemImage: "folder.badge.plus")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Theme.fill).foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Button { showImporter = true } label: {
                    Label("上传", systemImage: "arrow.up.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 7)
                        .background(Theme.accent.opacity(0.10)).foregroundColor(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Theme.card)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Theme.line), alignment: .bottom)
    }

    private var sortedItems: [RemoteFile] {
        items.sorted {
            if $0.dir != $1.dir { return $0.dir }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: 行

    private func row(_ f: RemoteFile) -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor(f).opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: iconName(f))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(iconColor(f))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(f.name)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                Text(subtitle(f))
                    .font(.system(size: 10))
                    .foregroundColor(Theme.dim)
            }
            Spacer()
            if f.dir {
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundColor(Theme.dim)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .contentShape(Rectangle())
    }

    private func subtitle(_ f: RemoteFile) -> String {
        if f.dir { return "文件夹" }
        let size = ByteCountFormatter.string(fromByteCount: f.size ?? 0, countStyle: .file)
        if let m = f.mtime, m > 0 {
            let d = Date(timeIntervalSince1970: TimeInterval(m))
            return "\(size) · \(d.formatted(date: .numeric, time: .shortened))"
        }
        return size
    }

    private func ext(_ f: RemoteFile) -> String {
        (f.name as NSString).pathExtension.lowercased()
    }

    private func iconName(_ f: RemoteFile) -> String {
        if f.dir { return "folder.fill" }
        switch ext(f) {
        case "mp3", "m4a", "wav", "flac", "ogg", "aac", "opus": return "music.note"
        case "mp4", "mkv", "mov", "avi", "webm", "3gp", "ts": return "play.rectangle.fill"
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic": return "photo.fill"
        case "txt", "md", "log", "json", "xml", "csv", "yml", "yaml", "ini", "conf": return "doc.text.fill"
        case "apk": return "shippingbox.fill"
        default: return "doc.fill"
        }
    }

    private func iconColor(_ f: RemoteFile) -> Color {
        if f.dir { return Theme.orange }
        switch ext(f) {
        case "mp3", "m4a", "wav", "flac", "ogg", "aac", "opus": return Theme.accent
        case "mp4", "mkv", "mov", "avi", "webm", "3gp", "ts": return Theme.blue
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic": return Theme.orange
        case "apk": return Theme.red
        default: return Theme.sub
        }
    }

    // MARK: 操作

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await Agent.shared.files(path: path)
            items = r.items
            error = nil
        } catch {
            self.error = app.friendly(error)
        }
    }

    private func goUp() {
        guard path != "/" , path != "/sdcard" else { return }
        let p = (path as NSString).deletingLastPathComponent
        path = p.isEmpty ? "/" : p
        Task { await load() }
    }

    private func open(_ f: RemoteFile) {
        let full = path.hasSuffix("/") ? path + f.name : path + "/" + f.name
        if f.dir {
            path = full
            Task { await load() }
            return
        }
        switch ext(f) {
        case "mp3", "m4a", "wav", "flac", "ogg", "aac", "opus", "mp4", "mkv", "mov", "avi", "webm", "3gp", "ts":
            playingFile = RemoteFile(name: full, dir: false, size: f.size, mtime: f.mtime)
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "heic":
            openImage(full)
        case "txt", "md", "log", "json", "xml", "csv", "yml", "yaml", "ini", "conf", "js", "py", "sh", "html", "css":
            editingFile = RemoteFile(name: full, dir: false, size: f.size, mtime: f.mtime)
        default:
            download(f)
        }
    }

    private func openImage(_ full: String) {
        Task {
            do {
                let data = try await Agent.shared.fileData(path: full)
                if let img = UIImage(data: data) {
                    previewImage = img
                    showPreview = true
                } else { flash("不是有效图片") }
            } catch { flash(app.friendly(error)) }
        }
    }

    private func download(_ f: RemoteFile) {
        let full = path.hasSuffix("/") ? path + f.name : path + "/" + f.name
        Task {
            do {
                let data = try await Agent.shared.fileData(path: full)
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(f.name)
                try data.write(to: tmp)
                await MainActor.run {
                    shareURL = tmp
                    showShare = true
                }
            } catch { flash(app.friendly(error)) }
        }
    }

    private func createFolder() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let full = path.hasSuffix("/") ? path + name : path + "/" + name
        Task {
            do {
                try await Agent.shared.fileOp("mkdir", path: full)
                flash("已创建 \(name)")
                await load()
            } catch { flash(app.friendly(error)) }
        }
        newName = ""
    }

    private func doDelete(_ f: RemoteFile) {
        let full = path.hasSuffix("/") ? path + f.name : path + "/" + f.name
        deleteTarget = nil
        Task {
            do {
                try await Agent.shared.fileOp("delete", path: full)
                flash("已删除")
                await load()
            } catch { flash(app.friendly(error)) }
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else { return }
            uploading = true
            Task {
                defer { uploading = false }
                for url in urls {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let data = try Data(contentsOf: url)
                        let full = path.hasSuffix("/") ? path + url.lastPathComponent : path + "/" + url.lastPathComponent
                        _ = try await Agent.shared.upload(to: full, data: data)
                    } catch {
                        flash("上传失败：\(app.friendly(error))")
                    }
                }
                flash("上传完成")
                await load()
            }
        case .failure(let e):
            flash(e.localizedDescription)
        }
    }

    private func flash(_ s: String) {
        withAnimation { toast = s }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation { if toast == s { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = toast {
            Text(t).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.78)).foregroundColor(.white)
                .clipShape(Capsule()).padding(.top, 8)
                .transition(.opacity)
        }
    }
}

// MARK: - 快捷路径

struct QuickPathBar: View {
    var paths: [PresetItem]
    var current: String
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(paths) { p in
                    Button(p.label) { onSelect(p.value) }
                        .font(.system(size: 11))
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .background(current == p.value ? Theme.accent.opacity(0.12) : Theme.card)
                        .foregroundColor(current == p.value ? Theme.accent : Theme.sub)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.line, lineWidth: 1))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}

// MARK: - 文本编辑

struct TextEditorSheet: View {
    let file: RemoteFile
    var onSaved: () async -> Void
    @Environment(\.dismiss) var dismiss
    @State private var text = ""
    @State private var original = ""
    @State private var loading = true
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if loading {
                    ProgressView("载入中…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $text)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .background(Theme.card)
                }
                if let e = error {
                    Text(e).font(.system(size: 11)).foregroundColor(Theme.red).padding(6)
                }
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle((file.name as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "保存中…" : "保存") { save() }
                        .disabled(loading || saving || text == original)
                }
            }
        }
        .task { await loadFile() }
    }

    private func loadFile() async {
        do {
            let data = try await Agent.shared.fileData(path: file.name)
            let s = String(data: data, encoding: .utf8) ?? "（二进制文件，无法以文本打开）"
            await MainActor.run {
                text = s
                original = s
                loading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }

    private func save() {
        saving = true
        Task {
            defer { saving = false }
            do {
                _ = try await Agent.shared.upload(to: file.name, data: Data(text.utf8))
                original = text
                await onSaved()
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run { self.error = error.localizedDescription }
            }
        }
    }
}

// MARK: - 音视频播放

struct MediaPlayerSheet: View {
    let file: RemoteFile
    @Environment(\.dismiss) var dismiss
    @State private var player: AVPlayer?
    @State private var loading = true
    @State private var error: String?
    @State private var localURL: URL?

    private var isVideo: Bool {
        ["mp4", "mkv", "mov", "avi", "webm", "3gp", "ts"].contains((file.name as NSString).pathExtension.lowercased())
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text((file.name as NSString).lastPathComponent)
                    .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Spacer()
                Button("关闭") { player?.pause(); dismiss() }
            }
            .padding(.horizontal, 16).padding(.top, 12)

            if loading {
                Spacer()
                ProgressView("正在从手机下载…")
                Spacer()
            } else if let e = error {
                Spacer()
                Text(e).font(.system(size: 12)).foregroundColor(Theme.red).padding()
                Spacer()
            } else if let p = player {
                if isVideo {
                    VideoPlayer(player: p)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onAppear { p.play() }
                } else {
                    Spacer()
                    Image(systemName: "music.note")
                        .font(.system(size: 64)).foregroundColor(Theme.accent)
                    Text((file.name as NSString).lastPathComponent)
                        .font(.system(size: 13)).foregroundColor(Theme.sub)
                    Button {
                        if p.rate == 0 { p.play() } else { p.pause() }
                    } label: {
                        Image(systemName: "playpause.fill")
                            .font(.system(size: 26))
                            .frame(width: 74, height: 74)
                            .background(Theme.accent.opacity(0.12))
                            .foregroundColor(Theme.accent)
                            .clipShape(Circle())
                    }
                    Spacer()
                }
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .task { await prepare() }
        .onDisappear { player?.pause() }
    }

    private func prepare() async {
        do {
            let data = try await Agent.shared.fileData(path: file.name)
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent((file.name as NSString).lastPathComponent)
            try data.write(to: tmp)
            await MainActor.run {
                localURL = tmp
                player = AVPlayer(url: tmp)
                loading = false
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                loading = false
            }
        }
    }
}
