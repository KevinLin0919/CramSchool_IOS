import SwiftUI

// Visual identity for a template in the picker. So the user can tell at a
// glance what they're selecting, every row carries a paper-like thumbnail and
// the 預覽 sheet shows either the real master sheet (bundled demo templates)
// or a schematic answer card built from the template's answer key — both work
// fully offline, unlike the old server-image-only preview.

// MARK: - Row thumbnail

struct TemplateThumbnail: View {
    let template: ExamTemplate
    var side: CGFloat = 46

    var body: some View {
        Group {
            if let image = DemoData.bundledImage(for: template.id) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                MiniAnswerSheet(subject: template.subject)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AG.border2, lineWidth: 0.75))
    }
}

// An abstract "answer sheet" mark for templates that ship no image: a tinted
// title bar over a few answer lines, so the tile still reads as a document.
struct MiniAnswerSheet: View {
    let subject: String

    var body: some View {
        let tint = AG.subjectTint(subject)
        ZStack {
            AG.bg1
            VStack(alignment: .leading, spacing: 3.5) {
                RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.85))
                    .frame(width: 20, height: 4)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 1).fill(AG.fg4)
                            .frame(width: 13, height: 3)
                        RoundedRectangle(cornerRadius: 1.5).fill(tint.opacity(0.28))
                            .frame(width: 9, height: 6)
                    }
                }
            }
        }
    }
}

// MARK: - Schematic answer card (full preview)

// Renders the template's answer key as a tidy two-column answer card, so the
// preview is meaningful even when there is no sheet image to show.
struct AnswerSheetSchematic: View {
    let title: String
    let subject: String
    let answers: [String]

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let tint = AG.subjectTint(subject)
        ScrollView {
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("標準答案卡")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Text(title)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                    }
                    Spacer()
                    Text("\(answers.count) 題")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.white.opacity(0.2))
                        .clipShape(Capsule())
                }
                .padding(16)
                .frame(maxWidth: .infinity)
                .background(tint)

                if answers.isEmpty {
                    Text("此考卷尚無答案資料")
                        .font(.system(size: 14))
                        .foregroundStyle(AG.fg3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(answers.enumerated()), id: \.offset) { i, answer in
                            answerCell(number: i + 1, answer: answer, tint: tint)
                        }
                    }
                    .padding(16)
                }
            }
            .background(AG.bg1)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(AG.border2, lineWidth: 1))
            .padding(16)
        }
    }

    private func answerCell(number: Int, answer: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 13, weight: .bold).monospacedDigit())
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            Text(answer.isEmpty ? "—" : answer)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AG.fg1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .background(AG.bg2)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(AG.border2, lineWidth: 1))
    }
}
