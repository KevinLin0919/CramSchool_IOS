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

/// Three outcomes, not two.
///
/// Marking a cell wrong because the model could not read it blames the student
/// for our failure, so "couldn't read" is its own state. The scanner has always
/// drawn it in yellow; carrying it through to the result is what lets the
/// teacher see which answers still need a human.
enum GradingVerdict {
    case correct
    case wrong
    case unsure
}

struct GradedAnswer: Identifiable {
    let id: Int              // questionNumber - 1
    let expected: String
    let recognized: String
    let verdict: GradingVerdict
    let rect: CGRect?        // normalized (0...1) within the scanned image

    /// What the teacher said it was, when they overrode us. Paired with the
    /// cell crop this is a labelled handwriting sample — the highest-value
    /// by-product of ordinary grading.
    var teacherValue: String?

    init(id: Int,
         expected: String,
         recognized: String,
         verdict: GradingVerdict,
         rect: CGRect?,
         teacherValue: String? = nil) {
        self.id = id
        self.expected = expected
        self.recognized = recognized
        self.verdict = verdict
        self.rect = rect
        self.teacherValue = teacherValue
    }

    var questionNumber: Int { id + 1 }

    /// A teacher's correction outranks the model's reading.
    var effectiveVerdict: GradingVerdict {
        guard let teacherValue else { return verdict }
        return AnswerKind.canonical(teacherValue) == AnswerKind.canonical(expected)
            ? .correct : .wrong
    }

    /// The answer as it should be read now — the teacher's, if they gave one.
    var effectiveAnswer: String { teacherValue ?? recognized }

    var isCorrect: Bool { effectiveVerdict == .correct }
    var needsReview: Bool { effectiveVerdict == .unsure }
}

struct GradingResult {
    let image: UIImage
    var answers: [GradedAnswer]
    let templateTitle: String
    let date: Date

    /// True when `image` shows the whole sheet, so every box could be placed
    /// on it. False means the scan never framed the full page and the result
    /// is drawn over whatever the camera last had in view.
    let isFullPage: Bool

    init(image: UIImage,
         answers: [GradedAnswer],
         templateTitle: String,
         date: Date,
         isFullPage: Bool = false) {
        self.image = image
        self.answers = answers
        self.templateTitle = templateTitle
        self.date = date
        self.isFullPage = isFullPage
    }

    var total: Int { answers.count }
    var correctCount: Int { answers.filter { $0.effectiveVerdict == .correct }.count }
    var unsureCount: Int { answers.filter { $0.effectiveVerdict == .unsure }.count }
    var incorrectCount: Int { answers.filter { $0.effectiveVerdict == .wrong }.count }
    // Deliberately no percentage and no pass/fail.
    //
    // Questions are not worth the same marks, so correct-count over total is
    // not the score — presenting it as one would be confidently wrong rather
    // than roughly right, and a teacher or parent reading it has no way to
    // tell. Where the pass mark sits is the school's call and varies by
    // subject; an app that decides 60% is inventing a judgement it has no
    // basis for. What this can honestly report is how many questions landed
    // in each of the three states.
    var needsReviewCount: Int { unsureCount }
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
