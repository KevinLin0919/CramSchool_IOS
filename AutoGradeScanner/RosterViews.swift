import SwiftUI

// Class lists, kept deliberately plain: a name per class, a name per student.
// This is the list the matching screen picks from.

struct ClassListView: View {
    @StateObject private var roster = RosterStore.shared
    @State private var newName = ""
    @State private var adding = false

    var body: some View {
        List {
            Section {
                ForEach(roster.classes) { cls in
                    NavigationLink {
                        ClassDetailView(classID: cls.id)
                    } label: {
                        HStack {
                            Text(cls.name)
                            if cls.is_simulated {
                                Text("模擬").font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(AG.warn)
                            }
                            Spacer()
                            Text("\(cls.students.count) 人").foregroundStyle(AG.fg3)
                        }
                    }
                }
                Button {
                    adding = true
                } label: {
                    Label("新增班級", systemImage: "plus")
                }
            } footer: {
                if let error = roster.lastError {
                    Text(error).foregroundStyle(AG.bad)
                } else {
                    Text("名冊只需要姓名。掃完一疊後，從名冊點選每份考卷是誰的。")
                }
            }
        }
        .navigationTitle("班級與學生")
        .task { await roster.refresh() }
        .refreshable { await roster.refresh() }
        .alert("新增班級", isPresented: $adding) {
            TextField("例如：四年甲班", text: $newName)
            Button("取消", role: .cancel) { newName = "" }
            Button("新增") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                newName = ""
                guard !name.isEmpty else { return }
                Task { await roster.createClass(name) }
            }
        }
    }
}

struct ClassDetailView: View {
    let classID: Int
    @StateObject private var roster = RosterStore.shared
    @State private var newStudent = ""
    @State private var renaming: APIClient.StudentDTO?
    @State private var renameText = ""

    private var cls: APIClient.ClassDTO? { roster.schoolClass(classID) }

    var body: some View {
        List {
            Section {
                ForEach(cls?.students ?? []) { student in
                    Text(student.name)
                        .swipeActions {
                            Button("移除", role: .destructive) {
                                Task { await roster.removeStudent(student.id, from: classID) }
                            }
                            Button("改名") {
                                renaming = student
                                renameText = student.name
                            }
                        }
                }
                HStack {
                    TextField("學生姓名", text: $newStudent)
                        .submitLabel(.done)
                        .onSubmit(add)
                    Button("加入", action: add)
                        .disabled(newStudent.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                Text("左滑可以改名或移除。移除只會把學生移出名冊，已批改的紀錄會保留。")
            }
        }
        .navigationTitle(cls?.name ?? "班級")
        .alert("修改姓名", isPresented: Binding(get: { renaming != nil },
                                               set: { if !$0 { renaming = nil } })) {
            TextField("姓名", text: $renameText)
            Button("取消", role: .cancel) { renaming = nil }
            Button("儲存") {
                if let student = renaming {
                    let name = renameText.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        Task { await roster.renameStudent(student.id, in: classID, to: name) }
                    }
                }
                renaming = nil
            }
        }
    }

    private func add() {
        let name = newStudent.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        newStudent = ""
        Task { await roster.addStudent(name, to: classID) }
    }
}

/// Six digits for signing a browser in as this teacher. Three minutes, once.
struct WebLoginCodeView: View {
    @State private var code: APIClient.WebCodeDTO?
    @State private var error: String?
    @State private var loading = false

    var body: some View {
        VStack(spacing: 18) {
            Text("在電腦上看報告")
                .font(.system(size: 20, weight: .bold))
            if let code {
                Text(spaced(code.code))
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundStyle(AG.brand)
                    .textSelection(.enabled)
                Text("在網頁的登入畫面輸入這組數字。3 分鐘內有效，只能用一次。")
                    .font(.system(size: 14))
                    .foregroundStyle(AG.fg2)
                    .multilineTextAlignment(.center)
            } else if let error {
                Text(error).foregroundStyle(AG.bad).multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
            Button(code == nil ? "產生登入碼" : "重新產生") { Task { await load() } }
                .buttonStyle(.bordered)
                .disabled(loading)
        }
        .padding(28)
        .task { await load() }
        .presentationDetents([.medium])
    }

    private func spaced(_ text: String) -> String {
        text.count == 6 ? "\(text.prefix(3)) \(text.suffix(3))" : text
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            code = try await APIClient.shared.webLoginCode()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}
