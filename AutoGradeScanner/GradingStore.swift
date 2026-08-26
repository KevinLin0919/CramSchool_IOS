import SwiftUI
import UIKit

// Where a graded paper lands the moment the teacher is done with it.
//
// The order matters more than the mechanism: write to disk first, worry about
// the server later. Cram-school Wi-Fi drops, and an afternoon of grading must
// not depend on the network being polite at the moment a button is pressed.
// Everything here is local; the upload half is deliberately absent until the
// payload's shape is settled (whether it carries a student id changes it).
//
// This is also what makes the continuous scanning loop safe to build. Removing
// the forced glance at each result — which is the point of the loop — would
// otherwise mean a teacher grades twenty papers and keeps only the last, since
// the app has never retained more than one.

/// One side of the paper, as it was when the paper was graded.
///
/// The record has to describe its own backdrop. Asking the template for it
/// works only until the template moves, and templates move: a single-sided
/// paper becomes double-sided and every result filed before that grows a
/// second side it never had, empty of boxes. Worse, replacing a page's
/// picture leaves the old records drawing their boxes on the new sheet — at
/// coordinates measured against a different one, so nothing looks broken and
/// everything is in the wrong place.
struct StoredPage: Codable, Equatable {
    /// Position in the paper, and the value `StoredAnswer.page` indexes.
    let index: Int
    /// The picture this side was graded against. Nil for a bundled demo
    /// sheet, which has no server-side image at all.
    let imageID: Int?
    /// 正面 / 背面 / 1..n, decided when the paper had a known page count
    /// rather than re-derived later from a template that may have grown.
    let label: String
}

/// One graded paper, in a form that survives the app being killed.
struct StoredPaper: Codable, Identifiable, Equatable {
    /// Minted on the device before anything is sent, so an upload that has to
    /// be retried lands on the row it created the first time.
    let id: UUID
    let templateID: Int
    let templateTitle: String
    let scannedAt: Date
    var answers: [StoredAnswer]

    /// The sides this paper had, in order. Optional so records written before
    /// papers described themselves still decode; `pagesOrInferred` is what
    /// the UI should read, never this.
    var pages: [StoredPage]?

    /// What to draw, whether or not the record says so.
    ///
    /// An older record knows one thing about its shape — the highest page any
    /// of its answers sits on — and that is enough to stop it borrowing sides
    /// from whatever the template has become since.
    var pagesOrInferred: [StoredPage] {
        if let pages, !pages.isEmpty { return pages }
        let count = (answers.map(\.page).max() ?? 0) + 1
        return (0..<count).map {
            StoredPage(index: $0, imageID: nil,
                       label: count == 2 ? ($0 == 0 ? "正面" : "背面") : "\($0 + 1)")
        }
    }

    var correctCount: Int { answers.filter { $0.effectiveVerdict == .correct }.count }
    var wrongCount: Int { answers.filter { $0.effectiveVerdict == .wrong }.count }
    var unsureCount: Int { answers.filter { $0.effectiveVerdict == .unsure }.count }
    var total: Int { answers.count }

    var needsReview: Bool { unsureCount > 0 }

    // MARK: - Upload

    /// When this paper reached the server. Nil means it has not, which is the
    /// only state the queue acts on.
    var uploadedAt: Date?
    var uploadAttempts: Int?
    var lastUploadError: String?

    /// Set when the server has told us this paper can never be accepted — its
    /// template was deleted, say. Retrying that forever would burn battery to
    /// collect the same refusal, and hide the papers that could still succeed.
    var uploadBlocked: Bool?

    /// Graded against a bundled demo sheet, whose template exists on no
    /// server. Recorded when the paper is filed rather than inferred later:
    /// someone can look around in 示範模式, enrol afterwards, and those papers
    /// would otherwise queue up and fail forever against a template id that
    /// was never real.
    var isDemo: Bool?

    /// Bumped whenever the record changes in a way the server needs to see.
    /// An upload carries the generation it started from; if a correction lands
    /// while the request is in flight, the reply no longer matches and is
    /// discarded rather than marking a stale version as delivered.
    var revision: Int?

    var needsUpload: Bool {
        uploadedAt == nil && uploadBlocked != true && isDemo != true
    }
}

struct StoredAnswer: Codable, Equatable, Identifiable {
    var id: Int { questionNo }

    let questionNo: Int
    let expected: String
    let recognized: String
    /// Stored as a string so a future verdict cannot silently decode as an
    /// existing one; unknown values read back as `.unsure`, which asks a human
    /// rather than guessing.
    var verdict: String
    var teacherValue: String?
    var confidence: Double?
    /// x, y, w, h as fractions of the master sheet.
    let templateRect: [Double]?

    /// Which page of the paper the cell is on. Optional so records written
    /// before double-sided papers existed still decode — they were all
    /// single-page, so absent means page 0 and nothing needs migrating.
    var pageIndex: Int?

    var page: Int { pageIndex ?? 0 }

    var parsedVerdict: GradingVerdict {
        switch verdict {
        case "correct": return .correct
        case "wrong": return .wrong
        default: return .unsure
        }
    }

    var effectiveVerdict: GradingVerdict {
        guard let teacherValue, !teacherValue.isEmpty else { return parsedVerdict }
        return AnswerKind.canonical(teacherValue) == AnswerKind.canonical(expected)
            ? .correct : .wrong
    }

    var rect: CGRect? {
        guard let r = templateRect, r.count >= 4 else { return nil }
        return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
    }
}

@MainActor
final class GradingStore: ObservableObject {
    static let shared = GradingStore()

    /// The current stack, newest last. Papers accumulate as they are graded
    /// and are reviewed together once the stack is done.
    @Published private(set) var papers: [StoredPaper] = []

    private init() {
        load()
    }

    // MARK: - Layout

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("GradedPapers", isDirectory: true)
    }

    private func folder(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func recordURL(_ id: UUID) -> URL {
        folder(id).appendingPathComponent("paper.json")
    }

    /// The crop recognition read for one question.
    func cellURL(_ id: UUID, question: Int) -> URL {
        folder(id).appendingPathComponent("cell_\(question).png")
    }

    func cellImage(_ paper: StoredPaper, question: Int) -> UIImage? {
        UIImage(contentsOfFile: cellURL(paper.id, question: question).path)
    }

    // MARK: - Reading

    private func load() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        papers = folders.compactMap { url in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("paper.json")),
                  let paper = try? decoder.decode(StoredPaper.self, from: data) else { return nil }
            return paper
        }.sorted { $0.scannedAt < $1.scannedAt }
    }

    // MARK: - Writing

    /// Files the paper and its cell crops. Called the instant a teacher moves
    /// on from it, before anything else can go wrong.
    func store(_ paper: StoredPaper, cells: [Int: UIImage]) {
        let dir = folder(paper.id)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for (question, image) in cells {
            guard let png = image.pngData() else { continue }
            try? png.write(to: cellURL(paper.id, question: question), options: .atomic)
        }
        writeRecord(paper)

        if let index = papers.firstIndex(where: { $0.id == paper.id }) {
            papers[index] = paper
        } else {
            papers.append(paper)
        }
        UploadQueue.shared.drain()
    }

    /// A teacher's correction. Rewrites only the record — the crop is what the
    /// model saw and does not change because someone disagreed with it.
    func correct(paper: StoredPaper, question: Int, to value: String?) {
        guard let index = papers.firstIndex(where: { $0.id == paper.id }),
              let answer = papers[index].answers.firstIndex(where: { $0.questionNo == question })
        else { return }

        let trimmed = value?.trimmingCharacters(in: .whitespaces)
        papers[index].answers[answer].teacherValue = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // The server has a stale copy now. Re-uploading the same UUID updates
        // it in place, which is exactly what the upload endpoint is built for.
        papers[index].uploadedAt = nil
        papers[index].revision = (papers[index].revision ?? 0) + 1
        writeRecord(papers[index])
        UploadQueue.shared.drain()
    }

    // MARK: - Upload bookkeeping

    var pendingUploadCount: Int { papers.filter(\.needsUpload).count }

    /// Papers that will never upload, so the reason can be shown once rather
    /// than retried forever.
    var blockedUploadCount: Int { papers.filter { $0.uploadBlocked == true }.count }

    func markUploaded(_ id: UUID, revision: Int) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        // A correction landing while the request was in flight bumped the
        // revision. The reply describes a version of this paper that no longer
        // exists, so it cannot be allowed to mark it delivered.
        guard (papers[index].revision ?? 0) == revision else { return }
        papers[index].uploadedAt = Date()
        papers[index].lastUploadError = nil
        writeRecord(papers[index])
    }

    func markUploadFailed(_ id: UUID, error: String, permanent: Bool) {
        guard let index = papers.firstIndex(where: { $0.id == id }) else { return }
        papers[index].uploadAttempts = (papers[index].uploadAttempts ?? 0) + 1
        papers[index].lastUploadError = error
        if permanent { papers[index].uploadBlocked = true }
        writeRecord(papers[index])
    }

    private func writeRecord(_ paper: StoredPaper) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(paper) else { return }
        try? FileManager.default.createDirectory(at: folder(paper.id),
                                                 withIntermediateDirectories: true)
        try? data.write(to: recordURL(paper.id), options: .atomic)
    }

    // MARK: - Clearing

    func remove(_ paper: StoredPaper) {
        try? FileManager.default.removeItem(at: folder(paper.id))
        papers.removeAll { $0.id == paper.id }
    }

    /// Ends the stack. Nothing is uploaded yet, so this genuinely discards —
    /// the confirmation belongs in the UI, not here.
    func clearAll() {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        papers = []
    }

    // MARK: - Conversion

    /// Builds the record from a finished session.
    static func record(from result: GradingResult,
                       templateID: Int,
                       pages: [StoredPage],
                       id: UUID = UUID()) -> StoredPaper {
        StoredPaper(
            id: id,
            templateID: templateID,
            templateTitle: result.templateTitle,
            scannedAt: result.date,
            answers: result.answers.map { answer in
                StoredAnswer(
                    questionNo: answer.questionNumber,
                    expected: answer.expected,
                    recognized: answer.recognized,
                    verdict: {
                        switch answer.verdict {
                        case .correct: return "correct"
                        case .wrong: return "wrong"
                        case .unsure: return "unsure"
                        }
                    }(),
                    teacherValue: answer.teacherValue,
                    confidence: nil,
                    templateRect: answer.templateRect.map {
                        [$0.minX, $0.minY, $0.width, $0.height]
                    },
                    pageIndex: answer.pageIndex)
            },
            // The paper's own account of its shape, taken while the template
            // that produced it is still in hand. Everything downstream reads
            // this instead of asking the template again.
            pages: pages,
            // Stamped now rather than worked out at upload time. Someone can
            // look around in 示範模式, enrol afterwards, and by then nothing
            // distinguishes those papers from real ones except this.
            isDemo: DemoData.isEnabled ? true : nil,
            revision: 0)
    }
}
