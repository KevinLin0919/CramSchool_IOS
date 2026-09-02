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
    /// Exactly one handwritten digit, because the cell is a multiple-choice
    /// answer and cannot hold more.
    ///
    /// The constraint buys accuracy less by discarding a stray blob than by
    /// letting the votes agree: unconstrained, one frame reads 「4」 and the
    /// next reads 「41」, those are two separate keys competing for the same
    /// 75% majority, neither gets it, and the cell gives up as unsure.
    case choice
    /// Circle or cross.
    case mark
    /// Chinese, mixed text, anything else — stays on the server for now.
    case unsupported

    /// What the template declared, when it declared anything.
    ///
    /// The server has always sent `answer_type` and this client has always
    /// thrown it away and guessed the same thing back from the answer text.
    /// That guess cannot produce `choice` and should not: a one-digit answer
    /// belongs equally to a fill-in blank, so whether the cell is
    /// multiple-choice is something only the template knows.
    static func declared(_ type: String?) -> AnswerKind? {
        switch type {
        case "choice":  return .choice
        case "digit":   return .digits
        case "mark":    return .mark
        case "chinese", "text": return .unsupported
        default:        return nil        // absent, or a value added since
        }
    }

    private static let circleForms: Set<String> = ["O", "o", "○", "◯", "圈"]
    private static let crossForms: Set<String> = ["X", "x", "×", "✗", "叉"]
    /// Taiwanese papers set multiple-choice options as ①②③④ but students write
    /// a bare 1234, so the two sides never match until these are folded.
    private static let circledDigits: [Character: Character] = [
        "⓪": "0", "①": "1", "②": "2", "③": "3", "④": "4",
        "⑤": "5", "⑥": "6", "⑦": "7", "⑧": "8", "⑨": "9",
    ]

    /// Falls back to reading the answer key's own text. Used for the bundled
    /// demo and for anything synced before templates declared a type.
    static func infer(expected: String) -> AnswerKind {
        let trimmed = canonical(expected)
        guard !trimmed.isEmpty else { return .unsupported }
        if trimmed == Mark.circle.rawValue || trimmed == Mark.cross.rawValue { return .mark }
        // ASCII only: Character.isNumber also accepts things like "½".
        if trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) { return .digits }
        return .unsupported
    }

    /// Folds the many ways a template can spell an answer onto the single form
    /// the recognisers produce — circle/cross variants, and circled digits.
    /// Apply it to both sides before comparing.
    static func canonical(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if circleForms.contains(trimmed) { return Mark.circle.rawValue }
        if crossForms.contains(trimmed) { return Mark.cross.rawValue }
        return String(trimmed.map { circledDigits[$0] ?? $0 })
    }
}

final class AnswerRecognizer {

    /// How sure a single frame has to be before it is allowed to vote.
    ///
    /// These are not guesses. Run over the six real cells in TestFixtures, five
    /// come back at 0.84–1.00 with the runner-up nowhere near them, while the
    /// one cell whose reading flips between implementations sits at 0.53 with a
    /// margin of 0.08 — the model already knows it is guessing there. Both
    /// thresholds sit in that gap, so that cell is reported as unsure instead
    /// of being marked right or wrong.
    enum Confidence {
        static let minSoftmax = 0.65
        /// Lead over the runner-up. A digit can score a high softmax and still
        /// be a coin flip between two classes; the margin is what catches that.
        static let minMargin = 0.20
        /// Topology has no runner-up to measure, so marks are judged on the
        /// single number MarkRecognizer already reports — which is low exactly
        /// when a circle was left too open to tell from a cross.
        static let minMark = 0.5
    }

    struct Reading {
        let text: String
        /// 0…1. Callers should collect several frames rather than act on a
        /// single low-confidence reading — see `AnswerAccumulator`.
        let confidence: Double
        /// Lead over the second-best interpretation; 1 when there is no rival.
        let margin: Double
        let kind: AnswerKind

        /// Ink groups this reading dropped because the cell holds one
        /// character. Non-zero means something else was in the cell — kept so
        /// the diagnostic overlay can say so, because a stray blob that is
        /// silently discarded is still there and still worth fixing at its
        /// source.
        var discarded: Int = 0

        /// Marks only: how many times a probe circle round the middle met ink.
        /// The number the circle-or-cross decision was made on, carried so the
        /// diagnostic overlay can show it — the tuning was measured on flatbed
        /// scans and the camera is a different picture, so this is what says
        /// whether it still holds there.
        var probeCrossings: Int = 0

        /// Whether this frame is trustworthy enough to vote with. A reading
        /// that fails this is still evidence that *something* is written — it
        /// just isn't evidence of what.
        var isConfident: Bool {
            switch kind {
            // Same thresholds either way: the arity changes how many groups
            // are read, not how sure the model has to be about the one it
            // keeps.
            case .digits, .choice:
                return confidence >= Confidence.minSoftmax
                    && margin >= Confidence.minMargin
            case .mark: return confidence >= Confidence.minMark
            case .unsupported: return false
            }
        }
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
    func read(_ patch: CellPatch, expected: String,
              declaredType: String? = nil) -> Reading? {
        // The template's word first; the answer text only when it said
        // nothing.
        let kind = AnswerKind.declared(declaredType) ?? AnswerKind.infer(expected: expected)
        guard kind != .unsupported else { return nil }

        // Strip the box border / parentheses before anything looks at the ink.
        // Both recognisers are otherwise reading printed strokes as part of the
        // answer, which is by far the largest error source measured on real
        // papers — see CellPatch.withoutPrintedMarks.
        let clean = patch.withoutPrintedMarks()

        switch kind {
        case .mark:
            guard let result = MarkRecognizer.recognize(clean) else { return nil }
            return Reading(text: result.mark.rawValue, confidence: result.confidence,
                           margin: result.confidence, kind: .mark,
                           probeCrossings: result.crossings)
        case .digits, .choice:
            guard let digits,
                  let result = try? digits.recognize(clean, arity: kind == .choice ? .single : .any)
            else { return nil }
            return Reading(text: result.text, confidence: result.confidence,
                           margin: result.margin, kind: .digits,
                           discarded: result.discarded)
        case .unsupported:
            return nil
        }
    }

    /// Lifts one cell out of a frame and reads it.
    ///
    /// `quad` is the cell's projected corners in the frame's pixel coordinates
    /// (tl, tr, br, bl); `aspect` is its true width/height on the master sheet.
    func read(frame: GrayBitmap, quad: [CGPoint], aspect: CGFloat, expected: String,
              declaredType: String? = nil) -> Reading? {
        guard let patch = CellPatch(bitmap: frame, quad: quad, aspect: aspect) else { return nil }
        return read(patch, expected: expected, declaredType: declaredType)
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
        /// Raised from 3 once the overlay started colouring boxes for real:
        /// green has to mean right and red has to mean wrong, and the price of
        /// that is waiting a frame or two longer.
        static let minSamples = 4
        /// The leader must hold this share of the total confidence before the
        /// answer is treated as settled.
        static let minLeaderShare = 0.75
        /// After this many confident-enough looks with no agreement, stop
        /// waiting and report the cell as unreadable rather than leaving it
        /// blank forever.
        static let givesUpAfter = 8
    }

    private var votes: [String: Double] = [:]
    private(set) var samples = 0
    /// Frames where something was clearly written but not confidently read.
    private(set) var unsureSamples = 0

    /// Only confident readings vote. An unconfident one still counts as a
    /// sighting, so a cell nobody can read eventually gives up instead of
    /// sitting uncoloured forever.
    mutating func add(_ reading: AnswerRecognizer.Reading) {
        samples += 1
        guard reading.isConfident else {
            unsureSamples += 1
            return
        }
        // Weighted by confidence, so a marginal frame nudges rather than votes.
        votes[reading.text, default: 0] += reading.confidence
    }

    /// Seen plenty and still no agreement — the honest answer is "I can't read
    /// this", which the overlay shows in yellow rather than guessing.
    var hasGivenUp: Bool {
        samples >= Tuning.givesUpAfter && !isSettled
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
        unsureSamples = 0
    }
}
