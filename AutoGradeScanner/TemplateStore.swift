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
        let box: CGRect          // normalized within the master image
        let answer: String
    }

    let id: Int
    let title: String
    let master: UIImage
    let questions: [Question]

    /// Demo templates only. The bundled master is a *blank* answer sheet, so
    /// there is no ink on it to read and a scripted answer is the only reason
    /// the offline demo shows anything at all. On a real paper a blank cell
    /// means the student left it empty, which is the teacher's call to make —
    /// see `LiveScanEngine`'s handling of `blankStreak`.
    let scriptedAnswers: [String]?

    var boxes: [CGRect] { questions.map(\.box) }
    var expected: [String] { questions.map(\.answer) }
}

enum TemplateStoreError: LocalizedError {
    case notCached
    case masterUnavailable

    var errorDescription: String? {
        switch self {
        case .notCached:
            return "這份考卷尚未下載，請連上伺服器後重新整理"
        case .masterUnavailable:
            return "考卷母卷影像損毀，請重新整理"
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
                try? await cacheDetail(id: summary.id)
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
        for page in detail.pages {
            try? await cacheMaster(templateID: id, page: page)
        }
        return detail
    }

    private func cacheMaster(templateID: Int, page: TemplatePageDTO) async throws {
        let url = masterURL(imageID: page.imageID)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
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

        guard let page = detail.pages.sorted(by: { $0.pageIndex < $1.pageIndex }).first else {
            throw TemplateStoreError.notCached
        }

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
                                             answer: $0.answer) }

        let summary = index.templates.first { $0.id == id }
        let title = summary.map { ExamTemplate(dto: $0).fullTitle } ?? detail.examName

        return ResolvedTemplate(id: id, title: title, master: master,
                                questions: questions, scriptedAnswers: nil)
    }

    private func cachedDetail(id: Int) -> TemplateDetailDTO? {
        guard let data = try? Data(contentsOf: detailURL(id)) else { return nil }
        return try? JSONDecoder().decode(TemplateDetailDTO.self, from: data)
    }

    /// True when a template can be graded with no network at all.
    func isAvailableOffline(id: Int) -> Bool {
        if DemoData.isEnabled, DemoData.bundledTemplates[id] != nil { return true }
        guard let detail = cachedDetail(id: id),
              let page = detail.pages.first else { return false }
        return FileManager.default.fileExists(atPath: masterURL(imageID: page.imageID).path)
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
