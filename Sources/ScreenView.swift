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
    @State private var lastTapAt: Date = .distantPast
    @State private var pollTask: Task<Void, Never>?
    @State private var monitorTask: Task<Void, Never>?
    @State private var h264Retries = 0
    @State private var fullscreen = false
    @State private var h264StartedAt: Date?
    @State private var slowTicks = 0
    @State private var autoDowngraded = false

    var body: some View {
        VStack(spacing: 8) {
            if !fullscreen { statusBar }
            screenArea
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
            monitorTask?.cancel()
            monitorTask = nil
            // V4.7 修复：离开屏幕页要恢复手机声音（原来 audio 泄漏，手机一直静音）
            if audio.playing {
                audio.stop()
                Task { _ = try? await Agent.shared.raw("/api/audio/stop", method: "POST") }
            }
        }
        .onChange(of: app.quality) { _ in startStream() }
        .onChange(of: useH264) { _ in startStream() }
        .onReceive(NotificationCenter.default.publisher(for: .rcForeground)) { _ in
            startStream()
            if audio.playing { audio.start(mutePhone: true) }
        }
        // V4.7：H.264 意外断流自动重启（最多 3 次，仍失败回退 JPEG）
        .onReceive(NotificationCenter.default.publisher(for: .rcH264Died)) { _ in
            guard useH264, h264Retries < 3 else {
                if useH264 { useH264 = false; flash("H.264 反复断流，已切回 JPEG") }
                return
            }
            h264Retries += 1
            flash("H.264 断流，自动重启中…")
            startStream()
        }
        .sheet(isPresented: $showTextInput) { textSheet }
        .overlay(alignment: .top) { toastView }
    }

    // MARK: 流控制

    private func startStream() {
        stream.stop()
        h264.stop()
        h264Retries = 0
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

    /// 自适应：连续掉帧就把画质降一档（V4.7：句柄存入 monitorTask，onDisappear 取消，不再越权常驻）
    private func startAdaptiveMonitor() {
        monitorTask?.cancel()
        monitorTask = Task {
            var offlineTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                // 断流看门狗：连续 9 秒没画面就主动重启，避免一直卡在「连接中」
                if !useH264 && !stream.connected {
                    offlineTicks += 1
                    if offlineTicks >= 3 {
                        offlineTicks = 0
                        await MainActor.run { startStream() }
                    }
                    continue
                }
                offlineTicks = 0
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
            do {
                // V4.7 修复：先查当前方向再 +1（原来硬编码永远发 0，功能无效）
                let cur: Int
                if let obj = try? await Agent.shared.raw("/api/display") {
                    let d = (obj["data"] as? [String: Any]) ?? obj
                    cur = (d["rotation"] as? Int) ?? 0
                } else { cur = 0 }
                _ = try await Agent.shared.raw("/api/rotate", method: "POST", json: ["rotation": (cur + 1) % 4])
                flash("已切换手机方向 → \(["竖屏", "横右", "倒竖", "横左"][(cur + 1) % 4])")
            } catch { flash("旋转失败：\(app.friendly(error))") }
        }
    }

    // MARK: 画面

    private var screenArea: some View {
        GeometryReader { geo in
            let rect = displayRect(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: fullscreen ? 0 : 14).fill(Color.black)

                if h264.ready {
                    H264View(layer: h264.layer)
                        .clipShape(RoundedRectangle(cornerRadius: fullscreen ? 0 : 14))
                } else if let img = stream.image {
                    Image(uiImage: img)
                        .resizable()
                        .interpolation(.medium)
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    VStack(spacing: 10) {
                        if stream.error == nil { ProgressView().tint(Theme.accent) }
                        Text(stream.error ?? (useH264 ? "正在启动 H.264…" : "正在获取画面…"))
                            .font(.system(size: 13)).foregroundColor(.white.opacity(0.7))
                            .multilineTextAlignment(.center).padding()
                    }
                }

                // V4.7：重连水印——断流时明确提示画面可能不是实时的
                if stream.reconnecting {
                    VStack(spacing: 6) {
                        ProgressView().tint(.white)
                        Text("连接断开，自动重连中…")
                            .font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .background(Color.black.opacity(0.62))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .transition(.opacity)
                }

                // 手势层：不管 H.264 还是 JPEG 都覆盖在画面区域上
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(dragGesture(rect: rect))
                    .simultaneousGesture(pinchGesture(rect: rect))

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

                if !fullscreen {
                    HStack(spacing: 0) {
                        VStack(spacing: 7) {
                            sideButton("power", "电源") { try await Agent.shared.key("power") }
                            sideButton("sun.max", "唤醒") { try await Agent.shared.key("wake") }
                            sideButton("speaker.wave.2", "音量+") { try await Agent.shared.key("volume_up") }
                            sideButton("speaker.minus", "音量-") { try await Agent.shared.key("volume_down") }
                            sideButton(audio.playing ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                       audio.playing ? "关声音" : "同步声音") { toggleAudio() }
                            sideButton("square.and.arrow.down", "截图") { saveScreenshot() }
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 7) {
                            sideButton("chevron.left", "返回") { try await Agent.shared.key("back") }
                            sideButton("house", "主页") { try await Agent.shared.key("home") }
                            sideButton("square.on.square", "多任务") { try await Agent.shared.key("recents") }
                        }
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 10)
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

    /// 画面在屏幕上的实际显示区域（用于坐标映射）
    private func displayRect(in size: CGSize) -> CGRect {
        if h264.ready, let s = app.deviceInfo?.screen {
            return fitRect(imageSize: CGSize(width: s.width, height: s.height), in: size)
        }
        if let img = stream.image {
            return fitRect(imageSize: img.size, in: size)
        }
        if let s = app.deviceInfo?.screen {
            return fitRect(imageSize: CGSize(width: s.width, height: s.height), in: size)
        }
        return CGRect(origin: .zero, size: size)
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

    // MARK: 侧边控制按钮

    private func sideButton(_ icon: String, _ label: String, action: @escaping () async throws -> Void) -> some View {
        Button { send(action) } label: {
            VStack(spacing: 2) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(label).font(.system(size: 8, weight: .medium))
            }
            .frame(width: 46, height: 42)
            .background(Color.black.opacity(0.55))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
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
        // V4.7 流畅度核心修复：去掉 busy 全局互斥（原来一条 tap 未返回会静默丢弃后续所有触控）
        // 改为并发发送 + 触控请求 4-5s 短超时，指令不再堆积丢失；成功时轻震动反馈
        Task {
            do {
                try await op()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } catch { flash(app.friendly(error)) }
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
