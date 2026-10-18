import SwiftUI
import UIKit

struct ScreenView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var stream = ScreenStream()
    @StateObject private var audio = AudioStreamer()
    @State private var showTextInput = false
    @State private var text = ""
    @State private var showQuality = false
    @State private var toast: String?
    @State private var pressStartTime: Date?
    @State private var busy = false
    @State private var lastTapAt: Date = .distantPast

    var body: some View {
        VStack(spacing: 8) {
            statusBar
            screenArea
            controlBar
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { Diag.mark("stream-onAppear"); startStream() }
        .onDisappear { stream.stop() }
        .onChange(of: app.quality) { _ in startStream() }
        .sheet(isPresented: $showTextInput) { textSheet }
        .overlay(alignment: .top) { toastView }
    }

    private func startStream() {
        stream.start(max: app.streamMaxWidth, q: app.streamQualityParam, fps: app.streamFPS)
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(stream.connected ? Theme.green : Theme.red).frame(width: 8, height: 8)
            Text(stream.connected ? "实时" : "连接中…")
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.sub)
            if stream.connected {
                Text(String(format: "%.1f fps", stream.fps))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
            }
            Spacer()
            if let e = stream.error {
                Text(e).font(.system(size: 10)).foregroundColor(Theme.orange).lineLimit(1)
            }
            Button { showQuality = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                    Text(["流畅", "均衡", "高清"][min(max(app.quality, 0), 2)]).font(.system(size: 11))
                }
                .foregroundColor(Theme.accent)
            }
            Button { Task { await app.refreshInfo() } } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .confirmationDialog("画质", isPresented: $showQuality, titleVisibility: .visible) {
            Button("流畅 540p（最省流量）") { app.quality = 0 }
            Button("均衡 720p") { app.quality = 1 }
            Button("高清 1080p") { app.quality = 2 }
            Button("取消", role: .cancel) {}
        }
    }

    private var screenArea: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Color.black)
                if let img = stream.image {
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
                        if stream.error == nil { ProgressView().tint(Theme.accent) }
                        Text(stream.error ?? "正在获取画面…")
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center).padding()
                    }
                }
                if audio.playing {
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "speaker.wave.2.fill").font(.system(size: 9))
                                Text("声音已同步").font(.system(size: 9))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.black.opacity(0.55))
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                            .padding(8)
                        }
                        Spacer()
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, lineWidth: 1))
    }

    private func dragGesture(rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { _ in
                if pressStartTime == nil { pressStartTime = Date() }
            }
            .onEnded { value in
                let dur = Date().timeIntervalSince(pressStartTime ?? Date())
                pressStartTime = nil
                let start = value.startLocation
                let dx = value.location.x - start.x
                let dy = value.location.y - start.y
                let dist = sqrt(dx * dx + dy * dy)
                guard let screen = app.deviceInfo?.screen else { return }
                func toDevice(_ p: CGPoint) -> (Int, Int) {
                    let rx = min(max((p.x - rect.minX) / max(rect.width, 1), 0), 1)
                    let ry = min(max((p.y - rect.minY) / max(rect.height, 1), 0), 1)
                    return (Int(Double(screen.width) * rx), Int(Double(screen.height) * ry))
                }
                let (sx, sy) = toDevice(start)
                if dist < 14 {
                    if dur >= 0.55 {
                        send { try await Agent.shared.longPress(x: sx, y: sy, ms: Int(dur * 1000)) }
                    } else {
                        if Date().timeIntervalSince(lastTapAt) < 0.3 { return }
                        lastTapAt = Date()
                        send { try await Agent.shared.tap(x: sx, y: sy) }
                    }
                } else {
                    let (ex, ey) = toDevice(value.location)
                    send { try await Agent.shared.swipe(x1: sx, y1: sy, x2: ex, y2: ey, ms: 220) }
                }
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
                Button { showTextInput = true } label: {
                    Label("输入文字", systemImage: "keyboard")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Theme.accent.opacity(0.10))
                        .foregroundColor(Theme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button { toggleAudio() } label: {
                    Label(audio.playing ? "关闭声音" : "同步声音",
                          systemImage: audio.playing ? "speaker.slash.fill" : "speaker.wave.2")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(audio.playing ? Theme.blue.opacity(0.12) : Theme.card)
                        .foregroundColor(audio.playing ? Theme.blue : Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                }
                Button { saveScreenshot() } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 46, height: 36)
                        .background(Theme.card)
                        .foregroundColor(Theme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
                }
            }
        }
    }

    private func keyButton(_ icon: String, _ label: String, action: @escaping () async throws -> Void) -> some View {
        Button { send(action) } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(label).font(.system(size: 9))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 6)
            .background(Theme.card)
            .foregroundColor(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        }
    }

    private var textSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发送文字到安卓").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.text)
            TextField("输入内容（支持中文）", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .padding(12)
                .background(Theme.fill)
                .foregroundColor(Theme.text)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .lineLimit(3...6)
            Text("中文需手机安装 ADBKeyboard 并设为当前输入法；未安装时自动改用剪贴板粘贴")
                .font(.system(size: 11)).foregroundColor(Theme.dim)
            HStack(spacing: 10) {
                Button("取消") { showTextInput = false }
                    .foregroundColor(Theme.sub).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.fill).clipShape(RoundedRectangle(cornerRadius: 10))
                Button("发送") {
                    let t = text
                    showTextInput = false
                    guard !t.isEmpty else { return }
                    send { _ = try await Agent.shared.text(t) }
                    text = ""
                }
                .foregroundColor(.white).fontWeight(.bold)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Theme.accent).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Spacer()
        }
        .padding(20)
        .background(Theme.card.ignoresSafeArea())
        .presentationDetents([.height(320)])
    }

    private func toggleAudio() {
        if audio.playing {
            audio.stop()
            Task { _ = try? await Agent.shared.raw("/api/audio/stop", method: "POST") }
            flash("已停止声音同步")
        } else {
            audio.start(mutePhone: true)
            flash("声音同步中（手机会静音）")
        }
    }

    private func saveScreenshot() {
        Task {
            do {
                let img = try await Agent.shared.screenshot(max: 0, quality: 92)
                UIImageWriteToSavedPhotosAlbum(img, nil, nil, nil)
                flash("已保存到相册")
            } catch { flash("保存失败：\(app.friendly(error))") }
        }
    }

    private func send(_ op: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await op() } catch { flash(app.friendly(error)) }
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
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.78))
                .foregroundColor(.white)
                .clipShape(Capsule())
                .padding(.top, 8)
                .transition(.opacity)
        }
    }
}

func fitRect(imageSize: CGSize, in container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let scale = min(container.width / imageSize.width, container.height / imageSize.height)
    let w = imageSize.width * scale
    let h = imageSize.height * scale
    return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
}
