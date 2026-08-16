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
    @State private var enrolled = Credentials.isEnrolled

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
                developerSection
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
                testState = .idle
            }
            .confirmationDialog("要取消註冊嗎？",
                                isPresented: $showingSignOutConfirm,
                                titleVisibility: .visible) {
                Button("取消註冊並清除已下載的考卷", role: .destructive) {
                    model.signOut()
                    enrolled = false
                }
            } message: {
                Text("已下載的考卷與標準答案會一併刪除。")
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var deviceSection: some View {
        Section {
            if enrolled {
                LabeledContent("目前帳號", value: Credentials.teacherName ?? "已註冊")
                Button("取消註冊", role: .destructive) { showingSignOutConfirm = true }
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
            Text(enrolled
                 ? "授權存放於裝置的鑰匙圈，可由管理員隨時撤銷。"
                 : "尚未註冊。App 目前使用內建的示範考卷離線運作，不會連線伺服器。")
        }
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

    @ViewBuilder
    private var developerSection: some View {
        Section {
            NavigationLink("XFeat 對位測試") { XFeatDebugView() }
        } header: {
            Text("開發者工具")
        } footer: {
            Text("驗證裝置端 XFeat 特徵對位：把模板題框投影到考卷照片、產生半透明疊圖。")
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
