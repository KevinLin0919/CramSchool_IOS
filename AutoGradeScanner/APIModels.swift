import CoreGraphics
import Foundation

// Wire types for CramSchool_API's /api/v1 surface.
//
// These mirror the server's Pydantic schemas one-to-one and exist separately
// from the app's own models so the two can move independently: the UI's
// `ExamTemplate` is free to carry display niceties the server has no opinion
// about, and a field added server-side does not force a change here.
//
// Timestamps stay `String`. The only one the client acts on is `sync_cursor`,
// which it hands straight back on the next request — parsing it into a Date
// and re-formatting it would introduce a rounding step between "what the
// server said" and "what the client asks for next", and a sync cursor that
// loses microseconds silently skips whatever changed inside them. The rest are
// only ever displayed, and ISO-8601 already sorts and truncates correctly.

// MARK: - Auth

struct TokenResponse: Decodable {
    let token: String
    let teacherID: Int
    let teacherName: String
    let role: String

    enum CodingKeys: String, CodingKey {
        case token, role
        case teacherID = "teacher_id"
        case teacherName = "teacher_name"
    }
}

struct TeacherDTO: Decodable {
    let id: Int
    let name: String
    let role: String
}

// MARK: - Templates

struct TemplateSummaryDTO: Codable {
    let id: Int
    let examName: String
    let grade: String?
    let subject: String?
    let annotationCount: Int
    let pageCount: Int
    let revision: Int
    let createdAt: String
    let updatedAt: String
    let deletedAt: String?

    /// A soft-deleted template arrives as a tombstone so a device that was
    /// offline when it vanished can drop it locally.
    var isDeleted: Bool { deletedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, grade, subject, revision
        case examName = "exam_name"
        case annotationCount = "annotation_count"
        case pageCount = "page_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct TemplateListDTO: Decodable {
    let templates: [TemplateSummaryDTO]
    let syncCursor: String?

    enum CodingKeys: String, CodingKey {
        case templates
        case syncCursor = "sync_cursor"
    }
}

struct AnswerBoxDTO: Codable {
    /// Stable across edits — never the position in this array.
    let questionNo: Int
    /// Fractions of the page image, not the legacy 800x600 canvas.
    let x: Double
    let y: Double
    let w: Double
    let h: Double
    let answer: String
    let answerType: String

    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }

    enum CodingKeys: String, CodingKey {
        case x, y, w, h, answer
        case questionNo = "question_no"
        case answerType = "answer_type"
    }
}

struct TemplatePageDTO: Codable {
    let pageIndex: Int
    let imageID: Int
    let imageWidth: Int
    let imageHeight: Int
    let boxes: [AnswerBoxDTO]

    enum CodingKeys: String, CodingKey {
        case boxes
        case pageIndex = "page_index"
        case imageID = "image_id"
        case imageWidth = "image_width"
        case imageHeight = "image_height"
    }
}

struct TemplateDetailDTO: Codable {
    let id: Int
    let examName: String
    let grade: String?
    let subject: String?
    let revision: Int
    let pages: [TemplatePageDTO]

    /// Standard answers in stable question order.
    var expectedAnswers: [String] {
        pages.flatMap(\.boxes).sorted { $0.questionNo < $1.questionNo }.map(\.answer)
    }

    enum CodingKeys: String, CodingKey {
        case id, grade, subject, revision, pages
        case examName = "exam_name"
    }
}

// MARK: - Local sync state

/// What the store keeps on disk beside the cached templates.
struct TemplateIndex: Codable {
    var cursor: String?
    var templates: [TemplateSummaryDTO]

    static let empty = TemplateIndex(cursor: nil, templates: [])
}
