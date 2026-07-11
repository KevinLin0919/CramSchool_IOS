import SwiftUI

// Server addresses for the four backend services. Defaults mirror the
// web frontend's vite.config.ts proxy targets.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(DemoData.modeKey) private var demoMode = true
    @AppStorage(ServerConfig.predictKey) private var predictBase = ServerConfig.defaultPredict
    @AppStorage(ServerConfig.ocrKey) private var ocrBase = ServerConfig.defaultOCR
    @AppStorage(ServerConfig.ocrGoogleKey) private var ocrGoogleBase = ServerConfig.defaultOCRGoogle
    @AppStorage(ServerConfig.templatesKey) private var templatesBase = ServerConfig.defaultTemplates

    @State private var testState: TestState = .idle

    private enum TestState: Equatable {
        case idle
        case testing
        case success(Int)
        case failure(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("示範模式（離線假資料）", isOn: $demoMode)
                } footer: {
                    Text("開啟後不連線伺服器，改用內建的範例考卷與批改結果，可離線展示。正式使用時請關閉，並填入下方伺服器位址。")
                }

                Section {
                    urlField("YOLO 偵測", text: $predictBase)
                } footer: {
                    Text("答案區偵測服務（POST /predict）")
                }

                Section {
                    urlField("手寫 OCR", text: $ocrBase)
                } footer: {
                    Text("學生手寫答案辨識服務（POST /ocr）")
                }

                Section {
                    urlField("Google OCR", text: $ocrGoogleBase)
                } footer: {
                    Text("標準答案辨識服務（POST /ocr_google）")
                }

                Section {
                    urlField("模板伺服器", text: $templatesBase)
                } footer: {
                    Text("考卷模板儲存服務（/api/exam-templates）")
                }

                Section {
                    Button {
                        Task { await testConnection() }
                    } label: {
                        HStack {
                            Text("測試模板伺服器連線")
                            Spacer()
                            switch testState {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView()
                            case .success(let count):
                                Label("\(count) 份模板", systemImage: "checkmark.circle.fill")
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

                    Button("恢復預設值", role: .destructive) {
                        predictBase = ServerConfig.defaultPredict
                        ocrBase = ServerConfig.defaultOCR
                        ocrGoogleBase = ServerConfig.defaultOCRGoogle
                        templatesBase = ServerConfig.defaultTemplates
                        testState = .idle
                    }
                } footer: {
                    Text("手機需與伺服器位於同一網路（或可透過 VPN 連線）才能使用批改功能。")
                }
            }
            .navigationTitle("伺服器設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func urlField(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
                .frame(width: 92, alignment: .leading)
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
        do {
            let templates = try await APIClient.shared.listTemplates()
            testState = .success(templates.count)
        } catch {
            testState = .failure(error.localizedDescription)
        }
    }
}
