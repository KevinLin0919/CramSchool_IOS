import Foundation
import CoreGraphics
import UIKit

// Coordinate space used by the web frontend's labeling canvas.
// Template bboxes stored on the backend are in this 800x600 space,
// so we convert to/from it to stay compatible with the web app.
enum WebCanvas {
    static let width: Double = 800
    static let height: Double = 600
}

// MARK: - Exam template (list item, GET /api/exam-templates)

struct ExamTemplate: Identifiable, Decodable, Hashable {
    let id: Int
    let examName: String
    let annotationCount: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case examName = "exam_name"
        case annotationCount = "annotation_count"
        case createdAt = "created_at"
    }

    static let gradeOrder = ["國一", "國二", "國三", "高一", "高二", "高三", "其他"]

    private static let gradeTokens = ["國一", "國二", "國三", "高一", "高二", "高三",
                                      "小一", "小二", "小三", "小四", "小五", "小六"]
    private static let subjectTokens = ["數學", "英文", "英語", "國文", "理化", "物理", "化學",
                                        "歷史", "地理", "生物", "自然", "社會", "公民"]

    // The backend only stores a free-text exam_name; grade/subject are
    // parsed out of it so the UI can group like the design.
    var grade: String {
        Self.gradeTokens.first(where: { examName.contains($0) }) ?? "其他"
    }

    var subject: String {
        Self.subjectTokens.first(where: { examName.contains($0) }) ?? "一般"
    }

    var displayName: String {
        var name = examName
        for token in Self.gradeTokens + Self.subjectTokens {
            name = name.replacingOccurrences(of: token, with: "")
        }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ・·-_、，,"))
        return name.isEmpty ? examName : name
    }

    var fullTitle: String {
        let prefix = "\(grade == "其他" ? "" : grade)\(subject == "一般" ? "" : subject)"
        return prefix.isEmpty ? displayName : "\(prefix)・\(displayName)"
    }

    var dateText: String {
        String(createdAt.prefix(10)).replacingOccurrences(of: "-", with: "/")
    }
}

struct TemplateListResponse: Decodable {
    let templates: [ExamTemplate]
}

// MARK: - Template detail (GET /api/exam-templates/:id)

struct TemplateAnnotation: Decodable {
    let className: String?
    let bbox: [Double]   // [x, y, w, h] in 800x600 web-canvas space
    let answer: String?

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case bbox
        case answer
    }
}

struct TemplatePage: Decodable {
    let image: String?
    let annotations: [TemplateAnnotation]
}

struct TemplateDetail: Decodable {
    let id: Int
    let examName: String
    let pages: [TemplatePage]

    enum CodingKeys: String, CodingKey {
        case id
        case examName = "exam_name"
        case pages
    }

    var expectedAnswers: [String] {
        pages.flatMap(\.annotations).map {
            ($0.answer ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

// MARK: - OCR

// One OCR result for one answer box. The handwriting OCR service returns
// {chinese, digit} candidates; the Google OCR service returns plain text.
struct OCRCandidate {
    var chinese: String = ""
    var digit: String = ""
    var text: String = ""

    // Same selection rule as the web app: if the expected answer is all
    // digits pick the digit candidate, otherwise the chinese one.
    func value(expected: String) -> String {
        if !chinese.isEmpty || !digit.isEmpty {
            if expected.isEmpty {
                return (chinese.isEmpty ? digit : chinese).trimmingCharacters(in: .whitespaces)
            }
            let isDigit = expected.range(of: #"^\d+$"#, options: .regularExpression) != nil
            return (isDigit ? digit : chinese).trimmingCharacters(in: .whitespaces)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Grading result

struct GradedAnswer: Identifiable {
    let id: Int              // 0-based index
    let expected: String
    let recognized: String
    let isCorrect: Bool
    let rect: CGRect?        // normalized (0...1) within the scanned image

    var questionNumber: Int { id + 1 }
}

struct GradingResult {
    let image: UIImage
    let answers: [GradedAnswer]
    let templateTitle: String
    let date: Date

    var total: Int { answers.count }
    var correctCount: Int { answers.filter(\.isCorrect).count }
    var incorrectCount: Int { total - correctCount }
    var percent: Int { total > 0 ? Int((Double(correctCount) / Double(total) * 100).rounded()) : 0 }
    var passed: Bool { percent >= 60 }
}

// MARK: - Image helpers

extension UIImage {
    // Re-render at scale 1 with orientation baked in, capped to maxDimension,
    // so pixel coordinates from the backends map 1:1 onto `size`.
    func normalizedForUpload(maxDimension: CGFloat = 1600) -> UIImage {
        let largest = max(size.width, size.height)
        let ratio = largest > maxDimension ? maxDimension / largest : 1
        let newSize = CGSize(width: (size.width * ratio).rounded(),
                             height: (size.height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
