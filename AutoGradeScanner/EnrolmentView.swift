import SwiftUI
import UIKit

// Device enrolment: server address + a single-use invite code, swapped for a
// token that lives in the Keychain.
//
// Teachers never type a password on a phone keyboard. An admin issues one code
// per device with `cramctl teachers invite`, and the code is spent the moment
// it is redeemed — an overheard one is worthless afterwards.
struct EnrolmentView: View {
    @Environment(\.dismiss) private var dismiss

    @AppStorage(ServerConfig.apiKey) private var apiBase = ServerConfig.defaultAPI

    @State private var inviteCode = ""
    @State private var deviceName = Self.defaultDeviceName()
    @State private var status: Status = .idle

    private enum Status: Equatable {
        case idle
        case working
        case failed(String)
    }

    /// iOS 16 stopped handing `UIDevice.current.name` to apps without a
    /// special entitlement: it returns the model, so every iPad in the school
    /// enrols as "iPad". That defeats the field's only job — telling one
    /// teacher's devices apart when one of them needs revoking — and a list of
    /// identical names is how the wrong token gets killed.
    ///
    /// Stamping the enrolment date makes the default distinguishable without
    /// asking anyone to type anything, and the field stays editable for
    /// somebody who wants a real name.
    private static func defaultDeviceName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return "\(UIDevice.current.model)・\(formatter.string(from: Date()))"
    }

    private var canSubmit: Bool {
        status != .working
            && !apiBase.trimmingCharacters(in: .whitespaces).isEmpty
            && inviteCode.trimmingCharacters(in: .whitespaces).count >= 6
            && !deviceName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://主機.tailnet.ts.net", text: $apiBase)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14).monospaced())
                } header: {
                    Text("伺服器位址")
                } footer: {
                    Text("補習班的批改伺服器。裝置需先連上同一個 Tailscale 網路。")
                }

                Section {
                    TextField("貼上邀請碼", text: $inviteCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 14).monospaced())
                    TextField("裝置名稱", text: $deviceName)
                } header: {
                    Text("邀請碼")
                } footer: {
                    Text("向管理員索取，一組只能用一次。\n"
                         + "裝置名稱是這台裝置在管理員清單裡的識別，"
                         + "遺失時要靠它撤銷正確的那一台——建議改成「王老師的 iPad」這種認得出來的名字。")
                }

                if case .failed(let message) = status {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 14))
                            .foregroundStyle(AG.bad)
                    }
                }

                Section {
                    Button {
                        Task { await enrol() }
                    } label: {
                        HStack {
                            Text("註冊這台裝置")
                                .fontWeight(.semibold)
                            Spacer()
                            if status == .working { ProgressView() }
                        }
                    }
                    .disabled(!canSubmit)
                } footer: {
                    Text("尚未註冊時，App 會使用內建的示範考卷離線運作。")
                }
            }
            .navigationTitle("裝置註冊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(status == .working)
                }
            }
            .interactiveDismissDisabled(status == .working)
        }
    }

    @MainActor
    private func enrol() async {
        status = .working
        // Trim before storing: a trailing slash or a stray space pasted along
        // with the address turns every later request into a confusing 404.
        apiBase = apiBase.trimmingCharacters(in: .whitespaces)

        do {
            let response = try await APIClient.shared.redeemInvite(
                code: inviteCode.trimmingCharacters(in: .whitespaces),
                deviceName: deviceName.trimmingCharacters(in: .whitespaces))

            guard Credentials.store(token: response.token,
                                    teacherID: response.teacherID,
                                    teacherName: response.teacherName) else {
                status = .failed("無法將授權寫入鑰匙圈，請重試")
                return
            }
            // Enrolling is what turns demo mode off, so clear any explicit
            // override left over from a demo — otherwise the app stays on the
            // bundled sheets and looks like the enrolment did nothing.
            UserDefaults.standard.removeObject(forKey: DemoData.modeKey)
            dismiss()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
