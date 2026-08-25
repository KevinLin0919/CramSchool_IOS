import UIKit

// Offline mirror of the template server.
//
// Everything the scanner needs to grade a paper is read from disk. The network
// is only ever used to *refresh* that mirror, never to serve a scan in
// progress — a teacher halfway through a stack of papers when the Wi-Fi drops
// keeps working, and the alternative (fetching the master sheet when the
// camera opens) turns every flaky moment into a dead scanner.
//
// Sync is incremental: the server hands back an opaque cursor, the client
// gives it back next time, and only what changed comes down. Deletions arrive
// as tombstones, which is the reason a soft delete exists server-side at all —
// a hard DELETE would leave a device that was offline that week holding a
// template nobody can grade against any more.

/// Everything one scan session needs, with no notion of where it came from.
///
/// This is the seam that lets the same engine grade a bundled demo sheet and a
/// template downloaded five minutes ago. Before it existed, `LiveScanEngine`
/// reached into `DemoData` directly and live grading simply did not run
/// outside 示範模式 — the app quietly fell back to the one-shot server path,
/// which looks like a different product.
struct ResolvedTemplate {
    struct Question {
        let number: Int          // stable question_no, not an array index
        let box: CGRect          // normalized within its own page's master
        let answer: String
        let pageIndex: Int       // which sheet side this cell is printed on
    }

    /// One physical side of the paper: its own master image and its own cells.
    ///
    /// The server has stored templates this way all along — `template_pages`
    /// keyed by `page_index`, with `GET /templates/{id}/master?page=N` already
    /// taking the page — and `TemplateDetailDTO.pages` has always been an
    /// array. This client collapsed all of it with a `.first`, which is why a
    /// double-sided paper could only ever be half graded.
    struct Page {
        let index: Int
        let master: UIImage
        let questions: [Question]
    }

    let id: Int
    let title: String
    /// Ascending by `index`, never empty — `resolve` throws rather than hand
    /// back a template with nothing to grade against.
    let pages: [Page]

    /// Demo templates only. The bundled master is a *blank* answer sheet, so
    /// there is no ink on it to read and a scripted answer is the only reason
    /// the offline demo shows anything at all. On a real paper a blank cell
    /// means the student left it empty, which is the teacher's call to make —
    /// see `LiveScanEngine`'s handling of `blankStreak`.
    let scriptedAnswers: [String]?

    /// Every cell on the paper, page by page. This flat order is the index
    /// space the scan session works in, so it has to be stable: pages
    /// ascending, then question number ascending within a page.
    var questions: [Question] { pages.flatMap(\.questions) }

    var boxes: [CGRect] { questions.map(\.box) }
    var expected: [String] { questions.map(\.answer) }

    /// The first page's master. Kept for the places that legitimately want one
    /// representative image — the picker's preview, the alignment debug view.
    var master: UIImage { pages[0].master }

    var pageCount: Int { pages.count }

    /// What to call a page on screen. A sheet has a front and a back and that
    /// is what teachers say; a four-page booklet does not, and numbering it is
    /// the only thing that reads naturally.
    func pageLabel(_ index: Int) -> String {
        guard pages.count == 2 else { return "\(index + 1)" }
        return index == 0 ? "正面" : "背面"
    }
}

enum TemplateStoreError: LocalizedError {
    case notCached
    case masterUnavailable
    case duplicateQuestionNumbers

    var errorDescription: String? {
        switch self {
        case .notCached:
            return "這份考卷尚未下載，請連上伺服器後重新整理"
        case .masterUnavailable:
            return "考卷母卷影像損毀，請重新整理"
        case .duplicateQuestionNumbers:
            return "這份考卷的題號跨頁重複，無法批改，請重新編號後再同步"
        }
    }
}

@MainActor
final class TemplateStore: ObservableObject {
    static let shared = TemplateStore()

    @Published private(set) var templates: [ExamTemplate] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var syncError: String?
    @Published private(set) var lastSyncedAt: Date?

    /// The width asked of the server. XFeat resizes to 832x608 internally, so
    /// a larger master buys the matcher nothing; 1600 leaves headroom for the
    /// preview thumbnail without shipping a 12MP original over the tailnet.
    private static let masterWidth = 1600

    private var index = TemplateIndex.empty

    private init() {
        loadFromDisk()
    }

    // MARK: - Disk layout

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        return base.appendingPathComponent("TemplateCache", isDirectory: true)
    }

    private var indexURL: URL { root.appendingPathComponent("index.json") }
    private var detailDir: URL { root.appendingPathComponent("detail", isDirectory: true) }
    private var masterDir: URL { root.appendingPathComponent("master", isDirectory: true) }

    private func detailURL(_ id: Int) -> URL {
        detailDir.appendingPathComponent("\(id).json")
    }

    /// Masters are keyed by the server's image id, not the template id: the
    /// id changes only when the picture itself changes, so renaming a template
    /// or editing its boxes does not force a re-download.
    private func masterURL(imageID: Int) -> URL {
        masterDir.appendingPathComponent("\(imageID)_\(Self.masterWidth).jpg")
    }

    private func ensureDirectories() {
        for dir in [root, detailDir, masterDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Loading

    private func loadFromDisk() {
        ensureDirectories()
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(TemplateIndex.self, from: data) {
            index = decoded
        }
        publish()
    }

    private func saveIndex() {
        ensureDirectories()
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private func publish() {
        templates = index.templates
            .filter { !$0.isDeleted }
            .sorted { $0.updatedAt > $1.updatedAt }
            .map(ExamTemplate.init(dto:))
    }

    // MARK: - Sync

    func refresh() async {
        guard Credentials.isEnrolled else {
            syncError = "尚未註冊裝置"
            return
        }
        isSyncing = true
        syncError = nil
        do {
            try await sync()
            lastSyncedAt = Date()
        } catch {
            // A failed sync is not a failed app: whatever is already on disk
            // still grades. Surface it, keep going.
            syncError = error.localizedDescription
        }
        isSyncing = false
    }

    private func sync() async throws {
        let page = try await APIClient.shared.listTemplates(updatedSince: index.cursor)

        var merged = Dictionary(uniqueKeysWithValues: index.templates.map { ($0.id, $0) })
        for incoming in page.templates {
            merged[incoming.id] = incoming
            if incoming.isDeleted {
                try? FileManager.default.removeItem(at: detailURL(incoming.id))
            }
        }
        index.templates = Array(merged.values)
        // Only advance on a cursor the server actually returned. An empty page
        // carries none, and inventing one here would step the client past
        // changes it never saw.
        if let cursor = page.syncCursor { index.cursor = cursor }
        saveIndex()
        publish()

        // Details and masters come down lazily, except for anything whose
        // cached copy is now stale — a teacher who opens the scanner offline
        // should find what they synced this morning, not a spinner.
        for summary in page.templates where !summary.isDeleted {
            if isDetailStale(summary) {
                // `@discardableResult` does not survive `try?` — that wraps the
                // return in an Optional, and it is the Optional going unused.
                _ = try? await cacheDetail(id: summary.id)
            }
        }
    }

    private func isDetailStale(_ summary: TemplateSummaryDTO) -> Bool {
        guard let data = try? Data(contentsOf: detailURL(summary.id)),
              let cached = try? JSONDecoder().decode(TemplateDetailDTO.self, from: data) else {
            return true
        }
        return cached.revision != summary.revision
    }

    @discardableResult
    private func cacheDetail(id: Int) async throws -> TemplateDetailDTO {
        let detail = try await APIClient.shared.templateDetail(id: id)
        ensureDirectories()
        if let data = try? JSONEncoder().encode(detail) {
            try? data.write(to: detailURL(id), options: .atomic)
        }
        // Re-fetch the masters too, without asking whether a file with that
        // name is already there.
        //
        // This runs only when the detail was missing or its revision moved —
        // in other words, when the template is not what we last saw. The image
        // id inside it is assigned by the server and is unique only within one
        // database, so "a file called 2_1600.jpg exists" says nothing about
        // whether it is THIS template's page. Rebuild the server and template
        // 2 becomes a different paper wearing the same numbers; the app went
        // on drawing the old sheet, and drew it confidently.
        for page in detail.pages {
            try? await cacheMaster(templateID: id, page: page, force: true)
        }
        return detail
    }

    /// `force` skips the "already on disk" shortcut. Callers that are merely
    /// filling a gap leave it off; callers that have just learned the template
    /// changed must set it, because the filename cannot tell them apart.
    private func cacheMaster(templateID: Int, page: TemplatePageDTO,
                             force: Bool = false) async throws {
        let url = masterURL(imageID: page.imageID)
        if !force, FileManager.default.fileExists(atPath: url.path) { return }
        let data = try await APIClient.shared.masterImage(templateID: templateID,
                                                          page: page.pageIndex,
                                                          width: Self.masterWidth)
        ensureDirectories()
        try? data.write(to: url, options: .atomic)
    }

    // MARK: - Resolving

    /// Assembles what a scan session needs. Reads disk first and only touches
    /// the network for something genuinely missing, so a synced device never
    /// waits on the tailnet to start grading.
    func resolve(id: Int) async throws -> ResolvedTemplate {
        if DemoData.isEnabled, let demo = DemoData.resolved(id: id) {
            return demo
        }

        var detail = cachedDetail(id: id)
        if detail == nil {
            detail = try await cacheDetail(id: id)
        }
        guard let detail else { throw TemplateStoreError.notCached }

        let ordered = detail.pages.sorted { $0.pageIndex < $1.pageIndex }
        guard !ordered.isEmpty else { throw TemplateStoreError.notCached }

        // The server's two halves disagree about what makes a question unique.
        // A template's cells are unique per PAGE (`uq_box_question_no` is on
        // `page_id, question_no`), but a grading session's answers are unique
        // per SESSION (`uq_answer_question_no`), and the upload schema rejects
        // a repeat outright. So a paper that restarts numbering on its back is
        // storable and ungradeable — and worse, `expectedAnswers` flattens and
        // sorts by question number, which would quietly pair every cell with
        // the wrong standard answer. Refusing is the only honest option; a
        // wrong grade that looks right is the failure worth preventing.
        var seen = Set<Int>()
        for page in ordered {
            for box in page.boxes where !seen.insert(box.questionNo).inserted {
                throw TemplateStoreError.duplicateQuestionNumbers
            }
        }

        var pages: [ResolvedTemplate.Page] = []
        for page in ordered {
            if !FileManager.default.fileExists(atPath: masterURL(imageID: page.imageID).path) {
                try await cacheMaster(templateID: id, page: page)
            }
            guard let master = UIImage(contentsOfFile: masterURL(imageID: page.imageID).path) else {
                throw TemplateStoreError.masterUnavailable
            }
            let questions = page.boxes
                .sorted { $0.questionNo < $1.questionNo }
                .map { ResolvedTemplate.Question(number: $0.questionNo,
                                                 box: $0.rect,
                                                 answer: $0.answer,
                                                 pageIndex: page.pageIndex) }
            pages.append(ResolvedTemplate.Page(index: page.pageIndex,
                                               master: master,
                                               questions: questions))
        }

        let summary = index.templates.first { $0.id == id }
        let title = summary.map { ExamTemplate(dto: $0).fullTitle } ?? detail.examName

        return ResolvedTemplate(id: id, title: title, pages: pages, scriptedAnswers: nil)
    }

    private func cachedDetail(id: Int) -> TemplateDetailDTO? {
        guard let data = try? Data(contentsOf: detailURL(id)) else { return nil }
        return try? JSONDecoder().decode(TemplateDetailDTO.self, from: data)
    }

    /// True when a template can be graded with no network at all. Every page
    /// has to be there: a two-sided paper whose back never downloaded is not
    /// offline-ready, it is a paper that stops halfway through.
    func isAvailableOffline(id: Int) -> Bool {
        if DemoData.isEnabled, DemoData.bundledTemplates[id] != nil { return true }
        guard let detail = cachedDetail(id: id), !detail.pages.isEmpty else { return false }
        return detail.pages.allSatisfy {
            FileManager.default.fileExists(atPath: masterURL(imageID: $0.imageID).path)
        }
    }

    /// Drops every cached template. Used when a device is un-enrolled — the
    /// answer keys should not outlive the credential that fetched them.
    func purge() {
        try? FileManager.default.removeItem(at: root)
        index = .empty
        ensureDirectories()
        publish()
    }
}
