import SwiftUI
import UIKit

@MainActor
final class ScreenStreamer: ObservableObject {
    @Published var image: UIImage?
    @Published var error: String?
    @Published var running = false
    @Published var latencyMS: Int = 0

    private var task: Task<Void, Never>?

    func start(intervalMS: Int = 300) {
        guard task == nil else { return }
        running = true
        error = nil
        task = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self = self else { return }
                let t0 = Date()
                do {
                    let img = try await Agent.shared.screenshot(max: 720, quality: 60)
                    if Task.isCancelled { return }
                    self.image = img
                    self.latencyMS = Int(Date().timeIntervalSince(t0) * 1000)
                    self.error = nil
                    failures = 0
                    try? await Task.sleep(nanoseconds: UInt64(intervalMS) * 1_000_000)
                } catch {
                    if Task.isCancelled { return }
                    failures += 1
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let backoff = min(5.0, 0.5 * Double(failures))
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        running = false
    }

    /// 抓一帧（保存用）
    func captureFull() async throws -> UIImage {
        try await Agent.shared.screenshot(max: 0, quality: 92)
    }
}

private func fitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}

struct ScreenView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var streamer = ScreenStreamer()
    @State private var showTextInput = false
    @State private var text = ""
    @State private var toast: String?
    @State private var pressStart: Date?
    @State private var lastTapAt: Date = .distantPast
    @State private var busy = false

    var body: some View {
        VStack(spacing: 8) {
            statusBar
            screenArea
            controlBar
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { streamer.start() }
        .onDisappear { streamer.stop() }
        .sheet(isPresented: $showTextInput) { textSheet }
        .overlay(alignment: .top) { toastView }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(app.connected ? Theme.green : Theme.red)
                .frame(width: 8, height: 8)
            Text(app.connected ? "已连接" : "未连接")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Theme.sub)
            if streamer.running && streamer.image != nil {
                Text("\(1000 / max(streamer.latencyMS + 300, 1)) fps · \(streamer.latencyMS)ms")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.dim)
            }
            Spacer()
            if let e = streamer.error {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.orange)
                    .lineLimit(1)
            }
            Button {
                Task { await app.refreshInfo() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var screenArea: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)
                if let img = streamer.image {
                    let rect = fitRect(imageSize: img.size, in: geo.size)
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(rect: rect))
                } else {
                    VStack(spacing: 10) {
                        if streamer.running {
                            ProgressView().tint(Theme.accent)
                        }
                        Text(streamer.error ?? "正在获取画面…")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.dim)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1)
        )
    }

    private func dragGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in
                if pressStart == nil { pressStart = Date() }
            }
            .onEnded { value in
                let start = value.startLocation
                let dur = Date().timeIntervalSince(pressStart ?? Date())
                pressStart = nil
                let dx = value.location.x - start.x
                let dy = value.location.y - start.y
                let dist = sqrt(dx * dx + dy * dy)
                guard let screen = app.deviceInfo?.screen else {
                    flash("尚未获取到屏幕尺寸，请稍后重试")
                    return
                }
                func toDevice(_ p: CGPoint) -> (Int, Int) {
                    let rx = min(max((p.x - rect.minX) / max(rect.width, 1), 0), 1)
                    let ry = min(max((p.y - rect.minY) / max(rect.height, 1), 0), 1)
                    return (Int(Double(screen.width) * rx), Int(Double(screen.height) * ry))
                }
                let (sx, sy) = toDevice(start)
                if dist < 14 {
                    if dur >= 0.55 {
                        send { try await Agent.shared.longPress(x: sx, y: sy, ms: Int(dur * 1000)) }
                        flash("长按")
                    } else {
                        if Date().timeIntervalSince(lastTapAt) < 0.35 { return }
                        lastTapAt = Date()
                        send { try await Agent.shared.tap(x: sx, y: sy) }
                    }
                } else {
                    let (ex, ey) = toDevice(value.location)
                    send { try await Agent.shared.swipe(x1: sx, y1: sy, x2: ex, y2: ey, ms: 220) }
                }
            }
    }

    private func send(_ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await op() } catch { flash((error as? LocalizedError)?.errorDescription ?? "操作失败") }
        }
    }

    private var controlBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                keyButton("chevron.left", "返回") { try await Agent.shared.key("back") }
                keyButton("house", "主页") { try await Agent.shared.key("home") }
                keyButton("square.on.square", "多任务") { try await Agent.shared.key("recents") }
                keyButton("power", "电源") { try await Agent.shared.key("power") }
                keyButton("sun.max", "唤醒") { try await Agent.shared.key("wake") }
                keyButton("speaker.slash", "音量-") { try await Agent.shared.key("volume_down") }
                keyButton("speaker.wave.2", "音量+") { try await Agent.shared.key("volume_up") }
            }
            HStack(spacing: 8) {
                Button {
                    showTextInput = true
                } label: {
                    Label("输入文字", systemImage: "keyboard")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.accent.opacity(0.16))
                        .foregroundColor(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    saveScreenshot()
                } label: {
                    Label("截图存相册", systemImage: "square.and.arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.card)
                        .foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }

    private func keyButton(_ icon: String, _ label: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            send(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
                Text(label).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Theme.card)
            .foregroundColor(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
    }

    private var textSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发送文字到安卓")
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(Theme.text)
            TextField("输入要输入到手机的内容（支持中文）", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Theme.card)
                .foregroundColor(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .lineLimit(3...6)
            HStack {
                Text("中文输入需在手机上安装 ADBKeyboard；未安装时自动改用剪贴板粘贴")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.dim)
                Spacer()
            }
            HStack(spacing: 10) {
                Button("取消") { showTextInput = false }
                    .foregroundColor(Theme.sub)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button("发送") {
                    let t = text
                    showTextInput = false
                    guard !t.isEmpty else { return }
                    send { _ = try await Agent.shared.text(t) }
                    text = ""
                }
                .foregroundColor(.black)
                .fontWeight(.bold)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Theme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.bg.ignoresSafeArea())
        .presentationDetents([.height(320)])
    }

    private func saveScreenshot() {
        Task {
            do {
                let img = try await streamer.captureFull()
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                flash("已保存到相册")
            } catch {
                flash("保存失败：\(error.localizedDescription)")
            }
        }
    }

    private func flash(_ msg: String) {
        withAnimation { toast = msg }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation { if toast == msg { toast = nil } }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let t = toast {
            Text(t)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.card.opacity(0.95))
                .foregroundColor(Theme.text)
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.opacity)
        }
    }
}
