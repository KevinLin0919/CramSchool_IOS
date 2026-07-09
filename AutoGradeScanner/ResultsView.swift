import SwiftUI

// Screen 3 — graded results: score card, the scanned paper with
// bounding boxes, and a per-question breakdown bottom sheet.
struct ResultsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var focusQ: Int?
    @State private var expanded = false

    var body: some View {
        if let result = model.lastResult {
            content(result)
        } else {
            emptyState
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

    private func content(_ result: GradingResult) -> some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                topNav(result)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ScoreCardView(result: result)

                        HStack {
                            Text("學生答案卷")
                                .font(.system(size: 12, weight: .semibold))
                                .kerning(0.3)
                                .foregroundStyle(AG.fg2)
                            Spacer()
                            HStack(spacing: 12) {
                                legend(color: AG.ok, text: "正確 \(result.correctCount)")
                                legend(color: AG.bad, text: "錯誤 \(result.incorrectCount)")
                            }
                        }
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                        GradedImageOverlay(image: result.image,
                                           answers: result.answers,
                                           focusedID: focusQ,
                                           onTapBox: { id in
                                               focusQ = (focusQ == id) ? nil : id
                                           })
                            .aspectRatio(result.image.size.width / max(result.image.size.height, 1),
                                         contentMode: .fit)
                            .background(Color(hex: 0xF3EEE3))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shadow(color: Color(hex: 0x0F1720, alpha: 0.12), radius: 8, y: 4)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 280)
                    .centeredContent(AG.Width.wide)
                }
            }
            .background(AG.bg2)

            BreakdownSheet(answers: result.answers,
                           focusQ: $focusQ,
                           expanded: $expanded)

            if !expanded {
                scanNextButton
                    .padding(.bottom, 240)
            }
        }
    }

    private func topNav(_ result: GradingResult) -> some View {
        HStack {
            Button {
                model.screen = .scan
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("重新掃描")
                        .font(.system(size: 17))
                }
                .foregroundStyle(AG.brand)
            }
            Spacer()
            ShareLink(item: shareText(result)) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(AG.brand)
            }
        }
        .overlay {
            Text("批改結果")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AG.fg1)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .centeredContent(AG.Width.wide)
    }

    private func shareText(_ result: GradingResult) -> String {
        let wrong = result.answers.filter { !$0.isCorrect }
            .map { "Q\($0.questionNumber)" }
            .joined(separator: "、")
        var text = "\(result.templateTitle) 批改結果：\(result.correctCount)/\(result.total)（\(result.percent)%）\(result.passed ? "通過" : "未通過")"
        if !wrong.isEmpty { text += "\n錯誤題目：\(wrong)" }
        return text
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(AG.fg2)
        }
    }

    private var scanNextButton: some View {
        Button {
            model.screen = .scan
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 16, weight: .semibold))
                Text("掃描下一張")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 50)
            .background(AG.brand)
            .clipShape(Capsule())
            .shadow(color: AG.brand.opacity(0.35), radius: 11, y: 8)
        }
    }
}

// MARK: - Score card (detailed style from the design)

private struct ScoreCardView: View {
    let result: GradingResult

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.date.formatted(date: .numeric, time: .shortened))
                        .font(.system(size: 12, weight: .semibold))
                        .kerning(0.3)
                        .foregroundStyle(AG.fg2)
                    Text(result.templateTitle)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AG.fg1)
                }
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: result.passed ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .heavy))
                    Text(result.passed ? "通過" : "未通過")
                        .font(.system(size: 12, weight: .bold))
                }
                .foregroundStyle(result.passed ? AG.brand : AG.bad)
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
                .background(result.passed ? AG.brand.opacity(0.09) : AG.badBg)
                .clipShape(Capsule())
            }
            .padding(.bottom, 12)

            HStack(alignment: .bottom) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(result.correctCount)")
                        .font(.system(size: 64, weight: .bold))
                        .foregroundStyle(result.passed ? AG.brand : AG.bad)
                    Text("/\(result.total)")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(AG.fg3)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text("\(result.percent)%")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(AG.fg1)
                    Text("得分率")
                        .font(.system(size: 11))
                        .foregroundStyle(AG.fg2)
                }
                .padding(.bottom, 6)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(AG.bg2)
                    Capsule()
                        .fill(result.passed ? AG.brand : AG.bad)
                        .frame(width: geo.size.width * CGFloat(result.percent) / 100)
                }
            }
            .frame(height: 6)
            .padding(.top, 14)
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .background(AG.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(AG.border2, lineWidth: 1))
        .shadow(color: Color(hex: 0x0F1720, alpha: 0.06), radius: 7, y: 4)
    }
}

// MARK: - Per-question breakdown bottom sheet

private struct BreakdownSheet: View {
    let answers: [GradedAnswer]
    @Binding var focusQ: Int?
    @Binding var expanded: Bool

    private var incorrect: Int { answers.filter { !$0.isCorrect }.count }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.28)) { expanded.toggle() }
            } label: {
                Capsule()
                    .fill(AG.borderStrong)
                    .frame(width: 36, height: 5)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack(alignment: .firstTextBaseline) {
                Text("逐題明細")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(AG.fg1)
                Spacer()
                Text(incorrect == 0 ? "全部正確" : "\(incorrect) 題錯誤")
                    .font(.system(size: 13))
                    .foregroundStyle(AG.fg2)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
            .centeredContent()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(answers) { answer in
                            chip(answer)
                        }
                    }

                    if expanded {
                        ocrComparisonList
                            .padding(.top, 16)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 90)
                .centeredContent()
            }
        }
        .frame(maxHeight: expanded ? 470 : 225)
        .frame(maxWidth: .infinity)
        .background(AG.bg1)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22))
        .shadow(color: Color(hex: 0x0F1720, alpha: 0.10), radius: 12, y: -8)
        .ignoresSafeArea(edges: .bottom)
    }

    private func chip(_ answer: GradedAnswer) -> some View {
        let color = answer.isCorrect ? AG.ok : AG.bad
        let bg = answer.isCorrect ? AG.okBg : AG.badBg
        let isFocused = focusQ == answer.id

        return Button {
            focusQ = isFocused ? nil : answer.id
        } label: {
            VStack(spacing: 4) {
                Text("Q\(answer.questionNumber)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isFocused ? .white : color)
                ZStack {
                    Circle().fill(isFocused ? .white : color)
                    Image(systemName: answer.isCorrect ? "checkmark" : "xmark")
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(isFocused ? color : .white)
                }
                .frame(width: 20, height: 20)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isFocused ? color : bg)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? color : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    private var ocrComparisonList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OCR 對照")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(AG.fg2)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(Array(answers.enumerated()), id: \.element.id) { index, answer in
                    comparisonRow(answer)
                        .overlay(alignment: .bottom) {
                            if index != answers.count - 1 {
                                AG.border1.frame(height: 0.5)
                            }
                        }
                }
            }
            .background(AG.bg2)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(AG.border2, lineWidth: 1))
        }
    }

    private func comparisonRow(_ answer: GradedAnswer) -> some View {
        let isFocused = focusQ == answer.id
        return Button {
            focusQ = isFocused ? nil : answer.id
        } label: {
            HStack(spacing: 12) {
                Text("Q\(answer.questionNumber)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AG.fg2)
                    .frame(width: 38, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text("作答")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AG.fg3)
                    Text(answer.recognized.isEmpty ? "—" : answer.recognized)
                        .font(.system(size: 15, weight: .semibold).monospaced())
                        .foregroundStyle(answer.isCorrect ? AG.fg1 : AG.bad)
                        .strikethrough(!answer.isCorrect && !answer.recognized.isEmpty)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text("標準")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AG.fg3)
                    Text(answer.expected.isEmpty ? "—" : answer.expected)
                        .font(.system(size: 15, weight: .semibold).monospaced())
                        .foregroundStyle(answer.isCorrect ? AG.fg1 : AG.ok)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                ZStack {
                    Circle().fill(answer.isCorrect ? AG.ok : AG.bad)
                    Image(systemName: answer.isCorrect ? "checkmark" : "xmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 22, height: 22)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isFocused ? AG.bg1 : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
