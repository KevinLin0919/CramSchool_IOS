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

    // Last grading result (results tab stays disabled until one exists)
    @Published var lastResult: GradingResult?

    var selectedTemplate: ExamTemplate? {
        templates.first { $0.id == selectedTemplateID }
    }

    var hasResults: Bool { lastResult != nil }

    func loadTemplates() async {
        isLoadingTemplates = true
        templatesError = nil
        do {
            templates = try await APIClient.shared.listTemplates()
            if let selected = selectedTemplateID,
               !templates.contains(where: { $0.id == selected }) {
                selectedTemplateID = nil
            }
        } catch {
            templatesError = error.localizedDescription
        }
        isLoadingTemplates = false
    }

    func renameTemplate(_ template: ExamTemplate, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        do {
            try await APIClient.shared.renameTemplate(id: template.id, name: trimmed)
            await loadTemplates()
        } catch {
            templatesError = error.localizedDescription
        }
    }

    func deleteTemplate(_ template: ExamTemplate) async {
        do {
            try await APIClient.shared.deleteTemplate(id: template.id)
            if selectedTemplateID == template.id { selectedTemplateID = nil }
            templates.removeAll { $0.id == template.id }
        } catch {
            templatesError = error.localizedDescription
        }
    }
}
