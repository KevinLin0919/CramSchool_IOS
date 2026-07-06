import UIKit

// Full grading pipeline for one captured student paper:
//   photo -> YOLO answer-box detection -> handwriting OCR -> compare
//   against the template's expected answers (paired by index, same as
//   the web frontend).
enum GradingEngine {

    static func grade(image: UIImage,
                      templateID: Int,
                      templateTitle: String) async throws -> GradingResult {
        let prepared = image.normalizedForUpload(maxDimension: 1600)
        guard let jpeg = prepared.jpegData(compressionQuality: 0.85) else {
            throw APIError.imageEncoding
        }
        let base64 = jpeg.base64EncodedString()

        async let detailTask = APIClient.shared.templateDetail(id: templateID)
        async let boxesTask = APIClient.shared.predict(imageBase64: base64)
        let (detail, boxes) = try await (detailTask, boxesTask)

        let expected = detail.expectedAnswers
        let ocr: [OCRCandidate] = boxes.isEmpty
            ? []
            : try await APIClient.shared.ocrStudent(imageBase64: base64, boxes: boxes)

        let imageWidth = prepared.size.width
        let imageHeight = prepared.size.height

        // Total question count comes from the template; if the template has
        // no annotations fall back to what was detected on the paper.
        let total = expected.isEmpty ? ocr.count : expected.count

        var answers: [GradedAnswer] = []
        for i in 0..<total {
            let exp = i < expected.count ? expected[i] : ""
            let recognized = i < ocr.count ? ocr[i].value(expected: exp) : ""
            let isCorrect = !exp.isEmpty && !recognized.isEmpty && recognized == exp

            var rect: CGRect?
            if i < boxes.count, boxes[i].count >= 4, imageWidth > 0, imageHeight > 0 {
                let b = boxes[i]
                rect = CGRect(x: b[0] / imageWidth,
                              y: b[1] / imageHeight,
                              width: abs(b[2] - b[0]) / imageWidth,
                              height: abs(b[3] - b[1]) / imageHeight)
            }

            answers.append(GradedAnswer(id: i,
                                        expected: exp,
                                        recognized: recognized,
                                        isCorrect: isCorrect,
                                        rect: rect))
        }

        return GradingResult(image: prepared,
                             answers: answers,
                             templateTitle: templateTitle,
                             date: Date())
    }
}
