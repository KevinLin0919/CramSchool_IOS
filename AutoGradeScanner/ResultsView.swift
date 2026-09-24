import SwiftUI

// Screen 3 — the stack that was just graded.
//
// Two decisions shape this page.
//
// The backdrop is the master sheet, not a photograph of the student's paper.
// The master is already cached, already rectified, and looks the same for
// every student, so reviewing forty papers stops meaning re-orienting to forty
// camera angles. It also costs nothing to obtain: requiring a full-page shot
// would mean asking the teacher to step back, and a page photographed from far
// enough away to fit in frame is exactly the resolution at which nothing can
// be read anyway.
//
// The consequence is that misalignment becomes invisible up there — boxes are
// drawn from template coordinates, so they are always perfectly placed whether
// or not the scan was. The cell crops below are what expose it: a cell sampled
// from the wrong place shows blank paper or a printed character rather than
// handwriting. They are the evidence, not decoration, and the layout treats
// them as the main content.
struct ResultsView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var papers = GradingStore.shared

    @State private var index = 0
    /// Whether the opening position has been chosen yet.
    ///
    /// Not a formality. The stack can arrive after this screen does — a
    /// sign-in restores a term of grading in the background — so "open on the
    /// newest" has to wait for there to be a newest. And it must happen once:
    /// a teacher who has paged back to the third paper should not be dragged
    /// to the end because one more record finished downloading.
    @State private var hasPositioned = false
    @State private var correcting: StoredAnswer?
    /// Sheets already loaded, keyed by the paper that named them.
    ///
    /// Keyed by paper rather than by template because the paper is what says
    /// which pictures it was graded against. Two papers from the same template
    /// can legitimately want different sheets — one filed before its page was
    /// replaced, one after — and a template-keyed cache would hand both the
    /// same answer.
    ///
    /// A pager also keeps the neighbouring papers alive so they can follow the
    /// finger, so a single shared set would have drawn the paper being swiped
    /// toward over the one being left, right up until the swipe finished.
    @State private var sheets: [UUID: SheetSet] = [:]
    @State private var shownPage = 0
    @State private var showsClearConfirm = false

    /// What a paper's backdrop resolved to. `failure` is a state of its own:
    /// without it a sheet that cannot be fetched shows a spinner that never
    /// stops, which is how demo papers reviewed after enrolling used to look.
    private struct SheetSet {
        var images: [UIImage?]
        var failure: String?
    }

    private var current: StoredPaper? {
        guard papers.papers.indices.contains(index) else { return papers.papers.last }
        return papers.papers[index]
    }

    var body: some View {
        Group {
            if papers.papers.isEmpty {
                emptyState
            } else {
                content
            }
        }
        .onChange(of: papers.papers.count) { _, count in
            if index >= count { index = max(0, count - 1) }
            positionAtNewest()
        }
        .onAppear { positionAtNewest() }
        .sheet(item: $correcting) { answer in
            if let paper = current {
                CorrectionSheet(paperID: paper.id, startAt: answer.questionNo)
            }
        }
    }

    /// Two different nothings. Someone who has never graded is being told
    /// where to start; someone who just signed back in after a term is
    /// watching their own work come down, and telling them there is none
    /// would be both wrong and alarming.
    /// Opens on the paper just graded rather than the oldest one in the pile.
    ///
    /// The stack is chronological, so starting at index 0 started as far from
    /// the teacher as the stack is long: finish a class set of thirty and the
    /// app offers you the first one, twenty-nine swipes from the one you were
    /// just holding.
    private func positionAtNewest() {
        guard !hasPositioned, !papers.papers.isEmpty else { return }
        index = papers.papers.count - 1
        hasPositioned = true
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if papers.isRestoring {
                ProgressView().tint(AG.brand)
                Text("正在還原批改紀錄")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AG.fg1)
                Text("從伺服器取回你先前上傳的結果")
                    .font(.system(size: 13))
                    .foregroundStyle(AG.fg2)
            } else {
                Image(systemName: "chart.bar")
                    .font(.system(size: 34))
                    .foregroundStyle(AG.fg3)
                Text("尚無批改結果")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AG.fg1)
                Text("先選擇考卷並掃描，結果會顯示在這裡")
                    .font(.system(size: 13))
                    .foregroundStyle(AG.fg2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AG.bg2)
    }

    // MARK: - Layout

    // An iPad has room to show the sheet and the answers at once; a phone
    // stacks them, with the crops taking the space because they are what gets
    // read.
    /// Takes no paper on purpose. Handing it the current one would rebuild the
    /// whole pager every time the selection moved — including the neighbours
    /// mid-drag, which is the one moment they need to stay put.
    private var content: some View {
        RegularWidth { isRegular in
            ZStack(alignment: .top) {
                // A real pager rather than a swipe that commits past a
                // threshold. Under a threshold, a swipe that falls short does
                // nothing at all — no movement, no hint — so nobody who does
                // not already know the gesture exists ever finds out. Dragging
                // the paper with the finger and letting it fall back is the
                // behaviour that teaches itself.
                TabView(selection: $index) {
                    ForEach(Array(papers.papers.enumerated()), id: \.element.id) { position, item in
                        paperBody(item, isRegular: isRegular)
                            .task(id: item.id) { await loadSheets(for: item) }
                            .tag(position)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                // Floats, rather than sitting in a stack above the content.
                // That is what gives the glass something to sample: a bar over
                // a flat background has nothing to refract and may as well be
                // a tinted rectangle.
                if let paper = current {
                    topNav(paper)
                }
            }
            .background(AG.bg2)
        }
    }

    /// Leaves room at the top for the floating nav, inside the scroll rather
    /// than outside it, so content passes underneath instead of stopping short.
    private static let navInset: CGFloat = 46

    @ViewBuilder
    private func paperBody(_ paper: StoredPaper, isRegular: Bool) -> some View {
        if isRegular {
            HStack(alignment: .top, spacing: 0) {
                ScrollView { scrollingColumn(sheetPanel(paper)) }
                    .frame(maxWidth: .infinity)
                Rectangle().fill(AG.border2).frame(width: 1)
                ScrollView { scrollingColumn(cellPanel(paper)) }
                    .frame(width: 380)
            }
        } else {
            ScrollView {
                scrollingColumn(VStack(alignment: .leading, spacing: 18) {
                    sheetPanel(paper)
                    cellPanel(paper)
                })
            }
        }
    }

    /// The insets every scrolling column needs, in one place so a layout
    /// cannot be given some of them and not others.
    ///
    /// The bottom one is room for the tab bar, which RootView floats over this
    /// screen rather than stacking beneath it. The two-column layout once had
    /// none: the last rows of the answer column sat under the bar with no way
    /// to scroll them clear. Measured from the physical edge, as the bar
    /// itself is, rather than a number tuned by eye on one phone.
    private func scrollingColumn(_ content: some View) -> some View {
        content
            .padding(16)
            .padding(.top, Self.navInset)
            .padding(.bottom, AG.padding(above: AG.bottomChromeClearance))
    }


    /// Moves the pager, and lets the pager decide how.
    ///
    /// Not wrapped in `withAnimation`. A paged `TabView` is a
    /// `UIPageViewController` underneath and runs its own transition; an
    /// explicit animation transaction around the selection write leaves the
    /// two disagreeing — `index` moves, the page does not, and every tap
    /// after that is computed from a number the screen is not showing. The
    /// arrows stopped working the moment the swipe pager replaced the old
    /// threshold gesture, and this is why.
    private func goTo(_ target: Int) {
        guard papers.papers.indices.contains(target), target != index else { return }
        index = target
    }

    // MARK: - Top: the master sheet with boxes

    private func sheetPanel(_ paper: StoredPaper) -> some View {
        // The paper's own account of its shape, never the template's current
        // one. A result filed when this exam was single-sided must not grow a
        // back the moment someone adds one to the template.
        let pages = paper.pagesOrInferred
        let set = sheets[paper.id]
        // A paper with fewer sides than the one before it must not inherit its
        // page: the strip would point at a side this paper does not have.
        let page = min(shownPage, max(0, pages.count - 1))
        // Two optionals collapse here: the set may not have loaded, and a page
        // within a loaded set may have no picture.
        let sheet: UIImage? = set.flatMap { $0.images[safe: page] ?? nil }
        return VStack(alignment: .leading, spacing: 8) {
            summaryRow(paper)

            // The same page control the scanner uses, for the same reason: a
            // box belongs to one side of the paper, and drawing every side's
            // boxes over one master would scatter the back's cells across the
            // front at coordinates that look plausible.
            if pages.count > 1 {
                pageSwitcher(paper, pages: pages, shown: page)
            }

            ZStack {
                if let sheet {
                    Image(uiImage: sheet)
                        .resizable()
                        .scaledToFit()
                        .overlay(GeometryReader { geo in
                            ForEach(paper.answers.filter { $0.page == page },
                                    id: \.questionNo) { answer in
                                if let rect = answer.rect {
                                    boxMarker(answer, in: rect, size: geo.size)
                                }
                            }
                        })
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AG.bg1)
                        .frame(height: 220)
                        .overlay {
                            // Say what went wrong rather than spin forever.
                            // The cell crops below still carry the grading, so
                            // a missing backdrop is a degraded page, not a
                            // broken one.
                            if let failure = set?.failure {
                                Text(failure)
                                    .font(.system(size: 13))
                                    .foregroundStyle(AG.fg2)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            } else {
                                ProgressView().tint(AG.brand)
                            }
                        }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AG.border2, lineWidth: 1))
        }
    }

    private func pageSwitcher(_ paper: StoredPaper,
                             pages: [StoredPage],
                             shown: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(pages.indices, id: \.self) { page in
                let unsure = paper.answers
                    .filter { $0.page == page && $0.effectiveVerdict == .unsure }.count
                Button {
                    shownPage = page
                } label: {
                    HStack(spacing: 5) {
                        Text(pages[page].label)
                            .font(.system(size: 13, weight: page == shown ? .semibold : .regular))
                        // Where the remaining work is, so the page holding it
                        // is findable without opening every one.
                        if unsure > 0 {
                            Text("\(unsure)")
                                .font(.system(size: 11, weight: .bold).monospacedDigit())
                                .foregroundStyle(AG.warn)
                        }
                    }
                    .foregroundStyle(page == shown ? AG.fg1 : AG.fg2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(page == shown ? AG.bg1 : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(AG.bg3)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func boxMarker(_ answer: StoredAnswer, in rect: CGRect, size: CGSize) -> some View {
        let color = AG.color(for: answer.effectiveVerdict)
        let frame = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                           width: rect.width * size.width, height: rect.height * size.height)
        return RoundedRectangle(cornerRadius: 2)
            .stroke(color, lineWidth: 2)
            .background(RoundedRectangle(cornerRadius: 2).fill(color.opacity(0.14)))
            .frame(width: max(frame.width, 6), height: max(frame.height, 6))
            .overlay(alignment: .topLeading) {
                Text("\(answer.questionNo)")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                    .offset(x: -2, y: -9)
            }
            .position(x: frame.midX, y: frame.midY)
    }

    private func summaryRow(_ paper: StoredPaper) -> some View {
        HStack(spacing: 12) {
            Text(paper.templateTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AG.fg1)
                .lineLimit(1)
            Spacer()
            tally(AG.ok, paper.correctCount)
            tally(AG.bad, paper.wrongCount)
            if paper.unsureCount > 0 { tally(AG.warn, paper.unsureCount) }
        }
    }

    private func tally(_ color: Color, _ count: Int) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(count)")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(AG.fg2)
        }
    }

    // MARK: - Bottom: what the model actually saw

    private func cellPanel(_ paper: StoredPaper) -> some View {
        let pages = paper.pagesOrInferred
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("各題作答")
                    .font(.system(size: 12, weight: .semibold))
                    .kerning(0.3)
                    .foregroundStyle(AG.fg2)
                Spacer()
                if paper.unsureCount > 0 {
                    Text("點一格可修正")
                        .font(.system(size: 11))
                        .foregroundStyle(AG.fg3)
                }
            }

            // Grouped by side once there is more than one. Question numbers
            // run continuously across the whole paper — the server's schema
            // leaves no choice — so a flat grid of Q1…Q24 gives no way to tell
            // which of six sides a cell came from, which is exactly what a
            // teacher looking for the page still owing corrections needs.
            if pages.count > 1 {
                ForEach(pages.indices, id: \.self) { page in
                    let answers = paper.answers.filter { $0.page == page }
                    if !answers.isEmpty {
                        Text(pages[page].label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AG.fg3)
                            .padding(.top, page == 0 ? 0 : 4)
                        cellGrid(paper, answers)
                    }
                }
            } else {
                cellGrid(paper, paper.answers)
            }
        }
    }

    private func cellGrid(_ paper: StoredPaper, _ answers: [StoredAnswer]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
            ForEach(answers, id: \.questionNo) { answer in
                cellCard(paper, answer)
            }
        }
    }

    private func cellCard(_ paper: StoredPaper, _ answer: StoredAnswer) -> some View {
        let verdict = answer.effectiveVerdict
        let color = AG.color(for: verdict)

        return Button {
            correcting = answer
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Text("Q\(answer.questionNo)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(AG.fg2)
                    Spacer()
                    if answer.teacherValue != nil {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(AG.brand)
                    }
                    Image(systemName: AG.glyph(for: verdict))
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Circle().fill(color))
                }

                // The crop recognition read. A cell that shows blank paper or
                // a printed character rather than handwriting is how a bad
                // alignment surfaces — the sheet above cannot show it.
                Group {
                    if let image = papers.cellImage(paper, question: answer.questionNo) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Text("—")
                            .font(.system(size: 20))
                            .foregroundStyle(AG.fg4)
                    }
                }
                .frame(height: 52)
                .frame(maxWidth: .infinity)
                .background(Color(hex: 0xF3EEE3))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                HStack(spacing: 3) {
                    // What the model read, even when it was not confident
                    // enough to act on it. `unsure` covers two different
                    // things — a cell nothing could be read from, and one
                    // read several ways across frames without agreement —
                    // and only the second has a reading worth showing. It is
                    // the one piece of evidence that says whether the cell
                    // was misread or the crop was sampled off the answer, and
                    // hiding it behind a question mark left the crop below
                    // with nothing to compare against. Yellow already says
                    // "not settled"; the glyph does not have to.
                    Text(displayValue(answer))
                        .font(.system(size: 15, weight: .bold).monospaced())
                        .foregroundStyle(color)
                    Text("→")
                        .font(.system(size: 10))
                        .foregroundStyle(AG.fg4)
                    Text(answer.expected.isEmpty ? "—" : answer.expected)
                        .font(.system(size: 15, weight: .semibold).monospaced())
                        .foregroundStyle(AG.fg2)
                }
                .lineLimit(1)
            }
            .padding(9)
            .background(AG.bg1)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(verdict == .unsure ? color.opacity(0.7) : AG.border2,
                        lineWidth: verdict == .unsure ? 1.5 : 1))
        }
        .buttonStyle(.plain)
    }

    private func displayValue(_ answer: StoredAnswer) -> String {
        if let teacher = answer.teacherValue, !teacher.isEmpty { return teacher }
        if !answer.recognized.isEmpty { return answer.recognized }
        // Nothing was read at all — a different state from "read, unsure",
        // and the only one the question mark honestly describes.
        return answer.effectiveVerdict == .unsure ? "？" : "—"
    }

    // MARK: - Nav

    private func topNav(_ paper: StoredPaper) -> some View {
        HStack(spacing: 8) {
            Button {
                model.screen = .scan
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold))
                    Text("繼續掃描").font(.system(size: 16))
                }
                .foregroundStyle(AG.brand)
            }

            Spacer()

            Menu {
                ShareLink(item: shareText(paper)) { Label("分享文字", systemImage: "square.and.arrow.up") }
                Button("清除這一疊", role: .destructive) { showsClearConfirm = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(AG.brand)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
        // Centred as an overlay rather than between two Spacers: the left
        // button carries an icon and two words, the right a single glyph, so
        // spacers split the leftover space unevenly and push the counter off
        // centre by the difference.
        .overlay {
            HStack(spacing: 12) {
                pagerButton("chevron.left", enabled: index > 0) { goTo(index - 1) }
                // Paging is by position in the stack. Which student a paper
                // belongs to is not recorded yet, and guessing would put a
                // name on a record nobody verified.
                Text("第 \(index + 1) / \(papers.papers.count) 份")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AG.fg1)
                pagerButton("chevron.right", enabled: index < papers.papers.count - 1) {
                    goTo(index + 1)
                }
            }
        }
        .floatingGlass(in: Capsule())
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .confirmationDialog("清除這一疊批改結果？", isPresented: $showsClearConfirm,
                            titleVisibility: .visible) {
            Button("清除 \(papers.papers.count) 份", role: .destructive) {
                papers.clearAll()
                index = 0
            }
        } message: {
            // The one place on this screen where upload state changes a
            // decision, so the one place it is mentioned.
            Text(papers.pendingUploadCount > 0
                 ? "其中 \(papers.pendingUploadCount) 份還沒上傳到伺服器，清除後無法復原。"
                 : "這些結果都已上傳到伺服器，這裡只清除裝置上的紀錄。")
        }
    }

    private func pagerButton(_ icon: String, enabled: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(enabled ? AG.brand : AG.fg4)
                // A 15pt glyph is a 15pt target, which is a third of what a
                // finger needs. Widened to the bar's own height, and no
                // further: this sits in an overlay centred over 繼續掃描 on
                // the left, and a target wide enough to reach it would start
                // eating that button's taps instead.
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
    }

    private func shareText(_ paper: StoredPaper) -> String {
        let wrong = paper.answers.filter { $0.effectiveVerdict == .wrong }
            .map { "Q\($0.questionNo)" }.joined(separator: "、")
        let unsure = paper.answers.filter { $0.effectiveVerdict == .unsure }
            .map { "Q\($0.questionNo)" }.joined(separator: "、")

        // Counts, not a score. Questions are not worth the same marks, and
        // this text gets pasted into messages someone's parent may read.
        var text = "\(paper.templateTitle) 批改結果：答對 \(paper.correctCount)/\(paper.total) 題"
        if !wrong.isEmpty { text += "\n答錯：\(wrong)" }
        if !unsure.isEmpty { text += "\n待確認：\(unsure)" }
        return text
    }

    /// Fetches the sheets one paper says it was graded against.
    ///
    /// Three sources, in the order they can be trusted. A demo paper's sheet
    /// ships in the app and is the only thing that can answer for it — the
    /// template ids it names exist on no server, so an enrolled device asking
    /// the server about them gets a 404 and, before this, a spinner that never
    /// stopped. A paper that names its image ids gets exactly those pictures,
    /// which is the whole point. Anything older names nothing, and falls back
    /// to the template as it stands today — the same guess as before, but now
    /// clamped to the number of sides the paper actually has.
    ///
    /// Nothing is recorded once the task is cancelled — swiping past a paper
    /// tears its task down mid-fetch, and storing the `CancellationError` that
    /// arrives would cache "cancelled" as this paper's permanent answer. The
    /// guard at the top would then never let it try again.
    private func loadSheets(for paper: StoredPaper) async {
        guard sheets[paper.id] == nil else { return }
        let pages = paper.pagesOrInferred

        if paper.isDemo == true {
            let demo = DemoData.resolved(id: paper.templateID)
            sheets[paper.id] = SheetSet(
                images: pages.indices.map { demo?.pages[safe: $0]?.master },
                failure: demo == nil ? "找不到這份示範考卷的底圖" : nil)
            return
        }

        if pages.contains(where: { $0.imageID != nil }) {
            var images: [UIImage?] = []
            var failure: String?
            for page in pages {
                guard let imageID = page.imageID else { images.append(nil); continue }
                do {
                    images.append(try await TemplateStore.shared.master(imageID: imageID))
                } catch {
                    images.append(nil)
                    failure = failure ?? error.localizedDescription
                }
            }
            guard !Task.isCancelled else { return }
            sheets[paper.id] = SheetSet(images: images, failure: failure)
            return
        }

        do {
            let resolved = try await TemplateStore.shared.resolve(id: paper.templateID)

            // Position in the template is not evidence of anything.
            //
            // A paper filed when this exam was one sheet — the back of it,
            // graded on its own — would take page 0 of a template that has
            // since grown a front, and every box would land somewhere
            // plausible and wrong. What the record does carry is the boxes it
            // graded, in the coordinates of the page they were measured on.
            // Ask which page still has those boxes.
            var images: [UIImage?] = []
            var unmatched = 0
            for slot in pages.indices {
                let answers = paper.answers.filter { $0.page == slot }
                guard let matched = Self.page(matching: answers, in: resolved) else {
                    images.append(nil)
                    unmatched += 1
                    continue
                }
                // Through the id where there is one, so a stack of forty
                // legacy papers shares one decode per side like every other
                // path here — `page.master` is a fresh decode each time.
                if let imageID = matched.imageID {
                    images.append(try? await TemplateStore.shared.master(imageID: imageID))
                } else {
                    images.append(matched.master)
                }
            }
            guard !Task.isCancelled else { return }
            sheets[paper.id] = SheetSet(
                images: images,
                failure: unmatched == 0 ? nil
                    : "這份考卷的題目位置已經和目前的「\(paper.templateTitle)」對不上了，"
                    + "無法確定當初批改的是哪一面，所以不顯示底圖。\n"
                    + "下方各題的作答與判定仍然是正確的。")
        } catch {
            guard !Task.isCancelled else { return }
            sheets[paper.id] = SheetSet(images: pages.map { _ in nil },
                                        failure: error.localizedDescription)
        }
    }
}

extension ResultsView {
    /// The page whose boxes are these boxes.
    ///
    /// A record written before papers described themselves names no image,
    /// but it still carries every box it graded, and those are in the
    /// coordinates of the page they were measured on. If the template still
    /// has a page holding them, that page is the sheet this paper was marked
    /// against — established rather than assumed.
    ///
    /// Ambiguity is treated as no answer. Two pages that both hold every box
    /// would mean the paper genuinely could have been either, and picking one
    /// would be the guess this exists to avoid.
    static func page(matching answers: [StoredAnswer],
                     in resolved: ResolvedTemplate) -> ResolvedTemplate.Page? {
        let rects = answers.compactMap(\.rect)
        guard !rects.isEmpty else { return nil }

        let matches = resolved.pages.filter { page in
            rects.allSatisfy { rect in
                page.questions.contains { sameCell($0.box, rect) }
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Centres only, and deliberately.
    ///
    /// A box's size is an artefact of how wide someone drew it; its centre is
    /// which printed cell it sits on, and that is the question here. The two
    /// come apart in practice: a master re-rendered at a different resolution
    /// keeps every cell in the same place as a fraction of the page, but a
    /// box laid out in pixels on the larger rendering normalises to a
    /// different width entirely. Comparing sizes would reject a page these
    /// boxes plainly came from.
    ///
    /// 0.01 of a page is about 26px across a 2573px master — comfortably
    /// inside one answer cell, so three centres landing on three of a page's
    /// cells is not something that happens to the wrong page.
    private static func sameCell(_ a: CGRect, _ b: CGRect) -> Bool {
        let t: CGFloat = 0.01
        return abs(a.midX - b.midX) < t && abs(a.midY - b.midY) < t
    }
}

private extension Array {
    /// Reading past the end here means the record and the pictures disagree
    /// about how many sides there are, which is a thing to draw around rather
    /// than crash on.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Correction

// What the teacher is asked here is not "is this right" — it is "what did the
// student write". Those are different jobs, and the screen used to do the
// second while showing everything needed for the first: the standard answer
// appeared three times, once as a green button labelled 改為正確.
//
// That button was the path of least resistance. A teacher holding a stack,
// looking at an unreadable smudge, had one tap that made the problem go away
// and agreed with the key — and the label it produced then went into
// `exports/corrections` as evidence about handwriting. A label written while
// looking at the expected answer is not evidence; worse, nothing afterwards
// can tell which labels were clean.
//
// So the key is gone from this screen, the verdict is gone with it (the
// results grid is already coloured, one gesture away), and the input is
// whatever the question type actually needs.
private struct CorrectionSheet: View {
    let paperID: UUID

    @Environment(\.dismiss) private var dismiss
    @StateObject private var papers = GradingStore.shared

    /// Which cell is being looked at. A cursor, not a fixed answer: the
    /// bottom button walks the queue without closing and reopening a sheet
    /// for each cell.
    @State private var questionNo: Int
    /// Digits and free text, held until the teacher moves on. A keystroke is
    /// not an answer — "2" on the way to "20" must not be filed as an answer
    /// of two.
    @State private var typed = ""

    init(paperID: UUID, startAt question: Int) {
        self.paperID = paperID
        _questionNo = State(initialValue: question)
    }

    /// Read live from the store, never from a snapshot. The sheet now stays
    /// open across corrections, so a captured copy would be describing the
    /// paper as it was when the sheet opened.
    private var paper: StoredPaper? {
        papers.papers.first { $0.id == paperID }
    }

    private var answer: StoredAnswer? {
        paper?.answers.first { $0.questionNo == questionNo }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let paper, let answer {
                    sheet(paper, answer)
                } else {
                    // The paper was cleared while this was open.
                    Color.clear.onAppear { dismiss() }
                }
            }
            .background(AG.bg2)
            .navigationTitle("第 \(questionNo) 題")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { commit(); dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        // Typing is only filed when the teacher leaves the cell, and swiping
        // the sheet away is leaving it. Losing what someone just typed
        // because they dismissed rather than pressed a button would be the
        // app deciding their work did not count.
        .onDisappear { commit() }
    }

    private func sheet(_ paper: StoredPaper, _ answer: StoredAnswer) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 18) {
                    evidence(paper, answer)

                    Text("這格學生寫了什麼？")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AG.fg2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    input(answer)
                    escapes(answer)
                }
                .padding(20)
            }
            nextBar(paper)
        }
    }

    // MARK: - The crop

    @ViewBuilder
    private func evidence(_ paper: StoredPaper, _ answer: StoredAnswer) -> some View {
        if let image = papers.cellImage(paper, question: answer.questionNo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 170)
                .background(Color(hex: 0xF3EEE3))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AG.border2, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(AG.bg1)
                .frame(height: 110)
                .overlay {
                    Text("這一格沒有留下裁切影像")
                        .font(.system(size: 13))
                        .foregroundStyle(AG.fg3)
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AG.border2, lineWidth: 1))
        }
    }

    // MARK: - Input, by what the question actually is

    @ViewBuilder
    private func input(_ answer: StoredAnswer) -> some View {
        switch answer.kind {
        case .mark:
            grid(["○", "✕"], columns: 2, current: answer.teacherValue)
        case .choice:
            // The template's own alphabet. Without one — an older record, or
            // a paper with too few distinct answers to infer from — fall back
            // to typing rather than inventing options that may not exist.
            if let options = answer.options, options.count >= 3 {
                grid(options, columns: Self.columns(for: options.count),
                     current: answer.teacherValue)
            } else {
                freeText(answer, keyboard: .default)
            }
        case .digits:
            keypad(answer)
        case .unsupported:
            freeText(answer, keyboard: .default)
        }
    }

    /// How to lay a fixed set out.
    ///
    /// Four goes two-by-two rather than four-across — the common case is four
    /// choices, and a row of four on a phone is four narrow targets with
    /// three quarters of the sheet empty below them. Two rows of two are
    /// twice the width each and land under the thumb.
    ///
    /// Five would leave one item alone on a second row at two columns, so
    /// anything else takes three or fewer and wraps evenly.
    static func columns(for count: Int) -> Int {
        count == 4 ? 2 : min(count, 3)
    }

    /// Big targets, one tap, filed immediately.
    ///
    /// Filed on tap rather than on leaving, because for a fixed set the tap
    /// IS the whole answer — there is no half-typed state to protect.
    private func grid(_ values: [String], columns: Int, current: String?) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                 count: columns),
                  spacing: 10) {
            ForEach(values, id: \.self) { value in
                let selected = current == value
                Button {
                    file(value)
                } label: {
                    Text(value)
                        .font(.system(size: 40, weight: .bold).monospaced())
                        .foregroundStyle(selected ? Color.white : AG.fg1)
                        .frame(maxWidth: .infinity)
                        // Sized to the room the sheet actually has. The
                        // detent stays .large for every question type on
                        // purpose — resizing as the cursor walks the queue
                        // would move the bottom button out from under a
                        // thumb mid-tap — so a two-row layout may as well
                        // use the space rather than leave it blank.
                        .frame(height: columns == 2 ? 96 : 76)
                        .background(selected ? AG.brand : AG.bg1)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16)
                            .stroke(selected ? AG.brand : AG.borderStrong,
                                    lineWidth: selected ? 2 : 1.5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Calculator order — 7 on top — because the hand reaching for digits
    /// mid-marking is the one that uses a desk calculator, not the one that
    /// dials. No confirm key: the bottom button already commits.
    private func keypad(_ answer: StoredAnswer) -> some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Text(typed.isEmpty ? "輸入數字" : typed)
                    .font(.system(size: 30, weight: .bold).monospaced())
                    .foregroundStyle(typed.isEmpty ? AG.fg4 : AG.fg1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .padding(.horizontal, 14)
            .background(AG.bg1)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AG.borderStrong, lineWidth: 1.5))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                ForEach([7, 8, 9, 4, 5, 6, 1, 2, 3], id: \.self) { n in
                    key("\(n)") { if typed.count < 6 { typed += "\(n)" } }
                }
                key("C", muted: true) { typed = "" }
                key("0") { if typed.count < 6 { typed += "0" } }
                key("⌫", muted: true) { typed = String(typed.dropLast()) }
            }
        }
        .onAppear { typed = reservedFree(answer.teacherValue) ?? "" }
    }

    private func key(_ label: String, muted: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: muted ? 20 : 24, weight: .bold).monospaced())
                .foregroundStyle(muted ? AG.fg2 : AG.fg1)
                .frame(maxWidth: .infinity)
                .frame(height: 56)
                .background(AG.bg1)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(AG.borderStrong, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    private func freeText(_ answer: StoredAnswer, keyboard: UIKeyboardType) -> some View {
        TextField("直接輸入", text: $typed)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 20).monospaced())
            .keyboardType(keyboard)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onAppear { typed = reservedFree(answer.teacherValue) ?? "" }
    }

    // MARK: - The two things that are not a value

    private func escapes(_ answer: StoredAnswer) -> some View {
        HStack(spacing: 10) {
            escape("沒有答案", value: TeacherMark.blank, current: answer.teacherValue)
            escape("無法辨識", value: TeacherMark.unreadable, current: answer.teacherValue)
        }
    }

    private func escape(_ label: String, value: String, current: String?) -> some View {
        let selected = current == value
        return Button {
            file(value)
        } label: {
            Text(label)
                .font(.system(size: 15, weight: selected ? .bold : .regular))
                .foregroundStyle(selected ? AG.brand : AG.fg2)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(selected ? AG.brandSoft : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? AG.brand : AG.borderStrong,
                                  style: StrokeStyle(lineWidth: selected ? 1.5 : 1,
                                                     dash: selected ? [] : [4, 3])))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Walking the queue

    private func nextBar(_ paper: StoredPaper) -> some View {
        // Counted excluding this cell, because pressing the button leaves it.
        let waiting = paper.answers.filter { $0.awaitsReview && $0.questionNo != questionNo }
        return VStack(spacing: 0) {
            Divider()
            Button {
                commit()
                if let next = paper.nextAwaitingReview(after: questionNo) {
                    questionNo = next.questionNo
                    typed = ""
                } else {
                    dismiss()
                }
            } label: {
                Text(waiting.isEmpty ? "完成" : "下一個待確認 (\(waiting.count))")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(waiting.isEmpty ? AG.brand : Color.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(waiting.isEmpty ? AG.bg1 : AG.brand)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay(RoundedRectangle(cornerRadius: 14)
                        .stroke(AG.brand, lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .background(AG.bg1)
    }

    // MARK: - Filing

    /// A fixed-set answer, filed the moment it is chosen.
    private func file(_ value: String) {
        guard let paper else { return }
        // Tapping the current choice again clears it, which is the only way
        // back to "the device's reading" now that the explicit clear button
        // is gone.
        let current = answer?.teacherValue
        papers.correct(paper: paper, question: questionNo,
                       to: current == value ? nil : value)
        typed = ""
    }

    /// Whatever is in the typing buffer, filed on the way out of this cell.
    private func commit() {
        guard let paper, let answer else { return }
        guard answer.kind == .digits || answer.kind == .unsupported else { return }
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        // Unchanged buffers must not write: re-filing the same value would
        // bump the revision and re-upload the paper for nothing.
        let existing = reservedFree(answer.teacherValue) ?? ""
        guard trimmed != existing else { return }
        papers.correct(paper: paper, question: questionNo,
                       to: trimmed.isEmpty ? nil : trimmed)
    }

    /// The stored value, unless it is one of the reserved dispositions —
    /// those belong to the escape buttons, not to the text buffer.
    private func reservedFree(_ value: String?) -> String? {
        guard let value, !TeacherMark.isReserved(value) else { return nil }
        return value
    }
}
