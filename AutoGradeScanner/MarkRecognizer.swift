import Foundation

// Circle-or-cross recognition.
//
// The question is "does anything run through the middle?", not "is anything
// enclosed?". A cross's strokes radiate from where they meet; a circle — or an
// arc, or a C, or a U — is empty inside. That holds however wide the student
// left the gap, which is the whole point: these children do not draw closed
// circles with a small gap, they draw open arcs, and the opening is 30–50% of
// the diameter.
//
// What changed is how that question gets measured, not the question.
//
// It used to be measured by walking three thin rings round the mark and
// counting how many times each met ink. That reading rests on about 540 sampled
// points out of sixteen thousand, and it is brittle in exactly the way a sparse
// sample is: shift a real cell two pixels and the crossing count moved on 37%
// of them. The thresholds absorbed some of that, which looked like robustness
// and was luck. Measured against 65 hand-labelled cells off five 康軒
// worksheets, the probe scored 63%, and its errors were not spread evenly —
// seventeen circles read as crosses against one cross read as a circle, ten of
// them at full confidence. A confident wrong answer is the one failure the
// vote cannot rescue, because every frame agrees.
//
// Now the same question is asked by integrating over the whole mark instead:
// isolate one blob of ink, describe it as fourteen ratios (`MarkFeatures`), and
// let a small decision forest (`MarkForest`) draw the boundary. Same insight,
// measured in a way that a couple of pixels cannot overturn.
//
//                      flatbed 65    phone, readable    phone, barely legible
//   probe                     63%                43%                       0%
//   forest                    96%                90%      declines all of them
//
// The last column is not a shortfall. A crop a person cannot read should
// produce no vote at all, and a cell nothing voted on becomes 不確定 — which
// is what the teacher is for. Guessing there is how a scan quietly marks a
// child wrong.

enum Mark: String {
    case circle = "O"
    case cross = "X"
}

enum MarkRecognizer {

    struct Result {
        let mark: Mark
        /// 0…1. The forest's agreement: the share of trees that voted for the
        /// winning class, so 0.5 is a coin flip and 1.0 is unanimous. Low
        /// values mean the shape was ambiguous, not that the ink was faint —
        /// callers should prefer another frame over trusting this.
        let confidence: Double
        /// Kept so the diagnostic overlay and `Reading` keep their shape. The
        /// forest has no crossing count to report, so this is always zero and
        /// the overlay's `⌀` annotation simply stops appearing.
        var crossings: Int = 0
    }

    /// Returns nil when the cell holds no mark to read — blank, so dark the
    /// projection has clearly drifted off the sheet, or holding nothing that
    /// qualifies as a blob once the printed furniture is gone.
    static func recognize(_ patch: CellPatch) -> Result? {
        guard !patch.isBlank, patch.coverage <= CellPatch.Tuning.maxCoverage else { return nil }

        // One blob, chosen before anything is measured. Skipping this step is
        // what made the difference between 43% and 90% on the crops the phone
        // actually uploaded — not because the model was weaker, but because
        // the ink being described was a parenthesis, or the printed heading,
        // or a stroke that leaked in from the row above.
        guard let mark = MarkFeatures.isolate(mask: patch.mask,
                                              width: patch.width,
                                              height: patch.height) else { return nil }

        let features = MarkFeatures.extract(mark: mark,
                                            width: patch.width,
                                            height: patch.height)
        let probability = MarkForest.probabilityOfCross(features)
        let isCross = probability >= 0.5
        return Result(mark: isCross ? .cross : .circle,
                      confidence: isCross ? probability : 1 - probability)
    }
}
