import UIKit

// Offline demo / mock layer. When 示範模式 is on (default), every APIClient
// call and the grading pipeline return canned data instead of hitting the
// LAN backends — so a sideloaded build works anywhere with no server on the
// network. Turn it off in 設定 once the real backends are reachable.
final class DemoData {
    static let shared = DemoData()

    static let modeKey = "demo.mode"

    // Default ON: the key is unset on a fresh install, and a demo build
    // should work offline out of the box.
    static var isEnabled: Bool {
        if UserDefaults.standard.object(forKey: modeKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: modeKey)
    }

    // MARK: - In-memory store (seeded with samples, mutable for the session)

    struct Sample {
        let id: Int
        let examName: String
        let answers: [String]
        let createdAt: String
    }

    private let lock = NSLock()
    private var store: [Sample]

    private init() { store = DemoData.seed }

    private static let seed: [Sample] = [
        Sample(id: 9001, examName: "國一數學第三次段考",
               answers: ["12", "5", "36", "8", "144", "7", "20", "9"],
               createdAt: "2026-07-08 10:30:00"),
        Sample(id: 9002, examName: "國二英文期中複習卷",
               answers: ["B", "apple", "C", "run", "D", "A", "cat", "B"],
               createdAt: "2026-07-06 14:05:00"),
        Sample(id: 9003, examName: "國三理化模擬考",
               answers: ["H2O", "3", "O2", "5", "CO2", "2"],
               createdAt: "2026-07-04 09:15:00"),
        Sample(id: 9004, examName: "高一數學週考",
               answers: ["4", "9", "16", "25", "36", "49"],
               createdAt: "2026-07-02 16:40:00"),
        Sample(id: 9005, examName: "高二國文複習",
               answers: ["之", "乎", "者", "也", "矣", "焉"],
               createdAt: "2026-06-30 11:20:00"),
    ]

    // MARK: - Template endpoints

    func templateList(search: String?) -> [ExamTemplate] {
        lock.lock(); let samples = store; lock.unlock()
        let all = samples.map {
            ExamTemplate(id: $0.id, examName: $0.examName,
                         annotationCount: $0.answers.count, createdAt: $0.createdAt)
        }
        guard let search, !search.isEmpty else { return all }
        return all.filter { $0.examName.localizedCaseInsensitiveContains(search) }
    }

    func templateDetail(id: Int) -> TemplateDetail {
        lock.lock(); let sample = store.first { $0.id == id }; lock.unlock()
        let answers = sample?.answers ?? []
        let boxes = DemoData.gridBoxes(count: answers.count,
                                       width: WebCanvas.width, height: WebCanvas.height)
        let annotations = zip(answers, boxes).map { answer, b in
            TemplateAnnotation(className: "答案區",
                               bbox: [b[0], b[1], b[2] - b[0], b[3] - b[1]],
                               answer: answer)
        }
        return TemplateDetail(id: id, examName: sample?.examName ?? "示範考卷",
                              pages: [TemplatePage(image: nil, annotations: annotations)])
    }

    func answers(for id: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return store.first { $0.id == id }?.answers ?? []
    }

    func rename(id: Int, name: String) {
        lock.lock(); defer { lock.unlock() }
        guard let i = store.firstIndex(where: { $0.id == id }) else { return }
        let s = store[i]
        store[i] = Sample(id: s.id, examName: name, answers: s.answers, createdAt: s.createdAt)
    }

    func delete(id: Int) {
        lock.lock(); defer { lock.unlock() }
        store.removeAll { $0.id == id }
    }

    func create(name: String, answers: [String]) {
        lock.lock(); defer { lock.unlock() }
        let nextID = (store.map(\.id).max() ?? 9000) + 1
        store.insert(Sample(id: nextID, examName: name, answers: answers,
                            createdAt: DemoData.nowString()), at: 0)
    }

    // MARK: - Detection / OCR

    // predict returns [x1, y1, x2, y2] in the submitted image's pixel space.
    func detect(imageBase64: String) -> [[Double]] {
        let size = DemoData.decodedSize(imageBase64) ?? CGSize(width: 1000, height: 1400)
        return DemoData.gridBoxes(count: 6, width: Double(size.width), height: Double(size.height))
    }

    func ocr(count: Int) -> [String] {
        let pool = ["A", "B", "C", "D", "12", "7"]
        return (0..<max(count, 0)).map { pool[$0 % pool.count] }
    }

    // MARK: - Grading

    // Fabricate a plausible graded result directly from the captured photo:
    // lay the template's answers over a tidy grid and mark ~75% correct.
    func grade(image: UIImage, templateID: Int, templateTitle: String) -> GradingResult {
        let expected = answers(for: templateID)
        let count = expected.isEmpty ? 6 : expected.count
        let boxes = DemoData.gridBoxes(count: count, width: 1, height: 1) // normalized 0...1
        var graded: [GradedAnswer] = []
        for i in 0..<count {
            let exp = i < expected.count ? expected[i] : ""
            let correct = i % 4 != 3            // every 4th wrong, deterministic
            let recognized = correct ? exp : DemoData.wrongVariant(of: exp)
            let b = boxes[i]
            let rect = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            graded.append(GradedAnswer(id: i, expected: exp, recognized: recognized,
                                       isCorrect: correct && !exp.isEmpty, rect: rect))
        }
        return GradingResult(image: image, answers: graded,
                             templateTitle: templateTitle, date: Date())
    }

    // MARK: - Helpers

    // A tidy 2-column grid of boxes as [x1, y1, x2, y2] in a width×height space.
    static func gridBoxes(count: Int, width: Double, height: Double) -> [[Double]] {
        guard count > 0 else { return [] }
        let cols = 2
        let rows = Int((Double(count) / Double(cols)).rounded(.up))
        let marginX = width * 0.10
        let top = height * 0.16
        let cellW = (width - marginX * 2) / Double(cols)
        let cellH = (height * 0.70) / Double(max(rows, 1))
        let boxW = cellW * 0.62
        let boxH = min(cellH * 0.45, height * 0.06)
        return (0..<count).map { i in
            let r = i / cols, c = i % cols
            let cx = marginX + cellW * (Double(c) + 0.5)
            let cy = top + cellH * (Double(r) + 0.5)
            let x1 = cx - boxW / 2, y1 = cy - boxH / 2
            return [x1, y1, x1 + boxW, y1 + boxH]
        }
    }

    static func wrongVariant(of exp: String) -> String {
        guard !exp.isEmpty else { return "?" }
        if exp.range(of: #"^\d+$"#, options: .regularExpression) != nil, let n = Int(exp) {
            return String(n + 1)
        }
        let swaps: [Character: Character] = ["A": "D", "B": "D", "C": "A", "D": "B",
                                             "之": "乎", "乎": "者", "者": "之"]
        if let first = exp.first, let s = swaps[first] {
            return String(s) + exp.dropFirst()
        }
        return exp + "?"
    }

    private static func nowString() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: Date())
    }

    private static func decodedSize(_ base64: String) -> CGSize? {
        let raw = base64.contains(",") ? String(base64.split(separator: ",").last ?? "") : base64
        guard let data = Data(base64Encoded: raw), let img = UIImage(data: data) else { return nil }
        return img.size
    }
}
