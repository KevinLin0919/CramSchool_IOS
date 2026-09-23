import SwiftUI

/// Where the API lives, asked for on the one screen that can be reached
/// without it.
///
/// Deliberately not a copy of Settings. Settings is where a teacher who is
/// already working adjusts things; this is the one field standing between a
/// fresh install and being able to sign in at all, and everything else in
/// that form would be noise at this moment.
///
/// Mostly a way back now, rather than a way in. The app ships pointed at the
/// school's public address, which works in the building and at home alike,
/// so a teacher who has just installed it never needs this sheet.
///
/// It stays because two situations still need it. The school's internet can
/// go down while the machine itself is fine, and a teacher in the room can
/// then still reach it over the WiFi. And a device that saved an older
/// address keeps it — `@AppStorage` only falls back to the default when
/// nothing was ever stored — so it needs somewhere to change it.
///
/// Named by where they work, not by their numbers, and the field stays open
/// for anything else.
struct ServerAddressSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ServerConfig.apiKey) private var apiBase = ServerConfig.defaultAPI

    @State private var typed = ""
    @State private var probe: Probe = .idle

    private enum Probe: Equatable {
        case idle
        case testing
        case reachable
        case unreachable(String)
    }

    /// The addresses this school actually answers on. Named by the situation
    /// rather than by the network, because "10.0.50.16" tells a teacher
    /// nothing and "在補習班" tells them everything.
    ///
    /// The tailnet address that used to be offered as 在外面 is gone from the
    /// list: it only ever worked on a phone running Tailscale, which is what
    /// the public address exists so that teachers never have to do. Anyone
    /// who needs it can still type it.
    static let known: [(label: String, detail: String, url: String)] = [
        ("任何地方", "在補習班或在家都能用（建議）", ServerConfig.defaultAPI),
        ("在補習班", "補習班網路斷線時，連上 WiFi 使用", "http://10.0.50.16:8085"),
    ]

    /// What to call the address currently saved.
    ///
    /// The login screen shows this, so somebody who has walked home can see
    /// that the app is still pointed at the cram school without opening
    /// anything. A raw IP there would say nothing to the person who needs it
    /// most.
    static func label(for url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        if let match = known.first(where: { $0.url == trimmed }) { return match.label }
        return trimmed.isEmpty ? "未設定" : "自訂"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Self.known, id: \.url) { entry in
                        Button {
                            typed = entry.url
                            Task { await test() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.label)
                                        .foregroundStyle(AG.fg1)
                                    Text(entry.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(AG.fg2)
                                }
                                Spacer()
                                if typed == entry.url {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(AG.brand)
                                }
                            }
                        }
                    }
                } header: {
                    Text("選擇位址")
                } footer: {
                    Text("兩個位址連的是同一台伺服器。平常用「任何地方」就好。")
                }

                Section("或自行輸入") {
                    TextField("http://…", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.system(size: 15).monospaced())
                        .onChange(of: typed) { _, _ in probe = .idle }
                }

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("測試連線")
                            Spacer()
                            switch probe {
                            case .idle:
                                EmptyView()
                            case .testing:
                                ProgressView()
                            case .reachable:
                                Label("連得到", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(AG.ok)
                                    .labelStyle(.titleAndIcon)
                            case .unreachable:
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AG.bad)
                            }
                        }
                    }
                    .disabled(trimmed.isEmpty || probe == .testing)
                } footer: {
                    // Say which way it failed. "連不到" covers a wrong address,
                    // the wrong network and a server that is down, and those
                    // are three different next actions.
                    if case .unreachable(let why) = probe {
                        Text(why).foregroundStyle(AG.bad)
                    }
                }
            }
            .navigationTitle("伺服器位址")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("儲存") {
                        apiBase = trimmed
                        dismiss()
                    }
                    .disabled(trimmed.isEmpty)
                }
            }
            .onAppear { if typed.isEmpty { typed = apiBase } }
        }
    }

    private var trimmed: String {
        typed.trimmingCharacters(in: .whitespaces)
    }

    /// Asks the server something it will answer without a credential.
    ///
    /// `/health` needs no token, so a 200 means the address is right and the
    /// machine is up — which is the whole question here. Saving an address
    /// that cannot be reached is how someone ends up at a login screen that
    /// fails for a reason it cannot name.
    @MainActor
    private func test() async {
        let base = trimmed
        guard !base.isEmpty, let url = URL(string: base + "/health") else {
            probe = .unreachable("位址格式不正確")
            return
        }
        probe = .testing

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            probe = code == 200 ? .reachable : .unreachable("伺服器回應 \(code)")
        } catch {
            probe = .unreachable(error.localizedDescription)
        }
    }
}
