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
        }
        .sheet(item: $correcting) { answer in
            if let paper = current {
                CorrectionSheet(paper: paper, answer: answer)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
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
                ScrollView { sheetPanel(paper).padding(16).padding(.top, Self.navInset) }
                    .frame(maxWidth: .infinity)
                Rectangle().fill(AG.border2).frame(width: 1)
                ScrollView { cellPanel(paper).padding(16).padding(.top, Self.navInset) }
                    .frame(width: 380)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sheetPanel(paper)
                    cellPanel(paper)
                }
                .padding(16)
                .padding(.top, Self.navInset)
                .padding(.bottom, 80)
            }
        }
    }


    private func goTo(_ target: Int) {
        guard papers.papers.indices.contains(target), target != index else { return }
        withAnimation(.easeInOut(duration: 0.28)) { index = target }
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
                    Text(answer.effectiveVerdict == .unsure && answer.teacherValue == nil
                         ? "？" : displayValue(answer))
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
        let value = answer.teacherValue ?? answer.recognized
        return value.isEmpty ? "—" : value
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

            // The template has to still be the shape this paper was graded
            // against, or its pages are not the ones this record means.
            //
            // A paper filed when this exam was one sheet, against a template
            // that now has two, does not get page 0 — that page is whatever
            // was added in front, and drawing a back page's boxes on it puts
            // every cell somewhere plausible and wrong. This exact case is
            // sitting on the device already: the papers graded against the
            // single-sided version of an exam that has since grown a front.
            //
            // Matching counts is the only signal an old record leaves. It
            // does not catch a page whose picture was swapped in place, which
            // nothing here can — but that one is far rarer than a template
            // gaining a side.
            guard resolved.pages.count == pages.count else {
                sheets[paper.id] = SheetSet(
                    images: pages.map { _ in nil },
                    failure: "這份考卷後來從 \(pages.count) 面改成 \(resolved.pages.count) 面，"
                           + "已經無法確定當初批改的是哪一面，所以不顯示底圖。\n"
                           + "下方各題的作答與判定仍然是正確的。")
                return
            }

            var images: [UIImage?] = []
            for slot in pages.indices {
                guard let page = resolved.pages[safe: slot] else { images.append(nil); continue }
                // Through the id where there is one, so a stack of forty
                // legacy papers shares one decode per side like every other
                // path here — `page.master` is a fresh decode each time.
                if let imageID = page.imageID {
                    images.append(try? await TemplateStore.shared.master(imageID: imageID))
                } else {
                    images.append(page.master)
                }
            }
            guard !Task.isCancelled else { return }
            sheets[paper.id] = SheetSet(images: images, failure: nil)
        } catch {
            guard !Task.isCancelled else { return }
            sheets[paper.id] = SheetSet(images: pages.map { _ in nil },
                                        failure: error.localizedDescription)
        }
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

// The teacher's answer outranks the model's. Three buttons cover almost every
// case: the model was right after all, it is the standard answer, or neither.
private struct CorrectionSheet: View {
    let paper: StoredPaper
    let answer: StoredAnswer

    @Environment(\.dismiss) private var dismiss
    @StateObject private var papers = GradingStore.shared
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    evidence
                    currentState

                    VStack(alignment: .leading, spacing: 10) {
                        Text("這格學生實際寫了什麼？")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AG.fg2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Two candidates, each labelled with where it came
                        // from and what picking it does. They used to be two
                        // identical green buttons showing only a value, so
                        // telling "what the device read" from "the standard
                        // answer" meant matching digits against a caption row
                        // somewhere else on the screen.
                        HStack(spacing: 10) {
                            if !answer.recognized.isEmpty {
                                choice(answer.recognized, source: "裝置讀到")
                            }
                            if !answer.expected.isEmpty, answer.expected != answer.recognized {
                                choice(answer.expected, source: "標準答案")
                            }
                        }

                        HStack(spacing: 8) {
                            TextField("其他答案", text: $typed)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 16).monospaced())
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Button("套用") { apply(typed) }
                                .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }

                    if answer.teacherValue != nil {
                        Button("清除修正，回到裝置判定", role: .destructive) { apply(nil) }
                            .font(.system(size: 14))
                    }
                }
                .padding(20)
            }
            .background(AG.bg2)
            .navigationTitle("第 \(answer.questionNo) 題")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// The crop is the only evidence on this screen and everything else is a
    /// judgement about it, so it gets the room. When there is none, say so —
    /// a silent gap reads as a layout bug rather than as missing data.
    @ViewBuilder
    private var evidence: some View {
        if let image = papers.cellImage(paper, question: answer.questionNo) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Color(hex: 0xF3EEE3))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AG.border2, lineWidth: 1))
        } else {
            RoundedRectangle(cornerRadius: 14)
                .fill(AG.bg1)
                .frame(height: 120)
                .overlay {
                    Text("這一格沒有留下裁切影像")
                        .font(.system(size: 13))
                        .foregroundStyle(AG.fg3)
                }
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AG.border2, lineWidth: 1))
        }
    }

    private var currentState: some View {
        let verdict = answer.effectiveVerdict
        let tint = AG.color(for: verdict)
        let corrected = answer.teacherValue != nil
        return HStack(spacing: 8) {
            Image(systemName: AG.glyph(for: verdict))
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(tint)
                .clipShape(Circle())
            Text(corrected
                 ? "老師已修正為 \(answer.teacherValue ?? "")"
                 : "裝置判定：\(answer.recognized.isEmpty ? "沒有讀到" : answer.recognized)")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AG.fg1)
            Spacer()
            Text("標準答案 \(answer.expected.isEmpty ? "—" : answer.expected)")
                .font(.system(size: 13).monospaced())
                .foregroundStyle(AG.fg2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// Says the value, where it came from, and what happens if it is chosen.
    ///
    /// The consequence matters because the question being asked is not "is
    /// this right" — it is "what did the student write". The verdict follows
    /// from the answer, and showing which way it will fall is what stops the
    /// teacher having to work that out from two bare numbers.
    private func choice(_ value: String, source: String) -> some View {
        let becomesCorrect = AnswerKind.canonical(value) == AnswerKind.canonical(answer.expected)
        let tint = becomesCorrect ? AG.ok : AG.bad
        let isCurrent = answer.teacherValue == value
        return Button {
            apply(value)
        } label: {
            VStack(spacing: 5) {
                Text(value)
                    .font(.system(size: 26, weight: .bold).monospaced())
                    .foregroundStyle(AG.fg1)
                Text(source)
                    .font(.system(size: 11))
                    .foregroundStyle(AG.fg2)
                HStack(spacing: 3) {
                    Image(systemName: becomesCorrect ? "checkmark" : "xmark")
                        .font(.system(size: 9, weight: .bold))
                    Text(becomesCorrect ? "改為正確" : "仍算錯誤")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(AG.bg1)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(isCurrent ? tint : AG.border2, lineWidth: isCurrent ? 2 : 1))
        }
        .buttonStyle(.plain)
    }

    private func apply(_ value: String?) {
        papers.correct(paper: paper, question: answer.questionNo, to: value)
        dismiss()
    }
}
