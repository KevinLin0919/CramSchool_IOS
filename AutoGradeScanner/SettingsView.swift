import SwiftUI

// Server + device settings.
//
// The four addresses this used to ask for have collapsed to one that matters:
// grading runs on device, so the only server the app needs to reach in normal
// use is the API. The two inference addresses remain because building a
// template still calls YOLO and Google OCR, and they are tucked away under a
// disclosure rather than presented as things a teacher must understand.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @AppStorage(DemoData.modeKey) private var demoModeOverride = false
    @AppStorage(CameraPreviewView.showsReadingKey) private var showsReading = false
    @AppStorage(ServerConfig.apiKey) private var apiBase = ServerConfig.defaultAPI
    @AppStorage(ServerConfig.predictKey) private var predictBase = ServerConfig.defaultPredict
    @AppStorage(ServerConfig.ocrGoogleKey) private var ocrGoogleBase = ServerConfig.defaultOCRGoogle

    @State private var testState: TestState = .idle
    @State private var showingEnrolment = false
    @State private var showingSignOutConfirm = false
    @State private var isSigningOut = false
    /// Set when the server never confirmed the revocation. The credential is
    /// gone from this device either way; what is left is a token nobody can
    /// present but that the server still honours.
    @State private var revokeWarning: String?
    @State private var enrolled = Credentials.isEnrolled
    @State private var method = Credentials.enrolmentMethod
    @StateObject private var papers = GradingStore.shared

    private enum TestState: Equatable {
        case idle
        case testing
        case success(Int)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                syncSection
                diagnosticsSection
                inferenceSection
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showingEnrolment) {
                EnrolmentView()
            }
            .onReceive(NotificationCenter.default.publisher(for: Credentials.didChange)) { _ in
                enrolled = Credentials.isEnrolled
                method = Credentials.enrolmentMethod
                testState = .idle
            }
            .confirmationDialog(signOutTitle,
                                isPresented: $showingSignOutConfirm,
                                titleVisibility: .visible) {
                Button(signOutConfirmLabel, role: .destructive) {
                    Task { await signOut() }
                }
            } message: {
                Text(signOutMessage)
            }
            .alert("授權尚未在伺服器撤銷",
                   isPresented: Binding(get: { revokeWarning != nil },
                                        set: { if !$0 { revokeWarning = nil } })) {
                Button("我知道了") {
                    revokeWarning = nil
                    dismiss()
                }
            } message: {
                Text(revokeWarning ?? "")
            }
        }
    }

    // MARK: - Sections

    // Every way in has a way out.
    //
    // There used to be exactly one, and it belonged to the enrolled state:
    // choosing 先看示範 on the login screen set a flag no button removed, so the
    // login screen could never come back. Signing in as the wrong account had
    // no remedy either — the only exit was labelled 取消註冊, which reads like
    // it destroys something, because for an invite-code device it does.
    //
    // So the row is always present and its wording follows the one thing that
    // actually differs between the three states: what it costs to come back.
    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if enrolled {
                LabeledContent("目前帳號", value: Credentials.teacherName ?? "已註冊")
                LabeledContent("登入方式",
                               value: method == .microsoft ? "學校帳號" : "邀請碼")
                if let expiry = expiryText {
                    LabeledContent("授權到期", value: expiry)
                }
                // Red only for the invite path. Signing a Microsoft account
                // out destroys nothing that cannot be fetched again, and
                // painting it as destructive is how you teach people not to
                // press the button that fixes their problem.
                Button(signOutLabel,
                       role: method == .microsoft ? nil : ButtonRole.destructive) {
                    showingSignOutConfirm = true
                }
                .disabled(isSigningOut)
                .overlay(alignment: .trailing) {
                    if isSigningOut { ProgressView() }
                }
            } else if model.isExplicitDemo {
                LabeledContent("目前模式", value: "示範考卷")
                Button {
                    showingEnrolment = true
                } label: {
                    Label("註冊這台裝置", systemImage: "person.badge.key")
                }
                Button("結束示範，回到登入頁") {
                    model.exitDemo()
                    dismiss()
                }
            } else {
                Button {
                    showingEnrolment = true
                } label: {
                    Label("註冊這台裝置", systemImage: "person.badge.key")
                }
            }
        } header: {
            Text("裝置")
        } footer: {
            Text(deviceFooter)
        }
    }

    /// Only shown when there is one. An invite-code authorisation has no
    /// expiry at all, and printing "永久" beside it would read as reassurance
    /// rather than as the thing that makes revoking it matter.
    private var expiryText: String? {
        guard let raw = Credentials.expiresAt else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsed = iso.date(from: raw) ?? {
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: raw)
        }()
        guard let parsed else { return String(raw.prefix(10)) }
        let display = DateFormatter()
        display.dateFormat = "yyyy/MM/dd"
        return display.string(from: parsed)
    }

    /// Revoke first, clear second — the token is what authorises its own
    /// revocation, so clearing it first would throw away the only means of
    /// ever killing it server-side.
    ///
    /// The local sign-out happens either way. Refusing to sign out until the
    /// network agrees would strand whoever is handing over a shared iPad in a
    /// room with no Wi-Fi, and that is a worse failure than a token that
    /// outlives its device: the second one an admin can still fix.
    @MainActor
    private func signOut() async {
        // Read before signing out. `Credentials.clear()` posts didChange, which
        // this view answers by re-reading `method` — and a cleared credential
        // reads back as `.invite`, so a Microsoft teacher would be told their
        // invite code needs revoking by an admin.
        let wasMicrosoft = method == .microsoft

        isSigningOut = true
        var failed = false
        do {
            try await APIClient.shared.revokeThisDevice()
        } catch {
            failed = true
        }
        model.signOut()
        isSigningOut = false

        guard failed else { return dismiss() }
        revokeWarning = wasMicrosoft
            ? "已在這台裝置登出，但伺服器端的授權還沒撤銷。請聯絡管理員撤銷，或等待授權到期。"
            : "已在這台裝置登出，但伺服器端的授權還沒撤銷。邀請碼的授權不會自動到期，請聯絡管理員撤銷。"
    }

    private var signOutLabel: String {
        method == .microsoft ? "登出" : "登出並取消註冊"
    }

    private var deviceFooter: String {
        if enrolled {
            return method == .microsoft
                ? "登出後已下載的考卷會一併移除，重新登入即可再同步。"
                : "這台裝置是用邀請碼註冊的。登出後需要向管理員索取新的邀請碼才能再次使用。"
        }
        if model.isExplicitDemo {
            return "示範考卷完全離線，不會連線伺服器。結束示範可改用學校帳號或邀請碼登入，已批改的紀錄會保留。"
        }
        return "尚未註冊。App 目前使用內建的示範考卷離線運作，不會連線伺服器。"
    }

    private var signOutTitle: String {
        method == .microsoft ? "要登出嗎？" : "要登出並取消註冊嗎？"
    }

    private var signOutConfirmLabel: String {
        method == .microsoft ? "登出" : "登出並取消註冊"
    }

    /// Names the unrecoverable part first, and the graded papers that stay
    /// behind second — on a shared device those are the previous teacher's,
    /// and they have not been uploaded anywhere yet.
    private var signOutMessage: String {
        var lines = [method == .microsoft
                     ? "已下載的考卷與標準答案會一併刪除，重新登入後可再次同步。"
                     : "已下載的考卷與標準答案會一併刪除，且需要新的邀請碼才能再次註冊。"]
        let pending = papers.papers.count
        if pending > 0 {
            lines.append("已批改的 \(pending) 份仍會留在這台裝置上。")
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var syncSection: some View {
        if enrolled {
            Section {
                LabeledContent("伺服器") {
                    Text(apiBase.isEmpty ? "未設定" : apiBase)
                        .font(.system(size: 13).monospaced())
                        .foregroundStyle(AG.fg2)
                        .lineLimit(1)
                        .truncationMode(.head)
                }

                Button {
                    Task { await testConnection() }
                } label: {
                    HStack {
                        Text("同步考卷")
                        Spacer()
                        switch testState {
                        case .idle:
                            EmptyView()
                        case .testing:
                            ProgressView()
                        case .success(let count):
                            Label("\(count) 份", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(AG.ok)
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AG.bad)
                        }
                    }
                }
                .disabled(testState == .testing)

                if case .failure(let message) = testState {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(AG.bad)
                }
            } header: {
                Text("考卷同步")
            } footer: {
                Text("同步後即可離線批改：母卷與標準答案都存在裝置上。")
            }
        }
    }

    @ViewBuilder
    private var diagnosticsSection: some View {
        Section {
            Toggle("顯示辨識結果（診斷用）", isOn: $showsReading)
            if enrolled {
                Toggle("強制示範模式", isOn: $demoModeOverride)
            }
        } header: {
            Text("診斷")
        } footer: {
            Text("開啟辨識結果後，紅框與黃框旁會一併顯示裝置讀到的答案（辨識→標準），"
                 + "並顯示答案格的實際像素數——那個數字決定答案讀不讀得出來，"
                 + "低於 96 就該再靠近一點。展示給他人看時建議關閉。")
        }
    }

    @ViewBuilder
    private var inferenceSection: some View {
        Section {
            DisclosureGroup("建立模板用的服務") {
                urlField("YOLO 偵測", text: $predictBase)
                urlField("標準答案 OCR", text: $ocrGoogleBase)
            }
        } footer: {
            Text("只有「新增考卷」時才會用到。批改本身完全在裝置上執行，不需要這兩個服務。")
        }
    }

    private func urlField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 108, alignment: .leading)
            TextField("http://主機:埠號", text: text)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.system(size: 14).monospaced())
        }
    }

    @MainActor
    private func testConnection() async {
        testState = .testing
        await TemplateStore.shared.refresh()
        if let error = TemplateStore.shared.syncError {
            testState = .failure(error)
        } else {
            testState = .success(TemplateStore.shared.templates.count)
            await model.loadTemplates()
        }
    }
}
