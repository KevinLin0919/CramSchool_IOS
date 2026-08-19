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
    @State private var master: UIImage?
    @State private var loadedTemplate: Int?
    @State private var showsClearConfirm = false

    private var current: StoredPaper? {
        guard papers.papers.indices.contains(index) else { return papers.papers.last }
        return papers.papers[index]
    }

    var body: some View {
        Group {
            if let paper = current {
                content(paper)
            } else {
                emptyState
            }
        }
        .task(id: current?.templateID) { await loadMaster() }
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
    private func content(_ paper: StoredPaper) -> some View {
        RegularWidth { isRegular in
            VStack(spacing: 0) {
                topNav(paper)
                if isRegular {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollView { sheetPanel(paper).padding(16) }
                            .frame(maxWidth: .infinity)
                        Rectangle().fill(AG.border2).frame(width: 1)
                        ScrollView { cellPanel(paper).padding(16) }
                            .frame(width: 380)
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            sheetPanel(paper)
                            cellPanel(paper)
                        }
                        .padding(16)
                        .padding(.bottom, 80)
                    }
                }
            }
            .background(AG.bg2)
        }
    }

    // MARK: - Top: the master sheet with boxes

    private func sheetPanel(_ paper: StoredPaper) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            summaryRow(paper)

            ZStack {
                if let master {
                    Image(uiImage: master)
                        .resizable()
                        .scaledToFit()
                        .overlay(GeometryReader { geo in
                            ForEach(paper.answers, id: \.questionNo) { answer in
                                if let rect = answer.rect {
                                    boxMarker(answer, in: rect, size: geo.size)
                                }
                            }
                        })
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(AG.bg1)
                        .frame(height: 220)
                        .overlay(ProgressView().tint(AG.brand))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AG.border2, lineWidth: 1))
        }
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
        VStack(alignment: .leading, spacing: 10) {
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(paper.answers, id: \.questionNo) { answer in
                    cellCard(paper, answer)
                }
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
        .padding(.horizontal, 16)
        .frame(height: 46)
        // Centred as an overlay rather than between two Spacers: the left
        // button carries an icon and two words, the right a single glyph, so
        // spacers split the leftover space unevenly and push the counter off
        // centre by the difference.
        .overlay {
            HStack(spacing: 12) {
                pagerButton("chevron.left", enabled: index > 0) { index -= 1 }
                // Paging is by position in the stack. Which student a paper
                // belongs to is not recorded yet, and guessing would put a
                // name on a record nobody verified.
                Text("第 \(index + 1) / \(papers.papers.count) 張")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AG.fg1)
                pagerButton("chevron.right", enabled: index < papers.papers.count - 1) {
                    index += 1
                }
            }
        }
        .background(AG.bg1)
        .overlay(alignment: .bottom) { AG.border1.frame(height: 0.5) }
        .confirmationDialog("清除這一疊批改結果？", isPresented: $showsClearConfirm,
                            titleVisibility: .visible) {
            Button("清除 \(papers.papers.count) 張", role: .destructive) {
                papers.clearAll()
                index = 0
            }
        } message: {
            Text("這些結果尚未上傳到伺服器，清除後無法復原。")
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

    private func loadMaster() async {
        guard let paper = current else { return }
        guard loadedTemplate != paper.templateID else { return }
        master = nil
        if let resolved = try? await TemplateStore.shared.resolve(id: paper.templateID) {
            master = resolved.master
            loadedTemplate = paper.templateID
        }
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
            VStack(spacing: 18) {
                if let image = papers.cellImage(paper, question: answer.questionNo) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 150)
                        .background(Color(hex: 0xF3EEE3))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AG.border2, lineWidth: 1))
                }

                HStack(spacing: 28) {
                    labelled("裝置讀到", answer.recognized.isEmpty ? "—" : answer.recognized)
                    labelled("標準答案", answer.expected.isEmpty ? "—" : answer.expected)
                }

                VStack(spacing: 8) {
                    Text("這格實際是")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AG.fg2)

                    HStack(spacing: 10) {
                        if !answer.recognized.isEmpty {
                            choice(answer.recognized)
                        }
                        if !answer.expected.isEmpty, answer.expected != answer.recognized {
                            choice(answer.expected)
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
                    .padding(.top, 4)
                }

                if answer.teacherValue != nil {
                    Button("取消修正，回到裝置判定", role: .destructive) { apply(nil) }
                        .font(.system(size: 14))
                }

                Spacer()
            }
            .padding(20)
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

    private func labelled(_ title: String, _ value: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(AG.fg2)
            Text(value)
                .font(.system(size: 22, weight: .bold).monospaced())
                .foregroundStyle(AG.fg1)
        }
    }

    private func choice(_ value: String) -> some View {
        Button {
            apply(value)
        } label: {
            Text(value)
                .font(.system(size: 20, weight: .bold).monospaced())
                .foregroundStyle(.white)
                .frame(minWidth: 74)
                .frame(height: 48)
                .background(AG.brand)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private func apply(_ value: String?) {
        papers.correct(paper: paper, question: answer.questionNo, to: value)
        dismiss()
    }
}
