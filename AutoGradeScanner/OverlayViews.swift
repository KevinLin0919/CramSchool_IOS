import SwiftUI

// Shared drawing of graded answer boxes over a scanned paper image.
// Used by both the scanner (live pop-in) and the results screen (tappable).

func aspectFitRect(imageSize: CGSize, container: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0,
          container.width > 0, container.height > 0 else { return .zero }
    let scale = min(container.width / imageSize.width,
                    container.height / imageSize.height)
    let size = CGSize(width: imageSize.width * scale,
                      height: imageSize.height * scale)
    return CGRect(x: (container.width - size.width) / 2,
                  y: (container.height - size.height) / 2,
                  width: size.width,
                  height: size.height)
}

struct AnswerBoxView: View {
    let answer: GradedAnswer
    var focused = false

    // Three states, not two. An answer the model could not read is not the
    // same as one the student got wrong, and flattening them here would undo
    // the distinction the scanner spent the whole session maintaining.
    private var color: Color {
        switch answer.effectiveVerdict {
        case .correct: return AG.ok
        case .wrong: return AG.bad
        case .unsure: return AG.warn
        }
    }

    private var glyph: String {
        switch answer.effectiveVerdict {
        case .correct: return "checkmark"
        case .wrong: return "xmark"
        case .unsure: return "questionmark"
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(color, lineWidth: focused ? 2.5 : 2)
            )
            .overlay(alignment: .topTrailing) {
                ZStack {
                    Circle().fill(color)
                    Image(systemName: glyph)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                }
                .frame(width: 18, height: 18)
                .offset(x: 8, y: -9)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
            }
            .overlay(alignment: .topLeading) {
                Text("Q\(answer.questionNumber)")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(color)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .offset(x: -5, y: -9)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
            }
    }
}
