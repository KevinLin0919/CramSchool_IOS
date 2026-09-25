import Foundation

/// Which world this build lives in: the teachers' app, or the QAT one.
///
/// Two separate apps on the store side — different bundle IDs, so both can sit
/// on one phone and TestFlight sends each to its own group — built from the
/// same source. CI decides which one it is building by setting `FUDAO_ENV`,
/// which lands in Info.plist. Absent means production: every build that does
/// not ask to be QAT is the teachers' app, including a plain Xcode run.
enum AppEnvironment {
    static let isQAT: Bool =
        (Bundle.main.object(forInfoDictionaryKey: "FudaoEnvironment") as? String) == "qat"

    /// Shown wherever confusing the two would matter.
    static var label: String? { isQAT ? "QAT 測試版" : nil }
}
