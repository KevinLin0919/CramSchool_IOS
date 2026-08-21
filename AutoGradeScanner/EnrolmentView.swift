import SwiftUI
import UIKit

// Enrolling a device with a single-use invite code.
//
// This is the path for a device being set up without a school account —
// during testing, or when Microsoft is unreachable. An admin issues one code
// per device with `cramctl teachers invite`; it is spent the moment it is
// redeemed, so an overheard one is worthless afterwards. Teachers never type
// a password on a phone keyboard.
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
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("輸入邀請碼")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(AG.fg1)
                        Text("向管理員索取，一組只能用一次。")
                            .font(.system(size: 14))
                            .foregroundStyle(AG.fg2)
                    }
                    .padding(.top, 10)

                    VStack(alignment: .leading, spacing: 18) {
                        field("伺服器位址", text: $apiBase,
                              placeholder: "http://主機:埠號", mono: true)

                        field("邀請碼", text: $inviteCode,
                              placeholder: "貼上邀請碼", mono: true,
                              focused: inviteCode.isEmpty)

                        field("裝置名稱", text: $deviceName,
                              placeholder: "例：王老師的 iPad",
                              note: "遺失時要靠它撤銷正確的那一台，建議改成認得出來的名字。")
                    }

                    if case .failed(let message) = status {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 15))
                            Text(message)
                                .font(.system(size: 14))
                        }
                        .foregroundStyle(AG.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(AG.badBg)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    Button {
                        Task { await enrol() }
                    } label: {
                        HStack(spacing: 10) {
                            if status == .working { ProgressView().tint(.white) }
                            Text("註冊這台裝置")
                                .font(.system(size: 17, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(canSubmit ? AG.brand : AG.fg4)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .disabled(!canSubmit)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 40)
                .centeredContent(AG.Width.content)
            }
            .background(AG.bg2)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") { dismiss() }
                        .disabled(status == .working)
                }
            }
            .interactiveDismissDisabled(status == .working)
        }
    }

    @ViewBuilder
    private func field(_ label: String,
                       text: Binding<String>,
                       placeholder: String,
                       mono: Bool = false,
                       focused: Bool = false,
                       note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.3)
                .foregroundStyle(AG.fg2)

            TextField(placeholder, text: text)
                .font(mono ? .system(size: 14).monospaced() : .system(size: 15))
                .foregroundStyle(AG.fg1)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(mono ? .URL : .default)
                .padding(.horizontal, 13)
                .frame(height: 46)
                .background(AG.bg1)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(focused ? AG.brand : AG.border2,
                                lineWidth: focused ? 1.5 : 1))

            if let note {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(AG.fg3)
            }
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
                                    teacherName: response.teacherName,
                                    method: .invite,
                                    expiresAt: response.expiresAt) else {
                status = .failed("無法將授權寫入鑰匙圈，請重試")
                return
            }
            // Enrolling is what turns demo mode off, so clear any explicit
            // override left over from someone tapping 先看示範 — otherwise the
            // app stays on the bundled sheets and the enrolment looks inert.
            UserDefaults.standard.removeObject(forKey: DemoData.modeKey)
            dismiss()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
