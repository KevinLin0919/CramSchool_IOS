import SwiftUI

// Screen 1 — template picker grouped 年級 → 科目, with search,
// collapsible grade sections and the floating 開始掃描 button.
struct TemplatesView: View {
    @EnvironmentObject private var model: AppModel

    @State private var query = ""
    @State private var openGrades: Set<String> = []
    @State private var showSettings = false
    @State private var showNewTemplate = false

    @State private var renameTarget: ExamTemplate?
    @State private var renameText = ""
    @State private var deleteTarget: ExamTemplate?
    @State private var previewTarget: ExamTemplate?

    private var searching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var filtered: [ExamTemplate] {
        model.templates.filter {
            $0.examName.contains(query) || $0.subject.contains(query) || $0.grade.contains(query)
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                listArea
            }
            startButton
        }
        .background(AG.bg2)
        .task {
            if model.templates.isEmpty {
                await model.loadTemplates()
                openSelectedGrade()
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNewTemplate) {
            NewTemplateView {
                Task { await model.loadTemplates() }
            }
        }
        .sheet(item: $previewTarget) { template in
            TemplatePreviewSheet(template: template)
        }
        .alert("重新命名考卷", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("考卷名稱", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("確認") {
                if let target = renameTarget {
                    Task { await model.renameTemplate(target, to: renameText) }
                }
                renameTarget = nil
            }
        }
        .confirmationDialog(
            "確定要刪除「\(deleteTarget?.examName ?? "")」嗎？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("確認刪除", role: .destructive) {
                if let target = deleteTarget {
                    Task { await model.deleteTemplate(target) }
                }
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        }
    }

    private func openSelectedGrade() {
        if let selected = model.selectedTemplate {
            openGrades.insert(selected.grade)
        } else if let first = model.templates.first {
            openGrades.insert(first.grade)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("AUTOGRADE")
                    .font(.system(size: 13, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(AG.fg2)
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(AG.fg2)
                }
                .padding(.trailing, 14)
                Button { showNewTemplate = true } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                        Text("新增")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .foregroundStyle(AG.brand)
                }
            }
            .frame(height: 44)

            Text("考卷模板")
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(AG.fg1)
                .padding(.top, 2)

            Text("依年級選擇要批改的考卷，再開啟相機掃描")
                .font(.system(size: 14))
                .foregroundStyle(AG.fg2)
                .padding(.top, 4)

            searchField
                .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .centeredContent()
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AG.fg2)
            TextField("搜尋考卷、科目或年級", text: $query)
                .font(.system(size: 17))
                .foregroundStyle(AG.fg1)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(AG.fg3)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color(hex: 0x767680, alpha: 0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - List

    private var listArea: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if model.isLoadingTemplates && model.templates.isEmpty {
                    loadingState
                } else if let error = model.templatesError, model.templates.isEmpty {
                    errorState(error)
                } else if searching {
                    searchResults
                } else {
                    gradeSections
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 220)
            .centeredContent()
        }
        .refreshable { await model.loadTemplates() }
    }

    private var loadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("載入考卷模板中…")
                .font(.system(size: 15))
                .foregroundStyle(AG.fg2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 30))
                .foregroundStyle(AG.fg3)
            Text("無法連線到模板伺服器")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AG.fg1)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(AG.fg2)
                .multilineTextAlignment(.center)
            Button("重試") {
                Task { await model.loadTemplates() }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var searchResults: some View {
        Group {
            sectionCaption("搜尋結果 · \(filtered.count) 份考卷")
            VStack(spacing: 0) {
                if filtered.isEmpty {
                    Text("找不到符合的考卷")
                        .font(.system(size: 15))
                        .foregroundStyle(AG.fg3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, template in
                        templateRow(template, showSubject: true,
                                    isLast: index == filtered.count - 1)
                    }
                }
            }
            .background(AG.bg1)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16).stroke(AG.border2, lineWidth: 1)
            )
        }
    }

    private var gradeSections: some View {
        Group {
            sectionCaption("依年級瀏覽 · \(model.templates.count) 份考卷")
            ForEach(ExamTemplate.gradeOrder, id: \.self) { grade in
                let items = model.templates.filter { $0.grade == grade }
                if !items.isEmpty {
                    gradeSection(grade: grade, items: items)
                }
            }
        }
    }

    private func sectionCaption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium))
            .kerning(0.3)
            .foregroundStyle(AG.fg2)
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
    }

    // MARK: - Grade section

    private func gradeSection(grade: String, items: [ExamTemplate]) -> some View {
        let open = openGrades.contains(grade)
        let subjects = orderedSubjects(items)
        let containsSelected = items.contains { $0.id == model.selectedTemplateID }

        return VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.28)) {
                    if open { openGrades.remove(grade) } else { openGrades.insert(grade) }
                }
            } label: {
                HStack(spacing: 10) {
                    Text(grade)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(open ? .white : AG.fg2)
                        .frame(width: 34, height: 34)
                        .background(open ? AG.brand : AG.bg2)
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(grade)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AG.fg1)
                        Text("\(subjects.joined(separator: "・"))・\(items.count) 份考卷")
                            .font(.system(size: 12))
                            .foregroundStyle(AG.fg2)
                    }
                    Spacer()
                    if !open && containsSelected {
                        Circle().fill(AG.brand).frame(width: 8, height: 8)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AG.fg3)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if open {
                Divider().overlay(AG.border1)
                ForEach(subjects, id: \.self) { subject in
                    subjectGroup(subject: subject,
                                 items: items.filter { $0.subject == subject })
                }
                Spacer().frame(height: 4)
            }
        }
        .background(AG.bg1)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16).stroke(AG.border2, lineWidth: 1)
        )
        .shadow(color: Color(hex: 0x0F1720, alpha: 0.04), radius: 1, y: 1)
    }

    private func orderedSubjects(_ items: [ExamTemplate]) -> [String] {
        var seen: [String] = []
        for item in items where !seen.contains(item.subject) {
            seen.append(item.subject)
        }
        return seen
    }

    private func subjectGroup(subject: String, items: [ExamTemplate]) -> some View {
        let tint = AG.subjectTint(subject)
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(subject)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
                Text("\(items.count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AG.fg3)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ForEach(Array(items.enumerated()), id: \.element.id) { index, template in
                templateRow(template, showSubject: false,
                            isLast: index == items.count - 1)
            }
        }
    }

    // MARK: - Template row

    // The row selects on tap; the leading thumbnail and the 眼睛 button both let
    // the user actually see what the template is. Selection is an .onTapGesture
    // (not an enclosing Button) so the preview button can own its own taps.
    private func templateRow(_ template: ExamTemplate, showSubject: Bool, isLast: Bool) -> some View {
        let selected = model.selectedTemplateID == template.id
        return HStack(spacing: 12) {
            TemplateThumbnail(template: template)

            VStack(alignment: .leading, spacing: 3) {
                Text(showSubject ? template.fullTitle : template.displayName)
                    .font(.system(size: 16, weight: selected ? .semibold : .medium))
                    .foregroundStyle(AG.fg1)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text("\(template.annotationCount) 題")
                    Text("・").foregroundStyle(AG.fg4)
                    Text(template.dateText)
                }
                .font(.system(size: 13))
                .foregroundStyle(AG.fg2)
            }

            Spacer()

            Button {
                previewTarget = template
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AG.fg3)
                    .frame(width: 34, height: 34)
                    .background(AG.bg2)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            selectCircle(selected: selected)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(minHeight: 56)
        .background(selected ? AG.brand.opacity(0.06) : Color.clear)
        .overlay(alignment: .bottom) {
            if !isLast {
                AG.border1.frame(height: 0.5).padding(.leading, 14)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedTemplateID = template.id }
        .contextMenu {
            Button {
                renameTarget = template
                renameText = template.examName
            } label: {
                Label("改名", systemImage: "pencil")
            }
            Button {
                previewTarget = template
            } label: {
                Label("預覽", systemImage: "eye")
            }
            Button(role: .destructive) {
                deleteTarget = template
            } label: {
                Label("刪除", systemImage: "trash")
            }
        }
    }

    private func selectCircle(selected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(selected ? AG.brand : Color.clear)
                .frame(width: 24, height: 24)
            if selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .stroke(AG.borderStrong, lineWidth: 1.5)
                    .frame(width: 24, height: 24)
            }
        }
    }

    // MARK: - Start button

    private var startButton: some View {
        VStack(spacing: 8) {
            Button {
                if model.selectedTemplate != nil {
                    model.screen = .scan
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 18, weight: .semibold))
                    Text(model.selectedTemplate != nil ? "開始掃描" : "請先選擇考卷")
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(model.selectedTemplate != nil ? AG.brand : Color(hex: 0xC8C9CB))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: model.selectedTemplate != nil ? AG.brand.opacity(0.25) : .clear,
                        radius: 11, y: 8)
            }
            .disabled(model.selectedTemplate == nil)

            if let selected = model.selectedTemplate {
                Text("已選擇：\(selected.fullTitle)")
                    .font(.system(size: 12))
                    .foregroundStyle(AG.fg2)
            }
        }
        .centeredContent(AG.Width.action)
        .padding(.horizontal, 16)
        .padding(.bottom, 76)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [AG.bg2.opacity(0), AG.bg2.opacity(0.98), AG.bg2],
                           startPoint: .top, endPoint: .bottom)
            .allowsHitTesting(false)
        )
    }
}

// MARK: - Template image preview sheet

private struct TemplatePreviewSheet: View {
    let template: ExamTemplate
    @Environment(\.dismiss) private var dismiss

    @State private var answers: [String] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            ZStack {
                AG.bg2.ignoresSafeArea()
                content
            }
            .navigationTitle(template.fullTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let image = DemoData.bundledImage(for: template.id) {
            // Bundled demo template: show the real master sheet.
            ScrollView {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(16)
            }
        } else if DemoData.isEnabled {
            // Offline demo: no image, so render the answer key as a card.
            if loaded {
                AnswerSheetSchematic(title: template.fullTitle,
                                     subject: template.subject,
                                     answers: answers)
            } else {
                ProgressView().tint(AG.brand)
            }
        } else {
            // Real backend: prefer the stored sheet image, fall back to the
            // schematic if it can't be fetched.
            AsyncImage(url: ServerConfig.templateImageURL(id: template.id)) { phase in
                switch phase {
                case .success(let image):
                    ScrollView {
                        image.resizable().scaledToFit().padding(16)
                    }
                case .failure:
                    AnswerSheetSchematic(title: template.fullTitle,
                                         subject: template.subject,
                                         answers: answers)
                default:
                    ProgressView().tint(AG.brand)
                }
            }
        }
    }

    private func load() async {
        guard !loaded else { return }
        let detail = try? await APIClient.shared.templateDetail(id: template.id)
        answers = detail?.expectedAnswers ?? []
        loaded = true
    }
}
