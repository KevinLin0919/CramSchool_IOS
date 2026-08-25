import Foundation
import UIKit

// Graded papers on their way to the server.
//
// Grading is deliberately, completely offline: alignment, recognition and
// verdicts all run on the device against a master synced earlier. A teacher
// working through a stack in a classroom is not waiting on the network for
// anything. Uploading inside that loop would give the guarantee away — one
// flaky moment and the thing that worked stops working.
//
// So papers are filed to disk the instant the teacher moves on, and this
// drains them separately whenever it can. Nothing here is on anybody's
// critical path, which is why nothing here is allowed to block the UI, show a
// spinner, or ask for a tap.
@MainActor
final class UploadQueue: ObservableObject {
    static let shared = UploadQueue()

    @Published private(set) var isDraining = false

    /// Set when the whole queue is standing down rather than one paper
    /// failing — a revoked credential, or a server nobody can reach.
    @Published private(set) var haltedReason: String?

    /// Consecutive failed drains, for backoff. Reset by any success.
    private var failureStreak = 0
    private var nextAttempt: Date?

    private let store = GradingStore.shared

    private init() {}

    // MARK: - Draining

    /// Safe to call from anywhere, as often as you like: it returns
    /// immediately when there is nothing to do, when one is already running,
    /// or when the last attempt failed recently enough that another would
    /// just collect the same error.
    func drain() {
        guard !isDraining else { return }
        guard Credentials.isEnrolled, !DemoData.isEnabled else { return }
        guard ServerConfig.isConfigured else { return }
        if let nextAttempt, nextAttempt > Date() { return }
        guard store.papers.contains(where: \.needsUpload) else { return }

        Task { await run() }
    }

    private func run() async {
        isDraining = true
        defer { isDraining = false }

        // Oldest first: if the connection dies partway through a stack, the
        // papers that have been waiting longest are the ones that got out.
        let queued = store.papers
            .filter(\.needsUpload)
            .sorted { $0.scannedAt < $1.scannedAt }

        for paper in queued {
            do {
                try await upload(paper)
                failureStreak = 0
                nextAttempt = nil
                haltedReason = nil
            } catch let error as APIError {
                if handle(error, for: paper) { return }
            } catch {
                store.markUploadFailed(paper.id, error: error.localizedDescription,
                                       permanent: false)
                backOff()
                return
            }
        }
    }

    /// Returns true when the whole drain should stop rather than move to the
    /// next paper.
    private func handle(_ error: APIError, for paper: StoredPaper) -> Bool {
        switch error {
        case .unauthorized:
            // The credential is gone. Every remaining paper would fail the
            // same way, and `AppModel` is already routing to the login screen
            // with the server's own explanation.
            haltedReason = "裝置授權已失效，重新登入後會繼續上傳"
            return true

        case .badStatus(let code) where code == 400:
            // The server rejected the paper itself, not the attempt: its
            // template was deleted, or an image it references is gone.
            // Retrying collects the same refusal forever and buries the papers
            // that could still succeed.
            store.markUploadFailed(paper.id,
                                   error: "伺服器不接受這份紀錄（考卷模板可能已刪除）",
                                   permanent: true)
            return false

        case .notConfigured:
            haltedReason = "尚未設定伺服器位址"
            return true

        default:
            store.markUploadFailed(paper.id, error: error.localizedDescription,
                                   permanent: false)
            backOff()
            return true
        }
    }

    private func backOff() {
        failureStreak += 1
        let seconds = min(pow(2.0, Double(failureStreak)) * 15, 900)
        nextAttempt = Date().addingTimeInterval(seconds)
    }

    // MARK: - One paper

    private func upload(_ paper: StoredPaper) async throws {
        // Read before the first await. A correction landing mid-flight bumps
        // this, and the store refuses to mark a stale revision as delivered.
        let revision = paper.revision ?? 0

        var cellIDs: [Int: Int] = [:]
        for answer in paper.answers where wantsCrop(answer) {
            guard let image = store.cellImage(paper, question: answer.questionNo),
                  let png = image.pngData() else { continue }
            let ref = try await APIClient.shared.uploadImage(
                png, filename: "cell_\(paper.id.uuidString)_\(answer.questionNo).png")
            cellIDs[answer.questionNo] = ref.id
        }

        let payload = APIClient.SessionPayload(
            template_id: paper.templateID,
            // Nothing binds a paper to a student yet, and inventing one would
            // put a name on a record nobody verified.
            student_id: nil,
            // The full-page photograph is not sent. The review screens draw on
            // the cached master, so nothing on this side needs it, and the
            // session row holds one image where a two-sided paper has two.
            image_id: nil,
            scanned_at: Self.iso8601.string(from: paper.scannedAt),
            app_version: APIClient.appVersion,
            answers: paper.answers.map { answer in
                APIClient.SessionAnswer(
                    question_no: answer.questionNo,
                    expected: answer.expected,
                    recognized: answer.recognized.isEmpty ? nil : answer.recognized,
                    // The teacher's verdict, not the model's. The server
                    // recomputes the score from what it is sent, so sending
                    // the raw reading would report a total that ignores every
                    // correction the teacher made. What the model read is not
                    // lost — `recognized` and `expected` still carry it.
                    verdict: answer.effectiveVerdict.wireName,
                    teacher_value: answer.teacherValue,
                    cell_image_id: cellIDs[answer.questionNo])
            })

        try await APIClient.shared.upsertSession(clientUUID: paper.id, payload)
        store.markUploaded(paper.id, revision: revision)
    }

    /// Which crops are worth the upload.
    ///
    /// A corrected cell paired with what the teacher said it was is the most
    /// valuable row in the schema — it is a labelled handwriting sample
    /// produced as a by-product of work someone was doing anyway. A cell the
    /// model could not read is the next most useful. The rest are crops of
    /// answers everyone already agrees about, and sending twenty of them per
    /// paper across a cram school's uplink buys nothing.
    private func wantsCrop(_ answer: StoredAnswer) -> Bool {
        answer.teacherValue != nil || answer.parsedVerdict == .unsure
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension GradingVerdict {
    /// The spelling the API stores. Kept beside the upload rather than on the
    /// enum's own file so a future verdict cannot be added without someone
    /// deciding what the server should call it.
    var wireName: String {
        switch self {
        case .correct: return "correct"
        case .wrong: return "wrong"
        case .unsure: return "unsure"
        }
    }
}
