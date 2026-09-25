import Foundation
import SwiftUI

// A teacher's classes, and the sittings their papers are filed under.
//
// The roster is what makes "whose paper is this" a choice from a short list
// rather than a reading of handwriting. It is cached on the device, because the
// moment it is needed — straight after a stack is scanned — is often a moment
// with no network.

@MainActor
final class RosterStore: ObservableObject {
    static let shared = RosterStore()

    @Published private(set) var classes: [APIClient.ClassDTO] = []
    @Published var lastError: String?

    private static let cacheKey = "roster.classes"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode([APIClient.ClassDTO].self, from: data) {
            classes = cached
        }
    }

    /// Real classes first; a simulated one is for showing the reports and is
    /// never where a teacher's own papers should be filed by accident.
    var realClasses: [APIClient.ClassDTO] { classes.filter { !$0.is_simulated } }

    func schoolClass(_ id: Int?) -> APIClient.ClassDTO? {
        guard let id else { return nil }
        return classes.first { $0.id == id }
    }

    func studentName(_ id: Int?) -> String? {
        guard let id else { return nil }
        for cls in classes {
            if let s = cls.students.first(where: { $0.id == id }) { return s.name }
        }
        return nil
    }

    func refresh() async {
        guard Credentials.isEnrolled, !DemoData.isEnabled else { return }
        do {
            set(try await APIClient.shared.listClasses())
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func clear() {
        classes = []
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // Edits go to the server first and replace the cached class with its
    // answer, so the device never holds a roster the server does not.

    func createClass(_ name: String) async {
        await run {
            let made = try await APIClient.shared.createClass(name: name)
            self.replace(made)
        }
    }

    func renameClass(_ id: Int, to name: String) async {
        await run {
            let renamed = try await APIClient.shared.renameClass(id: id, name: name)
            self.replace(renamed)
        }
    }

    func addStudent(_ name: String, to classID: Int) async {
        await run {
            let updated = try await APIClient.shared.addStudent(classID: classID, name: name)
            self.replace(updated)
        }
    }

    func renameStudent(_ studentID: Int, in classID: Int, to name: String) async {
        await run {
            let updated = try await APIClient.shared.renameStudent(classID: classID,
                                                                   studentID: studentID,
                                                                   name: name)
            self.replace(updated)
        }
    }

    func removeStudent(_ studentID: Int, from classID: Int) async {
        await run {
            try await APIClient.shared.removeStudent(classID: classID, studentID: studentID)
            await self.refresh()
        }
    }

    private func run(_ work: @escaping @MainActor () async throws -> Void) async {
        do {
            try await work()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func replace(_ cls: APIClient.ClassDTO) {
        var next = classes.filter { $0.id != cls.id }
        next.append(cls)
        set(next.sorted { ($0.is_simulated ? 1 : 0, $0.name) < ($1.is_simulated ? 1 : 0, $1.name) })
    }

    private func set(_ list: [APIClient.ClassDTO]) {
        classes = list
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }
}

/// One sitting as the device knows it: a class, a paper, a Taipei day.
struct LocalExam: Codable, Equatable, Identifiable {
    var id: UUID
    let classID: Int
    let className: String
    let templateID: Int
    let templateTitle: String
    /// yyyy-MM-dd in Asia/Taipei. A paper graded at 7am belongs to today.
    let date: String
    var sitting: Int
    /// The server has this exam under this id.
    var synced: Bool
}

@MainActor
final class ExamStore: ObservableObject {
    static let shared = ExamStore()

    @Published private(set) var exams: [LocalExam] = []

    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exams.json")
    }

    private init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([LocalExam].self, from: data) {
            exams = saved
        }
    }

    nonisolated static let taipei: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    nonisolated static func day(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = taipei
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func exam(_ id: UUID?) -> LocalExam? {
        guard let id else { return nil }
        return exams.first { $0.id == id }
    }

    /// Today's sitting of this paper for this class, started if there is none.
    /// Coming back to the camera later the same day continues the same stack.
    func current(classID: Int, className: String, templateID: Int,
                 templateTitle: String) -> LocalExam {
        let today = Self.day()
        if let existing = exams
            .filter({ $0.classID == classID && $0.templateID == templateID && $0.date == today })
            .max(by: { $0.sitting < $1.sitting }) {
            return existing
        }
        let exam = LocalExam(id: UUID(), classID: classID, className: className,
                             templateID: templateID, templateTitle: templateTitle,
                             date: today, sitting: 1, synced: false)
        exams.append(exam)
        save()
        return exam
    }

    /// A retake: the same paper and class again today, as a separate sitting.
    func newSitting(after exam: LocalExam) -> LocalExam {
        let next = (exams.filter { $0.classID == exam.classID && $0.templateID == exam.templateID
                                   && $0.date == exam.date }.map(\.sitting).max() ?? 1) + 1
        let fresh = LocalExam(id: UUID(), classID: exam.classID, className: exam.className,
                              templateID: exam.templateID, templateTitle: exam.templateTitle,
                              date: exam.date, sitting: next, synced: false)
        exams.append(fresh)
        save()
        return fresh
    }

    func markSynced(_ id: UUID, serverID: UUID) {
        guard let i = exams.firstIndex(where: { $0.id == id }) else { return }
        if serverID != id {
            // Another device started this sitting first. File under theirs.
            exams[i].id = serverID
            GradingStore.shared.moveExam(from: id, to: serverID)
        }
        exams[i].synced = true
        dedupe()
        save()
    }

    /// Exams the server knows about that this device has never seen — after a
    /// sign-in on a new phone, say.
    func merge(_ server: [APIClient.ExamDTO]) {
        for dto in server where !exams.contains(where: { $0.id == dto.client_uuid }) {
            exams.append(LocalExam(id: dto.client_uuid, classID: dto.class_id,
                                   className: dto.class_name, templateID: dto.template_id,
                                   templateTitle: dto.template_name, date: dto.exam_date,
                                   sitting: dto.sitting, synced: true))
        }
        save()
    }

    func clear() {
        exams = []
        try? FileManager.default.removeItem(at: url)
    }

    private func dedupe() {
        var seen = Set<UUID>()
        exams = exams.filter { seen.insert($0.id).inserted }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(exams) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
