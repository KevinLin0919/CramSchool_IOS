import SwiftUI
import PhotosUI

// Screen 2 — full-bleed camera scanner.
// Flow: aligning → detected (frame locks green, auto-captures) →
// grading (YOLO + OCR, boxes pop in) → done (score card slides up).
enum ScanPhase: Equatable {
    case aligning
    case detected
    case grading
    case done
    case failed(String)
}

struct ScannerView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var camera = CameraController()

    @State private var phase: ScanPhase = .aligning
    @State private var captured: UIImage?
    @State private var answers: [GradedAnswer] = []
    @State private var revealed = 0
    @State private var pickerItem: PhotosPickerItem?
    @State private var gradingTask: Task<Void, Never>?

    private var revealedCorrect: Int {
        answers.prefix(revealed).filter(\.isCorrect).count
    }

    private var totalQuestions: Int {
        answers.isEmpty ? (model.selectedTemplate?.annotationCount ?? 0) : answers.count
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop

                // top scrim
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 150)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()

                overlayContent(in: geo)

                if model.selectedTemplate == nil {
                    noTemplateOverlay
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .onAppear {
            camera.onCapture = { image in handleCapture(image) }
            if model.selectedTemplate != nil {
                camera.checkPermissionAndStart()
            }
        }
        .onDisappear {
            gradingTask?.cancel()
            camera.stop()
        }
        .onChange(of: camera.paperDetected) { _, detected in
            if detected && phase == .aligning {
                phase = .detected
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handleCapture(image)
                }
                pickerItem = nil
            }
        }
    }

    // MARK: - Backdrop (live camera or frozen capture)

    @ViewBuilder
    private var backdrop: some View {
        if let captured {
            ZStack {
                Color.black.ignoresSafeArea()
                GradedImageOverlay(image: captured,
                                   answers: answers,
                                   revealed: revealed)
                    .padding(.horizontal, 20)
                    .padding(.top, 100)
                    .padding(.bottom, 170)
                    .animation(.spring(duration: 0.28), value: revealed)
            }
        } else if camera.isAuthorized {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()
        } else {
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.5))
                Text("需要相機權限才能掃描考卷")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.8))
                Button("前往設定開啟") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(AG.brand)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(hex: 0x0D1011))
            .ignoresSafeArea()
        }
    }

    // MARK: - Overlay chrome

    @ViewBuilder
    private func overlayContent(in geo: GeometryProxy) -> some View {
        // Scale the guide frame with the screen so it stays generous on
        // iPad instead of being pinned to a phone-sized 300pt box.
        let frameWidth = min(geo.size.width - 80, geo.size.height * 0.5, 460)
        let frameHeight = frameWidth * 400 / 290

        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, geo.safeAreaInsets.top > 0 ? 8 : 16)

            if phase == .aligning || phase == .detected || phase == .grading {
                Text("將考卷置於框內，即時辨識並批改答案")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 14)
                    .padding(.horizontal, 32)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }

        // Guide frame — only over the live camera
        if captured == nil && camera.isAuthorized {
            GuideFrameView(locked: phase != .aligning,
                           sweeping: phase == .aligning)
                .frame(width: frameWidth, height: frameHeight)
                .allowsHitTesting(false)
        }

        VStack(spacing: 0) {
            Spacer()

            switch phase {
            case .aligning, .detected, .grading:
                StatusPillView(phase: phase,
                               graded: revealed,
                               total: totalQuestions)
                    .padding(.bottom, 18)

                if phase == .aligning || phase == .detected {
                    utilitiesRow
                        .padding(.bottom, 16)
                }

                Text(bottomHint)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.bottom, geo.safeAreaInsets.bottom + 24)

            case .done:
                DoneCardView(correct: answers.filter(\.isCorrect).count,
                             total: answers.count,
                             onViewResults: { model.screen = .results },
                             onRescan: rescan)
                    .centeredContent(AG.Width.card)
                    .padding(.horizontal, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))

            case .failed(let message):
                failedCard(message)
                    .centeredContent(AG.Width.card)
                    .padding(.horizontal, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.32), value: phase)
    }

    private var bottomHint: String {
        switch phase {
        case .aligning: return "・ 即時批改啟用中 ・"
        case .detected: return "・ 偵測穩定，YOLO 辨識答案區 ・"
        case .grading: return "・ OCR 即時比對答案中 ・"
        default: return ""
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                gradingTask?.cancel()
                camera.stop()
                model.screen = .templates
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.45))
                    .clipShape(Circle())
            }

            if let template = model.selectedTemplate {
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(.white.opacity(0.22))
                        Image(systemName: "doc.text")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 22, height: 22)

                    Text(template.fullTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text("\(template.annotationCount) 題")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .padding(.leading, 8)
                .padding(.trailing, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.24), lineWidth: 0.5))
            }

            Spacer()

            if phase == .grading || phase == .done {
                HStack(spacing: 5) {
                    Text("\(revealedCorrect)")
                        .foregroundStyle(Color(hex: 0x6FCF97))
                    Text("/").foregroundStyle(.white.opacity(0.5))
                    Text("\(revealed)")
                        .foregroundStyle(.white.opacity(0.8))
                }
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(AG.brand.opacity(0.55), lineWidth: 1))
            }
        }
    }

    private var utilitiesRow: some View {
        HStack(spacing: 22) {
            utilityButton(icon: camera.isTorchOn ? "bolt.fill" : "bolt.slash",
                          label: "閃光") {
                camera.toggleTorch()
            }

            PhotosPicker(selection: $pickerItem, matching: .images) {
                utilityLabel(icon: "photo.on.rectangle", label: "相簿")
            }

            utilityButton(icon: "arrow.triangle.2.circlepath.camera",
                          label: "翻轉") {
                camera.flipCamera()
            }
        }
        .opacity(0.75)
    }

    private func utilityButton(icon: String, label: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            utilityLabel(icon: icon, label: label)
        }
    }

    private func utilityLabel(icon: String, label: String) -> some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.white.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white)
        }
    }

    private func failedCard(_ message: String) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(AG.badBg)
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(AG.bad)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("批改失敗")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AG.fg1)
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(AG.fg2)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                Button {
                    model.screen = .templates
                } label: {
                    Text("返回")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AG.fg1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(AG.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(AG.border2, lineWidth: 1))
                }
                Button(action: rescan) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                        Text("重新掃描")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(AG.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .padding(16)
        .background(.white.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 16)
    }

    private var noTemplateOverlay: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.6))
            Text("請先選擇要批改的考卷模板")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
            Button {
                model.screen = .templates
            } label: {
                Text("選擇考卷")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .frame(height: 46)
                    .background(AG.brand)
                    .clipShape(Capsule())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.8))
        .ignoresSafeArea()
    }

    // MARK: - Flow

    private func handleCapture(_ image: UIImage) {
        guard phase == .aligning || phase == .detected else { return }
        camera.stop()
        captured = image
        phase = .grading
        revealed = 0
        answers = []
        runGrading(image)
    }

    private func runGrading(_ image: UIImage) {
        guard let template = model.selectedTemplate else {
            phase = .failed("尚未選擇考卷模板")
            return
        }
        gradingTask = Task { @MainActor in
            do {
                let result = try await GradingEngine.grade(image: image,
                                                           templateID: template.id,
                                                           templateTitle: template.fullTitle)
                guard !Task.isCancelled else { return }
                guard !result.answers.isEmpty else {
                    phase = .failed("未偵測到答案區，請重新對齊考卷")
                    return
                }
                answers = result.answers

                // Reveal boxes one by one — the design's live-grading feel.
                for i in 1...result.answers.count {
                    guard !Task.isCancelled else { return }
                    revealed = i
                    try? await Task.sleep(nanoseconds: 140_000_000)
                }

                model.lastResult = result
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled else { return }
                withAnimation { phase = .done }
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func rescan() {
        gradingTask?.cancel()
        captured = nil
        answers = []
        revealed = 0
        phase = .aligning
        camera.resetDetection()
        camera.checkPermissionAndStart()
    }
}

// MARK: - Guide frame

private struct GuideFrameView: View {
    let locked: Bool
    let sweeping: Bool

    @State private var sweepOffset: CGFloat = 0
    @State private var pulse = false

    private var borderColor: Color {
        locked ? AG.brand : .white.opacity(0.85)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(borderColor, lineWidth: 2)
                    .padding(-8)
                    .opacity(locked ? 1 : (pulse ? 0.85 : 0.6))
                    .shadow(color: locked ? AG.brand.opacity(0.5) : .white.opacity(0.25),
                            radius: locked ? 20 : 8)

                // scanning sweep line
                if sweeping {
                    Rectangle()
                        .fill(
                            LinearGradient(colors: [.clear, AG.brand500, .clear],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .frame(height: 2)
                        .shadow(color: AG.brand500, radius: 8)
                        .offset(y: sweepOffset - geo.size.height / 2)
                        .onAppear {
                            sweepOffset = 0
                            withAnimation(.linear(duration: 2.4).repeatForever(autoreverses: false)) {
                                sweepOffset = geo.size.height
                            }
                        }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .overlay(alignment: .topLeading) { bracket(0).offset(x: -10, y: -10) }
            .overlay(alignment: .topTrailing) { bracket(90).offset(x: 10, y: -10) }
            .overlay(alignment: .bottomTrailing) { bracket(180).offset(x: 10, y: 10) }
            .overlay(alignment: .bottomLeading) { bracket(270).offset(x: -10, y: 10) }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    // An L-shaped corner bracket anchored top-left, rotated per corner.
    private func bracket(_ degrees: Double) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(locked ? AG.brand : .white)
                .frame(width: 28, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(locked ? AG.brand : .white)
                .frame(width: 4, height: 28)
        }
        .frame(width: 28, height: 28, alignment: .topLeading)
        .rotationEffect(.degrees(degrees))
    }
}

// MARK: - Status pill

private struct StatusPillView: View {
    let phase: ScanPhase
    let graded: Int
    let total: Int

    @State private var spin = false
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .aligning:
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .opacity(blink ? 1 : 0.4)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                            blink = true
                        }
                    }
                Text("請將考卷對齊框內")

            case .detected:
                ZStack {
                    Circle().fill(AG.brand)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 16, height: 16)
                Text("已偵測到考卷・開始批改")

            default:
                Circle()
                    .trim(from: 0.15, to: 1)
                    .stroke(AG.brand500, lineWidth: 2)
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) {
                            spin = true
                        }
                    }
                Text("即時批改中・\(graded)/\(total)")
                    .monospacedDigit()
            }
        }
        .font(.system(size: 15, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
    }
}

// MARK: - Done card

private struct DoneCardView: View {
    let correct: Int
    let total: Int
    let onViewResults: () -> Void
    let onRescan: () -> Void

    private var pct: Int {
        total > 0 ? Int((Double(correct) / Double(total) * 100).rounded()) : 0
    }
    private var passed: Bool { pct >= 60 }

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text("\(correct)")
                        .font(.system(size: 40, weight: .bold))
                        .foregroundStyle(passed ? AG.brand : AG.bad)
                    Text("/\(total)")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AG.fg3)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("批改完成・\(pct)%")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AG.fg1)
                    Text(total - correct == 0 ? "全部正確" : "\(total - correct) 題錯誤，已在畫面標示")
                        .font(.system(size: 12))
                        .foregroundStyle(AG.fg2)
                }
                Spacer()

                Text(passed ? "通過" : "未通過")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(passed ? AG.brand : AG.bad)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(passed ? AG.brand.opacity(0.09) : AG.badBg)
                    .clipShape(Capsule())
            }

            HStack(spacing: 10) {
                Button(action: onViewResults) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar")
                            .font(.system(size: 14, weight: .semibold))
                        Text("查看明細")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(AG.fg1)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(AG.bg2)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AG.border2, lineWidth: 1))
                }

                Button(action: onRescan) {
                    HStack(spacing: 6) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 14, weight: .bold))
                        Text("掃描下一張")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(AG.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: AG.brand.opacity(0.35), radius: 8, y: 6)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(.white.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 16)
    }
}
