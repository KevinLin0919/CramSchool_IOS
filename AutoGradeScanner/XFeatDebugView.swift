import SwiftUI
import PhotosUI
import CoreImage
import UIKit

// Debug page for verifying on-device XFeat alignment before it gets wired
// into the grading pipeline. Pick a template (from the server, with its
// answer boxes, or any photo) and a scanned/student photo, run
// XFeatAligner.alignmentHomography, then inspect:
//   1. the template answer boxes projected onto the scan (do the frames land
//      on the answer cells?)
//   2. the template warped onto the scan at ~50% opacity (do the printed
//      lines coincide, or is there ghosting?)
// plus the raw match / inlier numbers.
struct XFeatDebugView: View {

    // MARK: - Template side

    @State private var templates: [ExamTemplate] = []
    @State private var templatesError: String?
    @State private var selectedTemplateName: String?
    @State private var templateImage: UIImage?
    @State private var templateBoxes: [[Double]] = []   // [x,y,w,h] in 800x600 web-canvas space
    @State private var templatePickerItem: PhotosPickerItem?
    @State private var loadingTemplate = false

    // MARK: - Scan side

    @State private var scanImage: UIImage?
    @State private var scanPickerItem: PhotosPickerItem?
    @State private var showCamera = false

    // MARK: - Run state

    private enum RunState {
        case idle
        case running
        case failed(String)
        case done(AlignmentReport)
    }

    private struct AlignmentReport {
        let boxesImage: UIImage      // scan + projected page outline / answer boxes
        let blendImage: UIImage?     // template warped onto the scan, half transparent
        let matchCount: Int
        let inlierCount: Int
        let inlierRatio: Double
        let seconds: Double
    }

    @State private var runState: RunState = .idle

    var body: some View {
        Form {
            templateSection
            scanSection
            runSection
            if case .done(let report) = runState {
                metricsSection(report)
                imageSection(title: "投影題框（黃框應落在答案格上）", image: report.boxesImage)
                if let blend = report.blendImage {
                    imageSection(title: "半透明疊圖（印刷線條應重合）", image: blend)
                }
            }
        }
        .navigationTitle("XFeat 對位測試")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                scanImage = image.normalizedForUpload()
                runState = .idle
            }
            .ignoresSafeArea()
        }
        .task { await loadTemplateList() }
        .onChange(of: templatePickerItem) { _, item in
            guard let item else { return }
            Task { await loadPickedImage(item, into: .template) }
        }
        .onChange(of: scanPickerItem) { _, item in
            guard let item else { return }
            Task { await loadPickedImage(item, into: .scan) }
        }
    }

    // MARK: - Sections

    private var templateSection: some View {
        Section {
            Menu {
                ForEach(templates) { template in
                    Button(template.examName) {
                        Task { await loadServerTemplate(template) }
                    }
                }
            } label: {
                HStack {
                    Text("從伺服器選擇模板")
                    Spacer()
                    if loadingTemplate {
                        ProgressView()
                    } else if templates.isEmpty {
                        Text(templatesError == nil ? "載入中…" : "無法連線")
                            .foregroundStyle(AG.fg3)
                    }
                }
            }
            .disabled(templates.isEmpty || loadingTemplate)

            PhotosPicker(selection: $templatePickerItem, matching: .images) {
                Text("或從相簿選標準卷照片")
            }

            if let templateImage {
                thumbnailRow(image: templateImage,
                             title: selectedTemplateName ?? "相簿圖片",
                             subtitle: templateBoxes.isEmpty
                                ? "無題框資料，只會顯示頁面外框"
                                : "\(templateBoxes.count) 個題框")
            }
        } header: {
            Text("1・模板（標準卷）")
        } footer: {
            Text("從伺服器選擇會一併載入題框；相簿圖片沒有題框，只能看整頁對位。")
        }
    }

    private var scanSection: some View {
        Section {
            PhotosPicker(selection: $scanPickerItem, matching: .images) {
                Text("從相簿選擇")
            }
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照") { showCamera = true }
            }
            if let scanImage {
                thumbnailRow(image: scanImage, title: "已選擇掃描照片",
                             subtitle: "\(Int(scanImage.size.width))×\(Int(scanImage.size.height))")
            }
        } header: {
            Text("2・學生卷照片")
        } footer: {
            Text("拍同一份印刷卷（可以有手寫、角度歪斜），整頁入鏡效果最好。")
        }
    }

    private var runSection: some View {
        Section {
            Button {
                Task { await runAlignment() }
            } label: {
                HStack {
                    Text("執行對位")
                        .fontWeight(.semibold)
                    Spacer()
                    if case .running = runState {
                        ProgressView()
                    }
                }
            }
            .disabled(templateImage == nil || scanImage == nil || isRunning)

            if case .failed(let message) = runState {
                Label(message, systemImage: "xmark.circle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(AG.bad)
            }
        } footer: {
            Text("在裝置上執行 XFeat 特徵萃取 × 2、MNN 匹配與 RANSAC，不需網路。")
        }
    }

    private func metricsSection(_ report: AlignmentReport) -> some View {
        Section("對位結果") {
            HStack(spacing: 0) {
                metric("匹配點", "\(report.matchCount)")
                metric("Inlier", "\(report.inlierCount)（\(Int((report.inlierRatio * 100).rounded()))%）")
                metric("耗時", String(format: "%.2f s", report.seconds))
            }
            verdictLabel(report)
        }
    }

    private func imageSection(title: String, image: UIImage) -> some View {
        Section(title) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .listRowInsets(EdgeInsets())
                .contextMenu {
                    Button {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    } label: {
                        Label("儲存到相簿", systemImage: "square.and.arrow.down")
                    }
                }
        }
    }

    // MARK: - Small views

    private func thumbnailRow(image: UIImage, title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(AG.fg3)
            }
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(AG.fg3)
        }
        .frame(maxWidth: .infinity)
    }

    private func verdictLabel(_ report: AlignmentReport) -> some View {
        let good = report.inlierCount >= 30 && report.inlierRatio >= 0.25
        return Label(good ? "對位成功，可信賴投影結果"
                          : "Inlier 偏少，對位品質存疑——換個角度或光線再試",
                     systemImage: good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundStyle(good ? AG.ok : AG.warn)
    }

    private var isRunning: Bool {
        if case .running = runState { return true }
        return false
    }

    // MARK: - Loading

    private func loadTemplateList() async {
        do {
            templates = try await APIClient.shared.listTemplates()
            templatesError = nil
        } catch {
            templatesError = error.localizedDescription
        }
    }

    @MainActor
    private func loadServerTemplate(_ template: ExamTemplate) async {
        loadingTemplate = true
        defer { loadingTemplate = false }
        do {
            guard let url = ServerConfig.templateImageURL(id: template.id) else {
                throw APIError.badURL
            }
            async let imageData = URLSession.shared.data(from: url).0
            async let detail = APIClient.shared.templateDetail(id: template.id)
            guard let image = UIImage(data: try await imageData) else {
                throw APIError.badPayload
            }
            templateImage = image.normalizedForUpload()
            templateBoxes = try await detail.pages.flatMap { $0.annotations.map(\.bbox) }
            selectedTemplateName = template.examName
            runState = .idle
        } catch {
            runState = .failed("模板載入失敗：\(error.localizedDescription)")
        }
    }

    private enum PickTarget { case template, scan }

    @MainActor
    private func loadPickedImage(_ item: PhotosPickerItem, into target: PickTarget) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            runState = .failed("無法讀取所選照片")
            return
        }
        let normalized = image.normalizedForUpload()
        switch target {
        case .template:
            templateImage = normalized
            templateBoxes = []
            selectedTemplateName = nil
        case .scan:
            scanImage = normalized
        }
        runState = .idle
    }

    // MARK: - Alignment

    @MainActor
    private func runAlignment() async {
        guard let templateImage, let scanImage else { return }
        runState = .running
        let boxes = templateBoxes

        do {
            let report = try await Task.detached(priority: .userInitiated) { () async throws -> AlignmentReport in
                let start = Date()
                guard let homography = try XFeatAligner.alignmentHomography(template: templateImage,
                                                                            scan: scanImage) else {
                    throw XFeatDebugError.alignmentFailed
                }
                let seconds = Date().timeIntervalSince(start)
                let boxesImage = XFeatDebugRender.projectedBoxes(scan: scanImage,
                                                                 homography: homography,
                                                                 boxes: boxes)
                let blendImage = XFeatDebugRender.blend(template: templateImage,
                                                        scan: scanImage,
                                                        homography: homography)
                return AlignmentReport(boxesImage: boxesImage,
                                       blendImage: blendImage,
                                       matchCount: homography.matchCount,
                                       inlierCount: homography.inlierCount,
                                       inlierRatio: homography.inlierRatio,
                                       seconds: seconds)
            }.value
            runState = .done(report)
        } catch XFeatError.modelMissing {
            runState = .failed("XFeat 模型載入失敗（bundle 內缺少 XFeat.mlmodelc）")
        } catch XFeatDebugError.alignmentFailed {
            runState = .failed("匹配點不足或無法估計 homography——確認兩張照片是同一份印刷卷、整頁入鏡")
        } catch {
            runState = .failed("對位失敗：\(error.localizedDescription)")
        }
    }
}

private enum XFeatDebugError: Error {
    case alignmentFailed
}

// MARK: - Rendering

private enum XFeatDebugRender {

    // Scan photo with the projected template page outline (dashed green) and
    // every answer box (yellow) drawn as true quadrilaterals, so perspective
    // error is visible instead of being hidden by axis-aligned bounding boxes.
    static func projectedBoxes(scan: UIImage,
                               homography: XFeatMatcher.Homography,
                               boxes: [[Double]]) -> UIImage {
        let size = scan.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            scan.draw(in: CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            let lineWidth = max(size.width, size.height) / 450

            func projected(_ point: CGPoint) -> CGPoint {
                let p = homography.project(point)
                return CGPoint(x: p.x * size.width, y: p.y * size.height)
            }

            func strokeQuad(_ corners: [CGPoint], color: UIColor,
                            width: CGFloat, dashed: Bool = false) {
                cg.saveGState()
                cg.setStrokeColor(color.cgColor)
                cg.setLineWidth(width)
                if dashed {
                    cg.setLineDash(phase: 0, lengths: [width * 4, width * 3])
                }
                cg.beginPath()
                cg.addLines(between: corners)
                cg.closePath()
                cg.strokePath()
                cg.restoreGState()
            }

            let pageCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                               CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(projected)
            strokeQuad(pageCorners,
                       color: UIColor(red: 0.32, green: 0.72, blue: 0.53, alpha: 1),
                       width: lineWidth, dashed: true)

            for box in boxes where box.count >= 4 {
                let x = box[0] / WebCanvas.width
                let y = box[1] / WebCanvas.height
                let w = box[2] / WebCanvas.width
                let h = box[3] / WebCanvas.height
                let corners = [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                               CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)].map(projected)
                strokeQuad(corners, color: .systemYellow, width: lineWidth)
            }
        }
    }

    // Template warped onto the scan through the homography, composited at
    // ~50% opacity: when alignment is right the printed content coincides,
    // when it is off the ghosting shows exactly where and how much.
    static func blend(template: UIImage, scan: UIImage,
                      homography: XFeatMatcher.Homography) -> UIImage? {
        guard let templateCG = template.cgImage, let scanCG = scan.cgImage else { return nil }
        let scanCI = CIImage(cgImage: scanCG)
        let width = scanCI.extent.width
        let height = scanCI.extent.height

        // Core Image is bottom-up; homography output is top-down normalized.
        func corner(_ point: CGPoint) -> CIVector {
            let p = homography.project(point)
            return CIVector(x: p.x * width, y: height - p.y * height)
        }

        guard let warp = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        warp.setValue(CIImage(cgImage: templateCG), forKey: kCIInputImageKey)
        warp.setValue(corner(CGPoint(x: 0, y: 0)), forKey: "inputTopLeft")
        warp.setValue(corner(CGPoint(x: 1, y: 0)), forKey: "inputTopRight")
        warp.setValue(corner(CGPoint(x: 1, y: 1)), forKey: "inputBottomRight")
        warp.setValue(corner(CGPoint(x: 0, y: 1)), forKey: "inputBottomLeft")
        guard let warped = warp.outputImage else { return nil }

        // Core Image works premultiplied, so RGB has to be scaled along with
        // alpha or the composite blows out instead of fading.
        let translucent = warped.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.5, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.5, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)
        ])
        let composited = translucent.composited(over: scanCI).cropped(to: scanCI.extent)
        guard let output = CIContext().createCGImage(composited, from: scanCI.extent) else {
            return nil
        }
        return UIImage(cgImage: output)
    }
}
