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
        guard hasWork else { return }

        Task { await run() }
    }

    /// One drain the caller can wait for, ignoring the backoff clock.
    ///
    /// Everything else here is deliberately invisible and deliberately
    /// patient. This is the one moment that is neither: the teacher is
    /// standing there about to sign out, and after that their unsent papers
    /// are deleted — the queue authenticates as whoever holds the credential,
    /// so a paper left behind belongs to nobody who can send it.
    ///
    /// The backoff reset is the point. A queue that failed four minutes ago is
    /// sitting out the next quarter of an hour, and "wait for the upload to
    /// finish" is advice a teacher cannot act on when nothing on screen says
    /// the queue is asleep.
    func flush() async {
        guard !isDraining else { return }
        guard Credentials.isEnrolled, !DemoData.isEnabled else { return }
        guard ServerConfig.isConfigured else { return }
        guard hasWork else { return }

        failureStreak = 0
        nextAttempt = nil
        await run()
    }

    private var hasWork: Bool {
        store.papers.contains(where: \.needsUpload) || !store.pendingDeletions.isEmpty
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
            // Deleted while this drain was under way. Sending it now would
            // put back on the server the paper the teacher just removed.
            guard store.papers.contains(where: { $0.id == paper.id }) else { continue }
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

        await sendDeletions()
    }

    /// After the uploads, never beside them. An upload of the same paper that
    /// was already in flight when the teacher deleted it would otherwise land
    /// after the delete, and the server would have the paper again.
    private func sendDeletions() async {
        for id in store.pendingDeletions {
            do {
                try await APIClient.shared.deleteSession(clientUUID: id)
                store.confirmDeleted(id)
                failureStreak = 0
                nextAttempt = nil
                haltedReason = nil
            } catch APIError.badStatus(let code, _) where code == 404 {
                // Never reached the server, or already gone: done either way.
                store.confirmDeleted(id)
            } catch APIError.unauthorized {
                haltedReason = "裝置授權已失效，重新登入後會繼續上傳"
                return
            } catch {
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

        case .badStatus(let code, let detail) where code == 400:
            // The server rejected the paper itself, not the attempt: its
            // template was deleted, or an image it references is gone.
            // Retrying collects the same refusal forever and buries the papers
            // that could still succeed.
            store.markUploadFailed(paper.id,
                                   error: detail ?? "伺服器不接受這份紀錄（考卷模板可能已刪除）",
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
        for answer in paper.answers {
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
                    cell_image_id: cellIDs[answer.questionNo],
                    alignment_leverage: answer.alignmentLeverage)
            })

        try await APIClient.shared.upsertSession(clientUUID: paper.id, payload)
        store.markUploaded(paper.id, revision: revision)
    }

    // NOTE: kept as prose rather than a predicate, because there is no
    // longer a decision to make.
    //
    /// Every crop, now.
    ///
    /// This used to send only corrected and unreadable cells, on the argument
    /// that the rest are crops of answers everyone already agrees about. The
    /// flaw in that is the word "agrees": a cell the model read confidently
    /// and WRONG agrees with nobody, and it is precisely the failure with no
    /// symptom — the grid shows a tidy green tick over a crop that was never
    /// kept, so there is nothing for a teacher to check it against.
    ///
    /// It surfaced the first time a teacher signed in on a second device.
    /// Everything they had graded came back with "—" where the evidence
    /// should be, because the only crops the server had ever been sent were
    /// the ones that had already gone wrong.
    ///
    /// The uplink argument does not survive arithmetic either: a cell crop is
    /// a few kilobytes, so a forty-question paper is well under half a
    /// megabyte, on a network the teacher is standing next to. What it buys
    /// is that a restored paper is as reviewable as a fresh one, and that
    /// `alignment_leverage` can be read across a whole paper rather than
    /// across the cells that already failed.


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
