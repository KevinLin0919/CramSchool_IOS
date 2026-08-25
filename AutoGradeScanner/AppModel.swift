import Combine
import SwiftUI

enum AppScreen {
    case templates
    case scan
    case results
}

@MainActor
final class AppModel: ObservableObject {
    @Published var screen: AppScreen = .templates

    // Templates
    @Published var templates: [ExamTemplate] = []
    @Published var isLoadingTemplates = false
    @Published var templatesError: String?
    @Published var selectedTemplateID: Int?

    /// Why the credential stopped working, in the server's own words, waiting
    /// for the login screen to say it. Nil when the person simply has not
    /// signed in yet — that screen needs no explanation.
    @Published var signedOutReason: String?

    /// The session just finished, for the scanner's own one-shot flow.
    /// The stack the results page shows lives in `GradingStore` — it survives
    /// the app being killed, which this does not.
    @Published var lastResult: GradingResult?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // `DispatchQueue.main` rather than `RunLoop.main`: the RunLoop
        // scheduler only delivers in the default mode, so anything posted
        // while a sheet is animating or a list is being dragged waits for the
        // interaction to finish. Both of these fire at exactly those moments —
        // enrolment dismisses a sheet — and neither wants to be held.
        NotificationCenter.default.publisher(for: APIClient.unauthorizedNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                // Clearing the credential is what routes back to the login
                // screen: `needsLogin` reads the Keychain, so there is no
                // second flag to keep in step with it.
                //
                // Clear FIRST. `Credentials.clear()` posts didChange, and the
                // handler below drops this message whenever a credential
                // exists — setting the reason before that runs would have it
                // erased by its own cause.
                Credentials.clear()
                self?.signedOutReason =
                    note.userInfo?[APIClient.detailKey] as? String ?? "這台裝置的授權已失效"
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Credentials.didChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if Credentials.isEnrolled {
                    // Signing in successfully answers the message; signing out
                    // does not, since that is when it was just written.
                    self?.signedOutReason = nil

                    // And drop whatever the last credential downloaded. The
                    // cache is keyed by ids the SERVER assigns — masters by
                    // image id, details by template id — and those are only
                    // unique within one database. Point a device at a rebuilt
                    // server and template 2 is a different paper that happens
                    // to share a number, while `cacheMaster` skips the
                    // download because a file with that name is already there.
                    // The symptom is a template that quietly shows the wrong
                    // sheet, which is worse than showing nothing.
                    TemplateStore.shared.purge()
                }
                Task { await self?.loadTemplates() }
            }
            .store(in: &cancellables)
    }

    var selectedTemplate: ExamTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    var isDemo: Bool { DemoData.isEnabled }

    /// True until the device is either enrolled or the person has chosen to
    /// look around with the bundled sheets. Landing straight on the template
    /// list is how someone ends up grading a real paper against a sample.
    var needsLogin: Bool {
        !Credentials.isEnrolled
            && UserDefaults.standard.object(forKey: DemoData.modeKey) == nil
    }

    /// Take the bundled sheets deliberately. Recorded rather than inferred so
    /// the login screen does not reappear on every launch.
    func enterDemo() {
        UserDefaults.standard.set(true, forKey: DemoData.modeKey)
        objectWillChange.send()
        Task { await loadTemplates() }
    }

    /// True when someone chose the demo rather than merely lacking a
    /// credential. Settings uses it to decide whether it owes them a way out:
    /// `enterDemo` writes a flag that nothing else removed, so choosing 先看示範
    /// on the login screen used to be a one-way door — the screen could never
    /// come back, on any launch.
    var isExplicitDemo: Bool {
        !Credentials.isEnrolled
            && UserDefaults.standard.object(forKey: DemoData.modeKey) != nil
    }

    /// The mirror of `enterDemo`, and deliberately not `signOut`: nothing was
    /// downloaded under a demo flag and nothing is being revoked, so purging
    /// the template cache here would be theatre with a confirmation dialog
    /// attached.
    func exitDemo() {
        UserDefaults.standard.removeObject(forKey: DemoData.modeKey)
        selectedTemplateID = nil
        lastResult = nil
        objectWillChange.send()
        Task { await loadTemplates() }
    }

    // MARK: - Templates

    func loadTemplates() async {
        isLoadingTemplates = true
        templatesError = nil

        if DemoData.isEnabled {
            templates = DemoData.shared.templateList(search: nil)
        } else {
            // Show whatever synced earlier first, then refresh over it. A
            // teacher opening the app on a dead network gets their templates,
            // not a spinner followed by an error.
            templates = TemplateStore.shared.templates
            await TemplateStore.shared.refresh()
            templates = TemplateStore.shared.templates
            templatesError = TemplateStore.shared.syncError
        }

        if let selected = selectedTemplateID,
           !templates.contains(where: { $0.id == selected }) {
            selectedTemplateID = nil
        }
        isLoadingTemplates = false
    }

    func renameTemplate(_ template: ExamTemplate, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            if DemoData.isEnabled {
                DemoData.shared.rename(id: template.id, name: trimmed)
            } else {
                try await APIClient.shared.renameTemplate(id: template.id, name: trimmed)
            }
            await loadTemplates()
        } catch {
            templatesError = error.localizedDescription
        }
    }

    func deleteTemplate(_ template: ExamTemplate) async {
        do {
            if DemoData.isEnabled {
                DemoData.shared.delete(id: template.id)
            } else {
                try await APIClient.shared.deleteTemplate(id: template.id)
            }
            if selectedTemplateID == template.id { selectedTemplateID = nil }
            templates.removeAll { $0.id == template.id }
            await loadTemplates()
        } catch {
            templatesError = error.localizedDescription
        }
    }

    // MARK: - Enrolment

    func signOut() {
        Credentials.clear()
        // Also drop any explicit demo choice: a device with neither a
        // credential nor that flag belongs on the login screen, and leaving
        // the flag set to `false` would strand it with neither.
        UserDefaults.standard.removeObject(forKey: DemoData.modeKey)
        // The answer keys came down with a credential that no longer exists;
        // they should not outlive it on a shared device.
        TemplateStore.shared.purge()
        selectedTemplateID = nil
        lastResult = nil
        Task { await loadTemplates() }
    }
}
