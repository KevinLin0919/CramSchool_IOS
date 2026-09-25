import SwiftUI

// The results tab's first page: one row per stack, not one pager over every
// paper ever graded. A stack is a sitting — a class, a paper, a day — or, for
// papers scanned before sittings existed, a paper and a day.

struct StackSummary: Identifiable {
    let id: String
    let title: String
    let className: String?
    let day: String
    let papers: [StoredPaper]
    let classID: Int?

    var latest: Date { papers.map(\.scannedAt).max() ?? .distantPast }
    var toReview: Int { papers.filter(\.needsReview).count }
    var unmatched: Int { classID == nil ? 0 : papers.filter { $0.studentID == nil }.count }
}

@MainActor
enum Stacks {
    static func all(_ store: GradingStore, exams: ExamStore) -> [StackSummary] {
        Dictionary(grouping: store.papers, by: \.stackKey)
            .map { key, papers in
                let first = papers.first!
                let exam = exams.exam(first.examUUID)
                return StackSummary(
                    id: key,
                    title: exam?.templateTitle ?? first.templateTitle,
                    className: exam.map { $0.sitting > 1 ? "\($0.className)（第 \($0.sitting) 次）"
                                                        : $0.className },
                    day: exam?.date ?? ExamStore.day(first.scannedAt),
                    papers: papers.sorted { $0.scannedAt < $1.scannedAt },
                    classID: exam?.classID ?? first.classID)
            }
            .sorted { $0.latest > $1.latest }
    }
}

struct StackListView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var papers = GradingStore.shared
    @StateObject private var exams = ExamStore.shared

    var body: some View {
        let stacks = Stacks.all(papers, exams: exams)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("批改結果")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(AG.fg1)
                    .padding(.top, 8)
                Text("一疊是同一個班、同一天考的同一份考卷")
                    .font(.system(size: 14))
                    .foregroundStyle(AG.fg2)
                    .padding(.bottom, 6)
                ForEach(stacks) { stack in
                    Button { model.focusedStack = stack.id } label: { row(stack) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, AG.padding(above: AG.bottomChromeClearance))
            .centeredContent(AG.Width.content)
        }
        .background(AG.bg2)
    }

    private func row(_ stack: StackSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(stack.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AG.fg1)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(stack.className ?? "未指定班級")
                    Text("・").foregroundStyle(AG.fg4)
                    Text(stack.day)
                }
                .font(.system(size: 13))
                .foregroundStyle(AG.fg2)
                HStack(spacing: 8) {
                    chip("\(stack.papers.count) 份", AG.fg2, AG.bg2)
                    if stack.toReview > 0 { chip("\(stack.toReview) 份待確認", AG.warn, AG.warnBg) }
                    if stack.unmatched > 0 { chip("\(stack.unmatched) 份未配對", AG.brand, AG.brandSoft) }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AG.fg3)
        }
        .padding(14)
        .background(AG.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(AG.border2, lineWidth: 1))
    }

    private func chip(_ text: String, _ fg: Color, _ bg: Color) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(bg)
            .clipShape(Capsule())
    }
}

// MARK: - Whose paper is this

/// Matching papers to students, after the stack is scanned rather than during.
///
/// Scanning stays one paper after another with nothing asked; this is where
/// names are settled, all at once, by picking from the class roster. A name
/// already given to a paper is greyed rather than hidden — tapping it moves it
/// here, because the likeliest mistake is a swap.
struct MatchStudentsView: View {
    let stackKey: String

    @Environment(\.dismiss) private var dismiss
    @StateObject private var papers = GradingStore.shared
    @StateObject private var roster = RosterStore.shared
    @State private var selected: UUID?

    private var stack: [StoredPaper] { papers.papers(inStack: stackKey) }
    private var classID: Int? { stack.first?.classID }
    private var students: [APIClient.StudentDTO] { roster.schoolClass(classID)?.students ?? [] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    ForEach(Array(stack.enumerated()), id: \.element.id) { position, paper in
                        paperRow(position, paper)
                            .listRowBackground(selected == paper.id ? AG.brandSoft : AG.bg1)
                            .contentShape(Rectangle())
                            .onTapGesture { selected = paper.id }
                    }
                }
                .listStyle(.plain)
                rosterPanel
            }
            .navigationTitle("配對學生")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .onAppear { selected = selected ?? stack.first(where: { $0.studentID == nil })?.id }
            .task { await roster.refresh() }
        }
    }

    private func paperRow(_ position: Int, _ paper: StoredPaper) -> some View {
        HStack(spacing: 10) {
            Text("第 \(position + 1) 份")
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(AG.fg1)
            Text("\(paper.correctCount)/\(paper.total)")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(AG.fg2)
            Spacer()
            if let name = roster.studentName(paper.studentID) {
                Text(name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(AG.brand)
            } else {
                Text("未配對")
                    .font(.system(size: 14))
                    .foregroundStyle(AG.fg3)
            }
        }
        .padding(.vertical, 6)
    }

    private var rosterPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if students.isEmpty {
                Text("這個班級還沒有學生。到「設定 → 班級與學生」新增名冊。")
                    .font(.system(size: 13))
                    .foregroundStyle(AG.fg2)
                    .padding(16)
            } else {
                Text(selected.flatMap { id in stack.firstIndex { $0.id == id } }
                        .map { "第 \($0 + 1) 份是誰的？" } ?? "先點一份考卷")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AG.fg2)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(students) { student in studentButton(student) }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .frame(maxHeight: 220)
            }
        }
        .background(AG.bg1)
    }

    private func studentButton(_ student: APIClient.StudentDTO) -> some View {
        let owner = stack.first { $0.studentID == student.id }
        let isCurrent = owner != nil && owner?.id == selected
        let usedElsewhere = owner != nil && !isCurrent
        return Button {
            guard let target = selected else { return }
            // Taking a name from another paper frees it there: a swap is the
            // mistake this screen exists to fix.
            if let owner, owner.id != target { papers.assign(owner.id, student: nil) }
            papers.assign(target, student: isCurrent ? nil : student.id)
            if !isCurrent {
                selected = stack.first(where: { $0.studentID == nil && $0.id != target })?.id
                    ?? target
            }
        } label: {
            Text(student.name)
                .font(.system(size: 15, weight: isCurrent ? .bold : .medium))
                .foregroundStyle(isCurrent ? Color.white : (usedElsewhere ? AG.fg4 : AG.fg1))
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(isCurrent ? AG.brand : (usedElsewhere ? AG.bg2 : AG.bg1))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(isCurrent ? AG.brand : AG.borderStrong, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(selected == nil)
    }
}

// MARK: - Which class is this stack

/// Asked once, before the camera opens: the class decides the roster the
/// names come from later. Skippable — a paper with no class is still graded.
struct ClassPickerSheet: View {
    let onPick: (APIClient.ClassDTO?) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var roster = RosterStore.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(roster.classes) { cls in
                        Button {
                            onPick(cls)
                            dismiss()
                        } label: {
                            HStack {
                                Text(cls.name).foregroundStyle(AG.fg1)
                                Spacer()
                                Text("\(cls.students.count) 人").foregroundStyle(AG.fg3)
                            }
                        }
                    }
                } footer: {
                    Text("掃完後可以在結果頁把每份考卷配對到學生。")
                }
                Section {
                    Button("不指定班級") {
                        onPick(nil)
                        dismiss()
                    }
                    .foregroundStyle(AG.fg2)
                }
            }
            .navigationTitle("這一疊是哪一班？")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
