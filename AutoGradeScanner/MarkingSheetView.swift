import SwiftUI

// 紅筆對照 — one finished side of the paper, drawn on its master, showing only
// what the teacher has to write on it.
//
// Exists because the live overlay cannot do this job. It is drawn over the
// camera, and the camera only holds the paper while the phone is held over
// it; the moment the phone goes down so a hand is free for the pen, alignment
// drops and every box goes with it. This is a still picture, so the phone can
// lie beside the paper while the teacher copies from it.
//
// Two kinds of mark and no others. Red is wrong, orange is the model could
// not tell. Greens are left off on purpose: the teacher does not write on
// them, and a sheet covered in boxes of every colour is what made the
// overlay read as random marking.

struct MarkingSheetView: View {
    let sheet: LiveScanEngine.MarkingSheet
    /// The side to turn to next, when there is one left to grade.
    var nextPageLabel: String?
    var onNextPage: () -> Void = {}
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            header

            GeometryReader { geo in
                let fit = aspectFitRect(imageSize: sheet.master.size, container: geo.size)
                ZStack(alignment: .topLeading) {
                    // Pins the stack's origin to the container's, so every
                    // offset and guide below is measured from the same corner.
                    Color.clear.frame(width: geo.size.width, height: geo.size.height)

                    Image(uiImage: sheet.master)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)

                    ForEach(sheet.marks) { mark in
                        MarkingBox(mark: mark, in: fit, container: geo.size)
                    }
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            buttons
        }
        .padding(14)
        .background(.black.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("紅筆對照・\(sheet.label)")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
            Spacer()
            if sheet.wrongCount > 0 {
                Text("錯 \(sheet.wrongCount)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AG.bad)
            }
            if sheet.unsureCount > 0 {
                Text("待確認 \(sheet.unsureCount)")
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    .foregroundStyle(AG.warn)
            }
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Text("收起")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(Color.white.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if let nextPageLabel {
                Button(action: onNextPage) {
                    Text("翻到\(nextPageLabel)")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(AG.brand)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

/// One cell to mark, and the answer to write beside it.
///
/// Red is a solid outline, orange a dashed one with "?" before the answer —
/// different in shape as well as colour, so the two never read as shades of
/// one thing. Neither is filled: the student's writing under it is what the
/// teacher is checking. The answer always sits to the right of the box, and
/// only moves left when the right edge would cut it off.
private struct MarkingBox: View {
    let mark: LiveScanEngine.MarkingSheet.Mark
    let rect: CGRect
    let container: CGSize

    init(mark: LiveScanEngine.MarkingSheet.Mark, in image: CGRect, container: CGSize) {
        self.mark = mark
        self.container = container
        self.rect = CGRect(x: image.minX + mark.rect.minX * image.width,
                           y: image.minY + mark.rect.minY * image.height,
                           width: mark.rect.width * image.width,
                           height: mark.rect.height * image.height)
    }

    private var isUnsure: Bool { mark.verdict == .unsure }
    private var color: Color { isUnsure ? AG.warn : AG.bad }
    private var text: String { isUnsure ? "? \(mark.expected)" : mark.expected }

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(color, style: StrokeStyle(lineWidth: 2.5, dash: isUnsure ? [6, 4] : []))
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)

        // Measured by the layout, not estimated: the label's width depends on
        // the answer, and guessing it is how a label on the last column ends
        // up half off the sheet.
        Text(text)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .alignmentGuide(.leading) { d in
                let gap: CGFloat = 3
                let fitsRight = rect.maxX + gap + d.width <= container.width
                return -(fitsRight ? rect.maxX + gap : max(0, rect.minX - gap - d.width))
            }
            .alignmentGuide(.top) { d in -max(0, rect.midY - d.height / 2) }
    }
}
