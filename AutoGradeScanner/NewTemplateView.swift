import SwiftUI
import PhotosUI

// 新增 flow — photograph or pick a master answer sheet, auto-detect the
// answer boxes with YOLO, recognize the standard answers with Google OCR,
// let the user correct them, then save to the template server in the
// same 800x600 web-canvas format the web frontend uses.
struct NewTemplateView: View {
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Stage {
        case pickImage
        case detecting
        case recognizing
        case ready
        case saving
    }

    @State private var stage: Stage = .pickImage
    @State private var name = ""
    @State private var image: UIImage?
    @State private var boxes: [[Double]] = []
    @State private var answers: [String] = []
    @State private var errorMessage: String?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false

    private var isBusy: Bool {
        stage == .detecting || stage == .recognizing || stage == .saving
    }

    private var canSave: Bool {
        stage == .ready
            && image != nil
            && !boxes.isEmpty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例：高一數學・段考一", text: $name)
                } header: {
                    Text("考卷名稱")
                } footer: {
                    Text("名稱包含年級（如 高一）與科目（如 數學）時，會自動歸類到對應分組。")
                }

                Section("標準答案卷") {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 300)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        HStack {
                            statusLabel
                            Spacer()
                            Button("重新選擇") { reset() }
                                .disabled(isBusy)
                        }
                    } else {
                        Button {
                            showCamera = true
                        } label: {
                            Label("拍攝答案卷", systemImage: "camera")
                        }
                        .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))

                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("從相簿選擇", systemImage: "photo.on.rectangle")
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(AG.bad)
                                .font(.system(size: 14))
                            if let image {
                                Button("重試辨識") {
                                    Task { await analyze(image) }
                                }
                            }
                        }
                    }
                }

                if stage == .ready && !boxes.isEmpty {
                    Section {
                        ForEach(answers.indices, id: \.self) { index in
                            HStack(spacing: 12) {
                                Text("Q\(index + 1)")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AG.fg2)
                                    .frame(width: 36, alignment: .leading)
                                TextField("標準答案", text: $answers[index])
                                    .font(.system(size: 16).monospaced())
                            }
                        }
                        .onDelete { offsets in
                            answers.remove(atOffsets: offsets)
                            boxes.remove(atOffsets: offsets)
                        }
                    } header: {
                        Text("標準答案（共 \(boxes.count) 格）")
                    } footer: {
                        Text("已用 YOLO 偵測答案區並以 OCR 辨識標準答案，可直接修改。左滑可刪除多餘的格子。")
                    }
                }
            }
            .navigationTitle("新增考卷模板")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(stage == .saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if stage == .saving {
                        ProgressView()
                    } else {
                        Button("儲存") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { @MainActor in
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let picked = UIImage(data: data) {
                        await imageSelected(picked)
                    }
                    pickerItem = nil
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { picked in
                    Task { await imageSelected(picked) }
                }
                .ignoresSafeArea()
            }
            .interactiveDismissDisabled(isBusy)
        }
    }

    private var statusLabel: some View {
        Group {
            switch stage {
            case .detecting:
                Label("YOLO 偵測答案區中…", systemImage: "viewfinder")
            case .recognizing:
                Label("OCR 辨識標準答案中…", systemImage: "text.viewfinder")
            case .ready:
                Label("已偵測 \(boxes.count) 格答案區", systemImage: "checkmark.circle")
                    .foregroundStyle(AG.ok)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(AG.fg2)
    }

    // MARK: - Flow

    private func reset() {
        image = nil
        boxes = []
        answers = []
        errorMessage = nil
        stage = .pickImage
    }

    @MainActor
    private func imageSelected(_ picked: UIImage) async {
        let prepared = picked.normalizedForUpload(maxDimension: 1600)
        image = prepared
        await analyze(prepared)
    }

    @MainActor
    private func analyze(_ prepared: UIImage) async {
        errorMessage = nil
        stage = .detecting
        do {
            guard let jpeg = prepared.jpegData(compressionQuality: 0.85) else {
                throw APIError.imageEncoding
            }
            let base64 = jpeg.base64EncodedString()

            let detected = try await APIClient.shared.predict(imageBase64: base64)
            guard !detected.isEmpty else {
                boxes = []
                answers = []
                stage = .ready
                errorMessage = "未偵測到答案區，請換一張更清晰的照片"
                return
            }
            boxes = detected

            stage = .recognizing
            var recognized: [String] = []
            do {
                recognized = try await APIClient.shared.ocrMaster(imageBase64: base64,
                                                                  boxes: detected)
            } catch {
                // OCR failure is non-fatal — answers can be typed by hand.
                recognized = []
            }
            answers = (0..<detected.count).map { index in
                index < recognized.count
                    ? recognized[index].trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
            }
            stage = .ready
        } catch {
            boxes = []
            answers = []
            stage = .ready
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let image, canSave,
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return }
        stage = .saving
        errorMessage = nil

        // Convert detected pixel bboxes into the web app's 800x600
        // labeling-canvas space so templates stay cross-compatible.
        let width = Double(image.size.width)
        let height = Double(image.size.height)
        let scale = min(WebCanvas.width / width, WebCanvas.height / height)
        let offsetX = (WebCanvas.width - width * scale) / 2
        let offsetY = (WebCanvas.height - height * scale) / 2

        let annotations: [[String: Any]] = boxes.enumerated().map { index, box in
            [
                "class": "答案區",
                "bbox": [
                    box[0] * scale + offsetX,
                    box[1] * scale + offsetY,
                    (box[2] - box[0]) * scale,
                    (box[3] - box[1]) * scale
                ],
                "answer": index < answers.count ? answers[index] : ""
            ]
        }

        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        do {
            try await APIClient.shared.createTemplate(
                name: trimmedName,
                imageBase64DataURL: "data:image/jpeg;base64,\(jpeg.base64EncodedString())",
                pages: [["image": trimmedName, "annotations": annotations]]
            )
            onSaved()
            dismiss()
        } catch {
            stage = .ready
            errorMessage = "儲存失敗：\(error.localizedDescription)"
        }
    }
}

// MARK: - UIKit camera picker (master sheet photos; also used by XFeatDebugView)

struct CameraPicker: UIViewControllerRepresentable {
    var onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
