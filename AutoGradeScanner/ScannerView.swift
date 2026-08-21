import SwiftUI
import ARKit

// Screen 2 — full-bleed camera scanner.
//
// One flow only: the camera streams, XFeat aligns each frame against the
// template, boxes fill in as they are read, and the teacher says when the
// paper is done. The photograph-then-grade path that used to live beside it
// is gone — it graded server-side and came back with no cell crops, so a
// teacher reviewing a verdict had nothing to look at.

struct ScannerView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var camera = CameraController()


    // Live grading (bundled demo templates): boxes track the paper in the
    // viewfinder and verdicts accumulate as the camera pans across it.
    @State private var liveEngine: LiveScanEngine?
    @State private var liveUpdate: LiveScanEngine.Update?
    /// Why live grading is unavailable, when it is. Shown rather than swallowed
    /// so a missing master sheet does not look like a camera that just will not
    /// lock on.
    @State private var resolveError: String?

    /// The paper just finished, waiting for the teacher to move on. The camera
    /// keeps running behind the card: stopping and restarting it between
    /// papers is what made grading a stack feel like leaving and re-entering
    /// the app forty times.
    @State private var completedPaper: StoredPaper?
    /// Pages the teacher would abandon by finishing now. Non-nil while the
    /// confirmation is up.
    @State private var leftBehind: LiveScanEngine.LeftBehind?
    @StateObject private var papers = GradingStore.shared

    // Experimental ARKit world-tracking backbone (Phase 3). When enabled and
    // supported, ARKit owns the camera and pins the boxes in world space.
    // The ARKit backbone is a parked experiment: it never picked up Plan
    // B/C's rounded, One-Euro-smoothed rendering, so it still draws the old
    // sharp quads and still twitches. A switch for it in Settings meant one
    // tap could silently drop someone onto that old overlay — which is what
    // happened in the field. The code stays compiled for later, but off
    // outside DEBUG, and under a fresh key so a device that already enabled
    // it comes back off rather than being stuck with no way to turn it off.
    @AppStorage("scan.arBackbone.v2") private var arBackbone = false
    @AppStorage(CameraPreviewView.showsReadingKey) private var showsReading = false

    private var useARBackbone: Bool {
        #if DEBUG
        arBackbone && ARWorldTrackingConfiguration.isSupported && liveEngine != nil
        #else
        false
        #endif
    }

    /// Names the pages, not just the fact that some exist. "背面還有 10 題沒批改"
    /// can be acted on; "還有題目沒批改" sends someone hunting.
    private var leftBehindTitle: String {
        guard let leftBehind, !leftBehind.isEmpty else { return "" }
        let names = leftBehind.pages.map(\.label).joined(separator: "、")
        return "\(names)還有 \(leftBehind.remaining) 題沒批改"
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
            if let template = model.selectedTemplate {
                startLiveSession(for: template)
                // ARKit owns the camera in AR mode; starting the AVCapture
                // session too would fight it for the device.
                if !useARBackbone {
                    camera.checkPermissionAndStart()
                }
            }
        }
        .onDisappear {
            camera.onLiveFrame = nil
            liveEngine = nil
            liveUpdate = nil
            completedPaper = nil
            camera.stop()
        }
        .onChange(of: liveUpdate?.gradedCount) { _, graded in
            // Completion is a positive signal — every cell has an outcome —
            // rather than the absence of one. "The paper left the frame" and
            // "I am panning across it" look identical to the sensor, and at
            // the range these cells need, the second happens constantly.
            //
            // `totalCount` spans every page, so this only fires once the whole
            // paper is graded — a finished front does not file a half paper.
            // Turning the page is the engine's job and it declines to schedule
            // one when nothing is left, so the two never race.
            guard let graded, let live = liveUpdate,
                  live.totalCount > 0, graded == live.totalCount,
                  completedPaper == nil else { return }
            finishLiveSession()
        }
        .confirmationDialog(leftBehindTitle,
                            isPresented: Binding(get: { leftBehind != nil },
                                                 set: { if !$0 { leftBehind = nil } }),
                            titleVisibility: .visible) {
            if let first = leftBehind?.pages.first {
                Button("翻到\(first.label)繼續") {
                    liveEngine?.switchTo(page: first.index)
                    leftBehind = nil
                }
            }
            Button("其他頁沒有作答，直接完成", role: .destructive) { finishLiveSession() }
        } message: {
            Text("現在完成的話，那些題目會記成未作答。")
        }
    }

    // MARK: - Backdrop (live camera)

    @ViewBuilder
    private var backdrop: some View {
        if useARBackbone, let engine = liveEngine {
            ARScanContainer(engine: engine, live: liveUpdate)
                .ignoresSafeArea()
        } else if camera.isAuthorized {
            CameraPreviewView(session: camera.session, live: liveUpdate, pose: camera.pose,
                              showsReading: showsReading,
                              onOrientationChange: { camera.setOrientation($0) })
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
        // Scale the guide frame with the screen so it stays generous on iPad
        // instead of being pinned to a phone-sized 300pt box, and lay it out
        // along whichever axis the device is currently long in — a landscape
        // window is guiding a landscape sheet.
        let landscape = geo.size.width > geo.size.height
        let sheetRatio: CGFloat = 400 / 290          // a sheet's long/short side
        let frameHeight = landscape
            ? min(geo.size.height - 80, geo.size.width * 0.5, 460)
            : min(geo.size.width - 80, geo.size.height * 0.5, 460) * sheetRatio
        let frameWidth = landscape
            ? frameHeight * sheetRatio
            : min(geo.size.width - 80, geo.size.height * 0.5, 460)

        VStack(spacing: 0) {
            topBar
                .padding(.horizontal, 16)
                .padding(.top, geo.safeAreaInsets.top > 0 ? 8 : 16)

            Text("先把整張考卷放進框內對位，再靠近讓答案看得更清楚")
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 14)
                .padding(.horizontal, 32)
                .multilineTextAlignment(.center)

            Spacer()
        }

        // Guide frame — only over the live camera, until live boxes take
        // over. Keyed on box presence (persistent through brief alignment
        // dropouts), not the per-frame aligned flag, so it doesn't strobe
        // back in on a single missed frame.
        if camera.isAuthorized && (liveUpdate?.boxes.isEmpty ?? true) {
            GuideFrameView()
                .frame(width: frameWidth, height: frameHeight)
                .allowsHitTesting(false)
        }

        VStack(spacing: 0) {
            Spacer()

            if let completedPaper {
                // The paper is done; the camera is still running behind
                // this. Nothing else from the scanning chrome belongs here
                // — the only question left is whether to move on.
                completedCard(completedPaper)
                    .centeredContent(AG.Width.card)
                    .padding(.horizontal, 12)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let live = liveUpdate, liveEngine != nil {
                livePill(live)
                    .padding(.bottom, 14)

                if live.pages.count > 1 {
                    pageStrip(live)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }

                if live.gradedCount > 0 {
                    liveFinishButton(live)
                        .padding(.bottom, geo.safeAreaInsets.bottom + 26)
                } else {
                    Color.clear.frame(height: geo.safeAreaInsets.bottom + 26)
                }
            } else {
                // Before the first aligned frame, or while a page's features
                // are still being extracted.
                StatusPillView()
                    .padding(.bottom, geo.safeAreaInsets.bottom + 26)
            }

            // The standing hint is gone: it stood between the teacher and
            // the paper for the entire session to say something they only
            // needed once. What it also carried was the template-load
            // failure, and that has to survive — without it a template
            // that cannot load is a camera drawing no boxes and offering
            // no explanation.
            if completedPaper == nil, let resolveError {
                Text("無法載入這份考卷：\(resolveError)\n請回到考卷列表重新同步")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color(hex: 0xF2A0A0))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, geo.safeAreaInsets.bottom + 24)
            }

        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
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

            if !papers.papers.isEmpty {
                // The one being graded, not the count already filed: those
                // differ by one, and labelling the finished count "第 N 份"
                // would name the paper you just put down.
                Text("第 \(papers.papers.count + 1) 份")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.5))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
            }

        }
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

    // MARK: - Live grading session

    // Resolving reads the cached master sheet and boxes off disk, so on a
    // device that has synced this is fast and works with no network at all.
    // It is async only because a template opened for the first time still has
    // to be fetched once.
    private func startLiveSession(for template: ExamTemplate) {
        Task { @MainActor in
            do {
                let resolved = try await TemplateStore.shared.resolve(id: template.id)
                let engine = LiveScanEngine(template: resolved)
                engine.onUpdate = { update in liveUpdate = update }
                liveEngine = engine
                resolveError = nil
                camera.onLiveFrame = { image, timestamp, intrinsics, pixels in
                    Task { @MainActor in
                        engine.submit(frame: image, timestamp: timestamp,
                                      intrinsics: intrinsics, pixels: pixels)
                    }
                }
            } catch {
                // There is no fallback left to offer, and inventing one would
                // be worse than saying so: this used to flip on auto-capture
                // and grade server-side, which quietly moved the teacher onto
                // a slower path with no cell crops — from their side, the app
                // just started behaving differently for no stated reason.
                liveEngine = nil
                resolveError = error.localizedDescription
            }
        }
    }

    private func livePill(_ live: LiveScanEngine.Update) -> some View {
        HStack(spacing: 8) {
            if !live.boxes.isEmpty {
                Image(systemName: "checkmark.viewfinder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x6FCF97))
                Text("已對位・批改 \(live.gradedCount)/\(live.totalCount)" + debugSuffix(live))
                    .monospacedDigit()
                if showsReading, live.cellPixels > 0 {
                    // How many pixels the answer cell is actually worth. This
                    // is the number that decides whether a digit is readable —
                    // 128px reads real handwriting 6/6, 64px manages 3/6 — and
                    // moving the camera is the only way to change it, so it
                    // belongs on screen rather than in a log.
                    Text("・格 \(live.cellPixels)px")
                        .monospacedDigit()
                        .foregroundStyle(Self.cellSizeTint(live.cellPixels))

                    // The buffer the cell was cropped from. A small cell with
                    // a 4K frame means stand closer; a small cell with a
                    // ~1080px frame means this device cannot do better, and
                    // moving will not help.
                    if live.framePixels > 0 {
                        Text("・畫面 \(live.framePixels)px")
                            .monospacedDigit()
                            .foregroundStyle(Self.frameSizeTint(live.framePixels))
                    }
                }
            } else if !live.isReady {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(0.7)
                Text("模板載入中…")
            } else {
                Text("將考卷置於畫面中，即時對位批改")
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

    // Slides over the running camera when a paper is done. Green passes in one
    // tap; anything unresolved keeps the teacher here rather than letting the
    // default action carry them past a paper that did not grade.
    private func completedCard(_ paper: StoredPaper) -> some View {
        let clean = paper.unsureCount == 0 && paper.total > 0
        let tint = clean ? AG.ok : AG.warn

        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: clean ? "checkmark.circle.fill" : "questionmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(paper.correctCount)/\(paper.total) 正確")
                        .font(.system(size: 16, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                    if !clean {
                        Text("\(paper.unsureCount) 格待確認")
                            .font(.system(size: 12))
                            .foregroundStyle(AG.warn)
                    }
                }
                Spacer()
                Text("已完成 \(papers.papers.count) 份")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }

            // Both buttons are always present, because the tab bar is hidden
            // on this screen: without a route to the results page here, a
            // stack that grades cleanly can never be reached at all — the
            // loop just offers another paper, forever.
            HStack(spacing: 10) {
                Button {
                    model.screen = .results
                } label: {
                    Text(clean ? "完成這疊" : "處理")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(clean ? .white : AG.warn)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(clean ? Color.white.opacity(0.16) : AG.warn.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(clean ? .clear : AG.warn.opacity(0.5), lineWidth: 1))
                }
                Button(action: nextPaper) {
                    Text("下一份")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .background(clean ? AG.brand : Color.white.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
        .padding(14)
        .background(.black.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }

    // One pill per side of the paper. It is the page indicator and the page
    // switch at once: "which side am I on" and "which side still needs work"
    // are the same question, and answering it with an arrow pager would mean
    // pressing forward three times just to find out.
    //
    // Six pages is the stated ceiling, and six pills come to roughly 322pt
    // against the 361pt an iPhone leaves — so this never scrolls, and there is
    // no ellipsis or arrow case to design.
    private func pageStrip(_ live: LiveScanEngine.Update) -> some View {
        HStack(spacing: 4) {
            ForEach(live.pages) { page in
                pagePill(page, isCurrent: page.id == live.currentPage,
                         showsCount: live.pages.count == 2)
            }
        }
        .padding(4)
        .background(.black.opacity(0.55))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
    }

    private func pagePill(_ page: LiveScanEngine.PageState,
                          isCurrent: Bool,
                          showsCount: Bool) -> some View {
        Button {
            // Tapping the page already in view does nothing. It is a
            // selection, not a toggle — a mis-tap should not walk the teacher
            // off the side they are working on.
            guard !isCurrent else { return }
            liveEngine?.switchTo(page: page.id)
        } label: {
            HStack(spacing: 6) {
                Text(page.label)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? Color.white : Color.white.opacity(0.62))

                // Only the page in hand spells out its progress. The others
                // owe one answer — done or not — and a row of x/y counts at
                // six pages neither fits nor helps.
                if isCurrent || showsCount {
                    Text("\(page.graded)/\(page.total)")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(page.isComplete || isCurrent
                                         ? Color(hex: 0x6FCF97)
                                         : Color.white.opacity(0.42))
                } else if page.isComplete {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color(hex: 0x6FCF97))
                } else {
                    Circle()
                        .fill(page.isUntouched ? Color.white.opacity(0.3)
                              : Color(hex: 0xF2C94C))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, showsCount ? 16 : 13)
            .padding(.vertical, 13)
            .background(isCurrent ? Color.white.opacity(0.20) : Color.clear)
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func liveFinishButton(_ live: LiveScanEngine.Update) -> some View {
        Button(action: attemptFinish) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                Text("完成這份（\(live.gradedCount)/\(live.totalCount) 題）")
                    .font(.system(size: 16, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .frame(height: 48)
            .background(AG.brand)
            .clipShape(Capsule())
            .shadow(color: AG.brand.opacity(0.4), radius: 10, y: 6)
        }
    }

    /// Green once the cell carries enough pixels to be read reliably, amber in
    /// the band where accuracy starts sliding, red where it will not work.
    /// Thresholds are the measured ones, not guesses.
    private static func cellSizeTint(_ pixels: Int) -> Color {
        if pixels >= 96 { return Color(hex: 0x6FCF97) }
        if pixels >= 64 { return Color(hex: 0xF2C94C) }
        return Color(hex: 0xEB5757)
    }

    /// ~2000px is where a 4K buffer starts; below it the device fell back to
    /// the preview-sized one and every cell on it is capped no matter how the
    /// paper is framed.
    private static func frameSizeTint(_ pixels: Int) -> Color {
        pixels >= 2000 ? .white.opacity(0.7) : Color(hex: 0xF2C94C)
    }

    // Latency/inlier HUD, debug builds only — for calibrating on device.
    private func debugSuffix(_ live: LiveScanEngine.Update) -> String {
        #if DEBUG
        return live.alignMillis > 0
            ? "・\(Int(live.alignMillis))ms・\(live.inlierCount)pt"
            : ""
        #else
        return ""
        #endif
    }

    /// Finishes, unless doing so would quietly abandon a side nobody turned to.
    ///
    /// Forgetting to flip the paper is the ordinary mistake, and its cost is
    /// silent: the back's cells simply file as unanswered, against the student.
    /// A prompt that names the pages is the cheap fix.
    @MainActor
    private func attemptFinish() {
        guard let engine = liveEngine else { return }
        let pending = engine.pagesLeftBehind
        if pending.isEmpty {
            finishLiveSession()
        } else {
            leftBehind = pending
        }
    }

    // Ends the paper without ending the session: no camera stop, no frozen
    // frame, no navigation. The result is filed immediately — the loop only
    // stays safe because nothing waits on the teacher to look at it.
    @MainActor
    private func finishLiveSession() {
        leftBehind = nil
        guard let engine = liveEngine, let result = engine.finish() else { return }
        let paper = GradingStore.record(from: result, templateID: engine.templateIdentifier)
        papers.store(paper, cells: engine.capturedCells())
        model.lastResult = result
        withAnimation(.spring(duration: 0.3)) { completedPaper = paper }
    }

    /// Clears the finished paper and starts the next one. The teacher's tap is
    /// the only signal here that is certain — detecting "the paper changed"
    /// from the camera cannot separate a new sheet from a pan across the old
    /// one, least of all at the close range these cells need.
    @MainActor
    private func nextPaper() {
        completedPaper = nil
        liveEngine?.reset()
    }

}

// MARK: - Guide frame

private struct GuideFrameView: View {

    @State private var sweepOffset: CGFloat = 0
    @State private var pulse = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .stroke(.white.opacity(0.85), lineWidth: 2)
                    .padding(-8)
                    .opacity(pulse ? 0.85 : 0.6)
                    .shadow(color: .white.opacity(0.25), radius: 8)

                // Scanning sweep. Always running now: the frame used to turn
                // brand green and stop sweeping once Vision had locked onto a
                // rectangle, which was the cue that a still capture was about
                // to fire. Nothing captures a still any more, so the lock had
                // nothing left to announce.
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
                .fill(.white)
                .frame(width: 28, height: 4)
            RoundedRectangle(cornerRadius: 2)
                .fill(.white)
                .frame(width: 4, height: 28)
        }
        .frame(width: 28, height: 28, alignment: .topLeading)
        .rotationEffect(.degrees(degrees))
    }
}

// MARK: - Status pill

private struct StatusPillView: View {
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
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

