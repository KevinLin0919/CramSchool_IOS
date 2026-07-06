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

    private var color: Color { answer.isCorrect ? AG.ok : AG.bad }

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
                    Image(systemName: answer.isCorrect ? "checkmark" : "xmark")
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

struct GradedImageOverlay: View {
    let image: UIImage
    let answers: [GradedAnswer]
    var revealed: Int? = nil      // nil = show all
    var focusedID: Int? = nil
    var onTapBox: ((Int) -> Void)? = nil

    private var shown: [GradedAnswer] {
        guard let revealed else { return answers }
        return Array(answers.prefix(revealed))
    }

    var body: some View {
        GeometryReader { geo in
            let fit = aspectFitRect(imageSize: image.size, container: geo.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)

                ForEach(shown) { answer in
                    if let rect = answer.rect {
                        let boxWidth = rect.width * fit.width
                        let boxHeight = rect.height * fit.height
                        AnswerBoxView(answer: answer, focused: focusedID == answer.id)
                            .frame(width: max(boxWidth, 14), height: max(boxHeight, 12))
                            .position(x: fit.minX + (rect.midX * fit.width),
                                      y: fit.minY + (rect.midY * fit.height))
                            .onTapGesture { onTapBox?(answer.id) }
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
            }
        }
    }
}
