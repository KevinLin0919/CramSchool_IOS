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
    @State private var showingServer = false
    /// Observed, not read. The label below names the address, and without
    /// this the login screen would still be showing the old one after the
    /// sheet saved a new one — SwiftUI has no reason to redraw for a value
    /// it was never watching.
    @AppStorage(ServerConfig.apiKey) private var apiBase = ServerConfig.defaultAPI

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
                    serverEntry
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 32)
                .centeredContent(AG.Width.action + 56)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(AG.bg2)
        .sheet(isPresented: $showingInvite) { EnrolmentView() }
        .sheet(isPresented: $showingServer) { ServerAddressSheet() }
        .animation(.spring(duration: 0.28), value: status)
        .task {
            // A device whose authorisation died lands here with no idea why.
            // Expired, revoked by an admin, account deactivated — the first
            // they fix by signing in again, the other two they cannot fix at
            // all, and arriving at a bare login screen tells them none of it.
            //
            // Moved into local state and cleared at the source so it shows
            // once. The next thing to write here is whatever they do next.
            if let reason = model.signedOutReason, status == .idle {
                status = .failed(reason)
                model.signedOutReason = nil
            }
        }
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

    /// The way out of the one dead end this screen could produce.
    ///
    /// "尚未設定伺服器位址，請至設定填寫" was true and useless: Settings opens
    /// from the template list, the template list is behind this screen, and
    /// this screen cannot be passed until the address is set. A fresh install
    /// had nowhere to go — which nobody noticed while every test device
    /// already carried an address from an earlier install.
    ///
    /// Always visible. There is now one address that works everywhere, which
    /// is the day this was going to become conditional again — and on
    /// reflection it should not.
    ///
    /// What it shows is which server the app is pointed at, in words. That is
    /// the first thing worth knowing when sign-in fails, and hiding it until
    /// after a failure is the "fail first, fix second" order it was made
    /// visible to avoid. It also costs one line of small grey text, and a
    /// device carrying an address saved before the public one existed needs
    /// a way to see that it is.
    private var serverEntry: some View {
        Button {
            showingServer = true
        } label: {
            Label(serverEntryTitle, systemImage: "network")
                .font(.system(size: 14))
                .foregroundStyle(AG.fg2)
        }
        .padding(.top, 2)
    }

    /// Names the current choice rather than the setting, so somebody who is
    /// in the wrong place can see that they are without opening anything.
    private var serverEntryTitle: String {
        guard !apiBase.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "設定伺服器位址"
        }
        return "伺服器：\(ServerAddressSheet.label(for: apiBase))"
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
