import Foundation
import CoreGraphics
import UIKit

// The 800x600 labeling-canvas space the web frontend used is gone along with
// the service that stored it. Boxes are fractions of the page image now, which
// needs no shared constant to interpret.

// MARK: - Exam template (the list model the UI works in)

struct ExamTemplate: Identifiable, Hashable {
    let id: Int
    let examName: String
    let annotationCount: Int
    let createdAt: String
    let updatedAt: String

    /// Real columns, when the row came from a server that has them.
    ///
    /// The token scan below survives as a fallback for bundled demo templates
    /// and for rows imported before the columns existed. It is also the reason
    /// the columns exist: scanning a free-text name classifies "高一數學" and
    /// gives up on "數甲 L1", and every client re-deriving that guess meant
    /// the same paper could file itself differently in two places.
    let serverGrade: String?
    let serverSubject: String?

    init(id: Int,
         examName: String,
         annotationCount: Int,
         createdAt: String,
         updatedAt: String = "",
         serverGrade: String? = nil,
         serverSubject: String? = nil) {
        self.id = id
        self.examName = examName
        self.annotationCount = annotationCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.serverGrade = serverGrade
        self.serverSubject = serverSubject
    }

    init(dto: TemplateSummaryDTO) {
        self.init(id: dto.id,
                  examName: dto.examName,
                  annotationCount: dto.annotationCount,
                  createdAt: dto.createdAt,
                  updatedAt: dto.updatedAt,
                  serverGrade: dto.grade,
                  serverSubject: dto.subject)
    }

    static let gradeOrder = ["國一", "國二", "國三", "高一", "高二", "高三", "其他"]

    private static let gradeTokens = ["國一", "國二", "國三", "高一", "高二", "高三",
                                      "小一", "小二", "小三", "小四", "小五", "小六"]
    private static let subjectTokens = ["數學", "英文", "英語", "國文", "理化", "物理", "化學",
                                        "歷史", "地理", "生物", "自然", "社會", "公民"]

    var grade: String {
        if let serverGrade, !serverGrade.isEmpty { return serverGrade }
        return Self.gradeTokens.first(where: { examName.contains($0) }) ?? "其他"
    }

    var subject: String {
        if let serverSubject, !serverSubject.isEmpty { return serverSubject }
        return Self.subjectTokens.first(where: { examName.contains($0) }) ?? "一般"
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

// The 800x600 "web canvas" bbox format that used to live here is gone with the
// service that spoke it. Boxes now arrive as fractions of the page image
// (`AnswerBoxDTO`), which is interpretable without also knowing the master's
// aspect ratio — the old format was not, and every consumer had to re-derive
// the same letterbox offsets to use it.

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
