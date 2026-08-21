import SwiftUI

// The first screen an unenrolled device shows.
//
// Enrolment used to live inside Settings, which meant a teacher handed an
// iPad had no way to find it — and worse, the app opened straight onto the
// bundled sample templates, which look exactly like real ones. Someone could
// pick "國一數學第三次段考", grade a real paper against it, and get a
// fabricated result. A launch screen is what stops that: the demo sheets are
// now somewhere you choose to go, not somewhere you land.
//
// The primary button says only 登入. What is behind it — a Microsoft tenant —
// is an implementation detail; to the teacher it is the one way in. The two
// smaller entries are for people who are not that teacher: an invite code for
// a device being set up without a school account, and the bundled sheets for
// demonstrating with no server at all.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel

    @State private var status: Status = .idle
    @State private var showingInvite = false

    private enum Status: Equatable {
        case idle
        case signingIn
        case failed(String)
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // Pinned to a fraction of the screen rather than centred in
                // whatever the controls leave over: an error banner appearing
                // below must not shift the brand mark up.
                Image("BrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: min(228, geo.size.width * 0.58))
                    .frame(maxWidth: .infinity)
                    .frame(height: geo.size.height * 0.75, alignment: .center)

                Spacer(minLength: 0)

                VStack(spacing: 14) {
                    if case .failed(let message) = status {
                        errorBanner(message)
                    }
                    primaryButton
                    secondaryEntries
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
                .centeredContent(AG.Width.action + 56)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(AG.bg2)
        .sheet(isPresented: $showingInvite) { EnrolmentView() }
        .animation(.spring(duration: 0.28), value: status)
    }

    // MARK: - Pieces

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 15))
            Text(message)
                .font(.system(size: 14))
        }
        .foregroundStyle(AG.bad)
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(AG.badBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var primaryButton: some View {
        Button {
            Task { await signIn() }
        } label: {
            HStack(spacing: 10) {
                if status == .signingIn {
                    ProgressView().tint(.white)
                }
                Text(buttonTitle)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(AG.brand)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(status == .signingIn ? 0.6 : 1)
        }
        .disabled(status == .signingIn)
    }

    private var buttonTitle: String {
        switch status {
        case .idle: return "登入"
        case .signingIn: return "登入中…"
        case .failed: return "重新登入"
        }
    }

    private var secondaryEntries: some View {
        HStack(spacing: 20) {
            Button("使用邀請碼") { showingInvite = true }
            Rectangle()
                .fill(AG.fg4)
                .frame(width: 1, height: 12)
            Button("先看示範") { model.enterDemo() }
        }
        .font(.system(size: 14))
        .foregroundStyle(AG.fg2)
        .padding(.top, 4)
    }

    // MARK: - Sign in

    @MainActor
    private func signIn() async {
        guard MicrosoftSignIn.isConfigured else {
            // Honest about what is missing rather than failing as if the
            // account were at fault. The tenant's app registration has to
            // exist before this button can do anything at all.
            status = .failed("尚未設定學校帳號登入，請先使用邀請碼")
            return
        }
        status = .signingIn
        do {
            let result = try await MicrosoftSignIn.run()
            guard Credentials.store(token: result.token,
                                    teacherID: result.teacherID,
                                    teacherName: result.teacherName,
                                    method: .microsoft,
                                    expiresAt: result.expiresAt) else {
                status = .failed("無法將授權寫入鑰匙圈，請重試")
                return
            }
            UserDefaults.standard.removeObject(forKey: DemoData.modeKey)
        } catch MicrosoftSignInError.wrongTenant {
            status = .failed("這個帳號不屬於浮島，請再試一次")
        } catch MicrosoftSignInError.cancelled {
            status = .idle
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
