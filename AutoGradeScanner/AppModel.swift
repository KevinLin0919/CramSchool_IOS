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

    /// Set when the server rejects our credential. Drives the enrolment
    /// prompt, so a revoked device says so once instead of failing every
    /// screen in its own words.
    @Published var needsEnrolment = false

    /// The session just finished, for the scanner's own one-shot flow.
    /// The stack the results page shows lives in `GradingStore` — it survives
    /// the app being killed, which this does not.
    @Published var lastResult: GradingResult?

    private var cancellables: Set<AnyCancellable> = []

    init() {
        NotificationCenter.default.publisher(for: APIClient.unauthorizedNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                Credentials.clear()
                self?.needsEnrolment = true
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: Credentials.didChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.needsEnrolment = false
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
