import CoreGraphics
import Foundation

// Routes one answer cell to the recogniser that suits its answer type.
//
// Sending every cell to a text recogniser is the obvious design and the wrong
// one. A circle-or-cross is a topology question with an exact answer and no
// model; a digit is a ten-way classification. Handing both to the same OCR
// throws away what we already know about the question and asks it to rediscover
// the alphabet from pixels.
//
// The routing key is the template's *expected* answer, which is the only
// reliable way to tell a letter O apart from a digit 0 — they are the same
// glyph. Note that the expected answer is used to pick the recogniser and
// nothing else: it never biases the reading itself, or a wrong answer would
// score as correct.

enum AnswerKind {
    /// One or more handwritten digits.
    case digits
    /// Circle or cross.
    case mark
    /// Chinese, mixed text, anything else — stays on the server for now.
    case unsupported

    private static let circleForms: Set<String> = ["O", "o", "○", "◯", "圈"]
    private static let crossForms: Set<String> = ["X", "x", "×", "✗", "叉"]

    static func infer(expected: String) -> AnswerKind {
        let trimmed = expected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unsupported }
        if circleForms.contains(trimmed) || crossForms.contains(trimmed) { return .mark }
        // ASCII only: Character.isNumber also accepts things like "½".
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) { return .digits }
        return .unsupported
    }

    /// Folds the many ways a template can spell a circle or a cross onto the
    /// single form `Mark` produces, so comparison stays an exact string match.
    /// Apply it to both sides before comparing.
    static func canonical(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if circleForms.contains(trimmed) { return Mark.circle.rawValue }
        if crossForms.contains(trimmed) { return Mark.cross.rawValue }
        return trimmed
    }
}

final class AnswerRecognizer {

    struct Reading {
        let text: String
        /// 0…1. Callers should collect several frames rather than act on a
        /// single low-confidence reading — see `AnswerAccumulator`.
        let confidence: Double
        let kind: AnswerKind
    }

    /// nil when the model could not be loaded; digit cells then return nil
    /// instead of the whole recogniser failing, so marks still work.
    private let digits: DigitRecognizer?
    let loadError: Error?

    init() {
        do {
            digits = try DigitRecognizer()
            loadError = nil
        } catch {
            digits = nil
            loadError = error
        }
    }

    /// Returns nil for a blank cell, an unsupported answer type, or a reading
    /// that could not be formed — all of which mean "no answer from this
    /// frame", not "wrong".
    func read(_ patch: CellPatch, expected: String) -> Reading? {
        switch AnswerKind.infer(expected: expected) {
        case .mark:
            guard let result = MarkRecognizer.recognize(patch) else { return nil }
            return Reading(text: result.mark.rawValue, confidence: result.confidence, kind: .mark)
        case .digits:
            guard let digits, let result = try? digits.recognize(patch) else { return nil }
            return Reading(text: result.text, confidence: result.confidence, kind: .digits)
        case .unsupported:
            return nil
        }
    }

    /// Lifts one cell out of a frame and reads it.
    ///
    /// `quad` is the cell's projected corners in the frame's pixel coordinates
    /// (tl, tr, br, bl); `aspect` is its true width/height on the master sheet.
    func read(frame: GrayBitmap, quad: [CGPoint], aspect: CGFloat, expected: String) -> Reading? {
        guard let patch = CellPatch(bitmap: frame, quad: quad, aspect: aspect) else { return nil }
        return read(patch, expected: expected)
    }
}

// MARK: - Cross-frame voting

/// Accumulates readings of one cell across frames.
///
/// A cell is seen dozens of times while the camera pans, and the readings are
/// far from independent failures — a blurred or clipped frame reads wrong in
/// its own way, while the true answer keeps recurring. Voting over frames is
/// the cheapest accuracy the pipeline can buy, and it costs one struct.
struct AnswerAccumulator {

    enum Tuning {
        /// Fewer samples than this and a single bad frame can still win.
        static let minSamples = 3
        /// The leader must hold this share of the total confidence before the
        /// answer is treated as settled.
        static let minLeaderShare = 0.6
    }

    private var votes: [String: Double] = [:]
    private(set) var samples = 0

    mutating func add(_ reading: AnswerRecognizer.Reading) {
        // Weighted by confidence, so an uncertain frame nudges rather than votes.
        votes[reading.text, default: 0] += reading.confidence
        samples += 1
    }

    /// The current leader, with its share of the accumulated confidence.
    var best: (text: String, share: Double)? {
        let total = votes.values.reduce(0, +)
        guard total > 0, let leader = votes.max(by: { $0.value < $1.value }) else { return nil }
        return (leader.key, leader.value / total)
    }

    /// Enough agreement, over enough frames, to stop asking.
    var isSettled: Bool {
        guard samples >= Tuning.minSamples, let best else { return false }
        return best.share >= Tuning.minLeaderShare
    }

    mutating func reset() {
        votes.removeAll()
        samples = 0
    }
}
