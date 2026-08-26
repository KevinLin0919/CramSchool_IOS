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

        /// The server's id for this page's picture, or nil for a bundled demo
        /// sheet. A graded paper records it so the result screen can redraw
        /// the sheet it was actually marked against — a template id alone
        /// says only which paper it *is*, not which picture it *was*.
        let imageID: Int?
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

    /// Decoded masters, by image id.
    ///
    /// A stack of forty papers is usually forty results against the same two
    /// sheets, and each one asks for its own backdrop by id. Decoding a 1600px
    /// JPEG per paper is both the cost and the memory; `UIImage` is a
    /// reference type, so handing every caller the same instance makes the
    /// stack cost one decode per side however long it gets. `NSCache` because
    /// the eviction should be the system's call under pressure, not a number
    /// invented here.
    private let decoded: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 24
        return cache
    }()

    /// The sync currently on the wire, if any. See `refresh()`.
    private var inFlight: Task<Void, Never>?

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

    /// Pictures kept for what has already been graded rather than for what is
    /// still gradeable. A template that drops a page stops fetching it; the
    /// results filed against it still have to draw it.
    private var archiveDir: URL { root.appendingPathComponent("archive", isDirectory: true) }

    private func archiveURL(imageID: Int) -> URL {
        archiveDir.appendingPathComponent("\(imageID).jpg")
    }

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
        for dir in [root, detailDir, masterDir, archiveDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Loading

    private func loadFromDisk() {
        ensureDirectories()
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode(TemplateIndex.self, from: data) {
            if decoded.version == TemplateIndex.current {
                index = decoded
            } else {
                // Written by a build whose cache cannot be trusted. Drop it
                // and sync from scratch: a few hundred KB once, against a
                // template that silently renders the wrong sheet forever.
                purge()
                return
            }
        }
        publish()
    }

    private func saveIndex() {
        ensureDirectories()
        index.version = TemplateIndex.current
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

    /// One sync at a time, and callers that arrive mid-flight wait for the one
    /// already running rather than starting a second.
    ///
    /// The app asks for a refresh from several places at once on launch — the
    /// templates screen appearing, the credential notification firing — which
    /// put two syncs on the wire downloading the same masters over each other.
    ///
    /// The work runs in an unstructured `Task` on purpose. A sync started from
    /// a SwiftUI `.task` is cancelled when that view goes away, and a master
    /// download aborted halfway leaves the cache in exactly the state this
    /// file spent a day untangling. Detaching it from the caller's lifetime
    /// means leaving a screen no longer half-writes the cache.
    func refresh() async {
        if let existing = inFlight {
            await existing.value
            return
        }
        let task = Task { await self.performRefresh() }
        inFlight = task
        await task.value
        // Only if it is still ours. `purge` cancels and clears mid-flight, and
        // a new sync may already have taken the slot by the time we wake up;
        // clearing that one would let a third caller start a duplicate.
        if inFlight == task { inFlight = nil }
    }

    private func performRefresh() async {
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

        // Every master first, and a failure is allowed to escape.
        //
        // The detail file is what `isDetailStale` reads to decide there is
        // nothing to do, so writing it before the images are safely down
        // records a template as current while a page of it is still missing —
        // and nothing ever retries. That is not hypothetical: one page landed,
        // the other lost its connection, and the template went on rendering
        // the previous server's sheet with no way back.
        //
        // `force` because the filename is the server's image id, which is
        // unique only within one database. Rebuild the server and template 2
        // is a different paper wearing the same numbers, so "2_1600.jpg
        // exists" answers a question nobody asked. Reaching here at all means
        // the template is not what we last saw; its pages are not either.
        for page in detail.pages {
            try await cacheMaster(templateID: id, page: page, force: true)
        }

        if let data = try? JSONEncoder().encode(detail) {
            try? data.write(to: detailURL(id), options: .atomic)
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
        // Decode before storing. A truncated body still writes a file, and a
        // file is all the rest of this class checks for — so a bad download
        // would be indistinguishable from a good one until the scanner had
        // nothing to align against.
        guard UIImage(data: data) != nil else {
            throw TemplateStoreError.masterUnavailable
        }
        ensureDirectories()
        // Not `try?`: the caller decides a template is fully cached by whether
        // this returned, so a write that failed has to say so.
        try data.write(to: url, options: .atomic)
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
                                               questions: questions,
                                               imageID: page.imageID))
        }

        let summary = index.templates.first { $0.id == id }
        let title = summary.map { ExamTemplate(dto: $0).fullTitle } ?? detail.examName

        return ResolvedTemplate(id: id, title: title, pages: pages, scriptedAnswers: nil)
    }

    /// The picture behind one image id, for a record that names it.
    ///
    /// Tries the template cache first, because a page still in use is already
    /// there under this very id — masters have always been filed by image id,
    /// which is what makes this possible at all. Falling back to the image
    /// endpoint rather than the template's own `/master` is deliberate: the
    /// caller is asking about a paper that was graded some time ago, and the
    /// template it belonged to is the one thing that may have moved since.
    func master(imageID: Int) async throws -> UIImage {
        let key = NSNumber(value: imageID)
        if let image = decoded.object(forKey: key) { return image }

        if let image = UIImage(contentsOfFile: masterURL(imageID: imageID).path) {
            decoded.setObject(image, forKey: key)
            return image
        }
        let archived = archiveURL(imageID: imageID)
        if let image = UIImage(contentsOfFile: archived.path) {
            decoded.setObject(image, forKey: key)
            return image
        }

        let data = try await APIClient.shared.imageContent(id: imageID)
        guard let image = UIImage(data: data) else {
            throw TemplateStoreError.masterUnavailable
        }
        ensureDirectories()
        try? data.write(to: archived, options: .atomic)
        decoded.setObject(image, forKey: key)
        return image
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
        // Stop any sync first. It is holding the ids of the server we are
        // throwing away, and letting it finish would write those files back in
        // behind us — which is the whole failure this purge exists to undo.
        inFlight?.cancel()
        inFlight = nil
        decoded.removeAllObjects()
        try? FileManager.default.removeItem(at: root)
        index = .empty
        ensureDirectories()
        publish()
    }
}
