import SwiftUI
import UIKit

struct ScreenView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var stream = ScreenStream()
    @StateObject private var audio = AudioStreamer()
    @StateObject private var h264 = H264Stream()

    @AppStorage("rc.h264") private var useH264 = false
    @State private var showTextInput = false
    @State private var text = ""
    @State private var showQuality = false
    @State private var toast: String?
    @State private var pressStartTime: Date?
    @State private var busy = false
    @State private var lastTapAt: Date = .distantPast
    @State private var pollTask: Task<Void, Never>?
    @State private var fullscreen = false
    @State private var h264StartedAt: Date?
    @State private var slowTicks = 0
    @State private var autoDowngraded = false

    var body: some View {
        VStack(spacing: 8) {
            if !fullscreen { statusBar }
            screenArea
            if !fullscreen { controlBar }
        }
        .padding(.horizontal, fullscreen ? 0 : 10)
        .padding(.bottom, fullscreen ? 0 : 6)
        .background(Theme.bg.ignoresSafeArea())
        .onAppear {
            startStream()
            startFallbackPolling()
            startAdaptiveMonitor()
        }
        .onDisappear {
            stream.stop()
            h264.stop()
            pollTask?.cancel()
            pollTask = nil
        }
        .onChange(of: app.quality) { _ in startStream() }
        .onChange(of: useH264) { _ in startStream() }
        .onReceive(NotificationCenter.default.publisher(for: .rcForeground)) { _ in
            startStream()
            if audio.playing { audio.start(mutePhone: true) }
        }
        .sheet(isPresented: $showTextInput) { textSheet }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: 流控制

    private func startStream() {
        stream.stop()
        h264.stop()
        if useH264 {
            h264StartedAt = Date()
            let w = app.streamMaxWidth
            let h = Int(Double(w) * 3200.0 / 1440.0)
            let bitrate: Int
            switch app.quality {
            case 0: bitrate = 900_000
            case 2: bitrate = 2_500_000
            default: bitrate = 1_500_000
            }
            h264.start(size: "\(w)x\(h)", bitrate: bitrate)
            // 3 秒没出画就自动退回 JPEG
            Task {
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                if useH264 && !h264.ready {
                    await MainActor.run {
                        useH264 = false
                        flash("H.264 没出画，已自动切回 JPEG")
                    }
                }
            }
        } else {
            stream.start(max: app.streamMaxWidth, q: app.streamQualityParam, fps: app.streamFPS)
        }
    }

    private func startFallbackPolling() {
        pollTask?.cancel()
        pollTask = Task {
            for i in 0..<40 {
                if Task.isCancelled { return }
                if useH264 { return }
                if stream.connected && stream.image != nil { return }
                do {
                    let img = try await Agent.shared.screenshot(max: app.streamMaxWidth, quality: app.streamQualityParam)
                    stream.setPolled(img)
                    if i == 0 { Diag.mark("preview-ok") }
                } catch {
                    if i == 0 { Diag.err("preview: \(app.friendly(error))") }
                }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    /// 自适应：连续掉帧就把画质降一档
    private func startAdaptiveMonitor() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard stream.connected, !useH264 else { continue }
                let target = Double(app.streamFPS)
                if stream.fps > 0 && stream.fps < target * 0.45 && app.quality > 0 {
                    slowTicks += 1
                    if slowTicks >= 2 && !autoDowngraded {
                        autoDowngraded = true
                        await MainActor.run {
                            app.quality = max(0, app.quality - 1)
                            flash("网络较慢，已自动降为\(["流畅", "均衡", "高清"][app.quality])")
                        }
                    }
                } else {
                    slowTicks = 0
                }
            }
        }
    }

    // MARK: 顶栏

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(stream.connected || h264.ready ? Theme.green : Theme.red).frame(width: 8, height: 8)
            Text(h264.ready ? "H.264" : (stream.connected ? "实时" : "连接中…"))
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.sub)
            if h264.ready {
                Text(String(format: "%.0f fps", h264.fps))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.dim)
            } else if stream.connected {
                Text(String(format: "%.1f fps · %d KB/s", stream.fps, stream.kbps))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(stream.kbps > 250 ? Theme.orange : Theme.dim)
            }
            Spacer()
            Button { Task { rotate() } } label: {
                Image(systemName: "rotate.right").font(.system(size: 13)).foregroundColor(Theme.accent)
            }
            Button { withAnimation { fullscreen = true } } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13)).foregroundColor(Theme.accent)
            }
            Button { showQuality = true } label: {
                HStack(spacing: 3) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                    Text(["流畅", "均衡", "高清"][min(max(app.quality, 0), 2)]).font(.system(size: 11))
                }
                .foregroundColor(Theme.accent)
            }
        }
        .padding(.horizontal, 4).padding(.top, 4)
        .confirmationDialog("画质与编码", isPresented: $showQuality, titleVisibility: .visible) {
            Button("流畅 480p / 6fps（省流）") { app.quality = 0 }
            Button("均衡 720p / 8fps") { app.quality = 1 }
            Button("高清 1080p / 8fps（吃满 5M）") { app.quality = 2 }
            Button(useH264 ? "编码：H.264（实验）✓" : "编码：H.264（实验，省 8 倍流量）") { useH264.toggle() }
            Button("取消", role: .cancel) {}
        }
    }

    private func rotate() {
        Task {
            let cur = 0
            try? await Agent.shared.raw("/api/rotate", method: "POST", json: ["rotation": cur])
            flash("已切换手机方向")
        }
    }

    // MARK: 画面

    private var screenArea: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: fullscreen ? 0 : 14).fill(Color.black)
                if h264.ready {
                    H264View(layer: h264.layer)
                        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 14))
                } else if let img = stream.image {
                    let rect = fitRect(imageSize: img.size, in: geo.size)
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .contentShape(Rectangle())
                        .gesture(dragGesture(rect: rect))
                        .simultaneousGesture(pinchGesture(rect: rect))
                } else {
                    VStack(spacing: 10) {
                        if stream.error == nil { ProgressView().tint(Theme.accent) }
                        Text(stream.error ?? (useH264 ? "正在启动 H.264…" : "正在获取画面…"))
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center).padding()
                    }
                }

                if fullscreen {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation { fullscreen = false }
                            } label: {
                                Image(systemName: "arrow.down.right.and.arrow.up.left")
                                    .font(.system(size: 15, weight: .semibold))
                                    .padding(9)
                                    .background(Color.black.opacity(0.5))
                                    .foregroundColor(.white)
                                    .clipShape(Circle())
                            }
                            .padding(12)
                        }
                        Spacer()
                    }
                }
                if audio.playing && !fullscreen {
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
        .overlay(
            RoundedRectangle(cornerRadius: fullscreen ? 0 : 14)
                .stroke(fullscreen ? Color.clear : Theme.line, lineWidth: 1)
        )
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

    private func pinchGesture(rect: CGRect) -> some Gesture {
        MagnificationGesture()
            .onEnded { value in
                guard value != 1.0 else { return }
                let cx = Int(rect.midX)
                let cy = Int(rect.midY)
                guard let screen = app.deviceInfo?.screen else { return }
                let rx = min(max((CGFloat(cx) - rect.minX) / max(rect.width, 1), 0), 1)
                let ry = min(max((CGFloat(cy) - rect.minY) / max(rect.height, 1), 0), 1)
                let devX = Int(Double(screen.width) * rx)
                let devY = Int(Double(screen.height) * ry)
                let base = 260.0
                let target = min(max(base * Double(value), 80), 1100)
                send {
                    try await Agent.shared.pinch(cx: devX, cy: devY, from: Int(base), to: Int(target), ms: 320)
                }
                flash(value > 1 ? "双指放大" : "双指缩小")
            }
    }

    // MARK: 控制条

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
                        .background(Theme.card).foregroundColor(Theme.text)
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
            .background(Theme.card).foregroundColor(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line, lineWidth: 1))
        }
    }

    private var textSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("发送文字到安卓").font(.system(size: 18, weight: .bold)).foregroundColor(Theme.text)
            TextField("输入内容（支持中文）", text: $text, axis: .vertical)
                .textFieldStyle(.plain).padding(12)
                .background(Theme.fill).foregroundColor(Theme.text)
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
        .padding(20).background(Theme.card.ignoresSafeArea())
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
            Text(t).font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.black.opacity(0.78)).foregroundColor(.white)
                .clipShape(Capsule()).padding(.top, 8)
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
