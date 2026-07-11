import Foundation

// Endpoints match the web frontend's vite.config.ts proxies:
//   /api/predict        -> http://140.115.54.241:8082/predict   (YOLO)
//   /api/ocr_process    -> http://140.115.54.239:8083/ocr       (student handwriting OCR)
//   /ocr_google         -> http://140.115.54.241:8083/ocr_google (master answer OCR)
//   /api/exam-templates -> http://140.115.54.241:8084/api/exam-templates

enum ServerConfig {
    static let predictKey = "server.predict"
    static let ocrKey = "server.ocr"
    static let ocrGoogleKey = "server.ocrGoogle"
    static let templatesKey = "server.templates"

    static let defaultPredict = "http://140.115.54.241:8082"
    static let defaultOCR = "http://140.115.54.239:8083"
    static let defaultOCRGoogle = "http://140.115.54.241:8083"
    static let defaultTemplates = "http://140.115.54.241:8084"

    private static func value(_ key: String, _ fallback: String) -> String {
        let raw = UserDefaults.standard.string(forKey: key) ?? fallback
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? fallback : trimmed
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    static var predictBase: String { value(predictKey, defaultPredict) }
    static var ocrBase: String { value(ocrKey, defaultOCR) }
    static var ocrGoogleBase: String { value(ocrGoogleKey, defaultOCRGoogle) }
    static var templatesBase: String { value(templatesKey, defaultTemplates) }

    static func templateImageURL(id: Int) -> URL? {
        URL(string: "\(templatesBase)/api/exam-templates/\(id)/image")
    }
}

enum APIError: LocalizedError {
    case badURL
    case badStatus(Int)
    case badPayload
    case imageEncoding

    var errorDescription: String? {
        switch self {
        case .badURL: return "伺服器位址無效，請至設定檢查"
        case .badStatus(let code): return "伺服器回應錯誤（\(code)）"
        case .badPayload: return "無法解析伺服器回應"
        case .imageEncoding: return "圖片編碼失敗"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        session = URLSession(configuration: config)
    }

    // MARK: - Helpers

    private func request(_ urlString: String,
                         method: String = "GET",
                         jsonBody: Any? = nil) async throws -> Data {
        guard let url = URL(string: urlString) else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }

    // MARK: - Exam templates

    func listTemplates(search: String? = nil) async throws -> [ExamTemplate] {
        if DemoData.isEnabled { return DemoData.shared.templateList(search: search) }
        var urlString = "\(ServerConfig.templatesBase)/api/exam-templates"
        if let search, !search.isEmpty,
           let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "?search=\(encoded)"
        }
        let data = try await request(urlString)
        return try JSONDecoder().decode(TemplateListResponse.self, from: data).templates
    }

    func templateDetail(id: Int) async throws -> TemplateDetail {
        if DemoData.isEnabled { return DemoData.shared.templateDetail(id: id) }
        let data = try await request("\(ServerConfig.templatesBase)/api/exam-templates/\(id)")
        return try JSONDecoder().decode(TemplateDetail.self, from: data)
    }

    func renameTemplate(id: Int, name: String) async throws {
        if DemoData.isEnabled { DemoData.shared.rename(id: id, name: name); return }
        _ = try await request("\(ServerConfig.templatesBase)/api/exam-templates/\(id)",
                              method: "PATCH",
                              jsonBody: ["exam_name": name])
    }

    func deleteTemplate(id: Int) async throws {
        if DemoData.isEnabled { DemoData.shared.delete(id: id); return }
        _ = try await request("\(ServerConfig.templatesBase)/api/exam-templates/\(id)",
                              method: "DELETE")
    }

    // pages: [{ image, annotations: [{ class, bbox: [x,y,w,h], answer }] }]
    // in web-canvas (800x600) space; imageBase64DataURL is a data: URL,
    // exactly like the web app's POST body.
    func createTemplate(name: String, imageBase64DataURL: String, pages: [[String: Any]]) async throws {
        if DemoData.isEnabled {
            let anns = (pages.first?["annotations"] as? [[String: Any]]) ?? []
            DemoData.shared.create(name: name, answers: anns.map { ($0["answer"] as? String) ?? "" })
            return
        }
        _ = try await request("\(ServerConfig.templatesBase)/api/exam-templates",
                              method: "POST",
                              jsonBody: [
                                "exam_name": name,
                                "image_base64": imageBase64DataURL,
                                "pages": pages
                              ])
    }

    // MARK: - YOLO detection

    // Returns bboxes [x1, y1, x2, y2] in the submitted image's pixel space.
    func predict(imageBase64: String) async throws -> [[Double]] {
        if DemoData.isEnabled { return DemoData.shared.detect(imageBase64: imageBase64) }
        let data = try await request("\(ServerConfig.predictBase)/predict",
                                     method: "POST",
                                     jsonBody: ["image_base64": imageBase64])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badPayload
        }
        let detections = (root["detections"] as? [[String: Any]])
            ?? (((root["body"] as? [String: Any])?["json"] as? [String: Any])?["detections"] as? [[String: Any]])
            ?? []
        return detections.compactMap { det in
            guard let bbox = det["bbox"] as? [Any], bbox.count >= 4 else { return nil }
            let nums = bbox.prefix(4).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
            return Array(nums)
        }
    }

    // MARK: - OCR

    private func ocrPayload(imageBase64: String, boxes: [[Double]]) -> [String: Any] {
        [
            "image": imageBase64,
            "annotations": boxes.map { ["class": "答案區", "bbox": $0] }
        ]
    }

    private func ocrResultsArray(from data: Data) throws -> [Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badPayload
        }
        return (root["ocr_results"] as? [Any]) ?? (root["results"] as? [Any]) ?? []
    }

    // Handwriting OCR for student papers -> {chinese, digit} per box.
    func ocrStudent(imageBase64: String, boxes: [[Double]]) async throws -> [OCRCandidate] {
        if DemoData.isEnabled {
            return DemoData.shared.ocr(count: boxes.count).map {
                var c = OCRCandidate(); c.text = $0; return c
            }
        }
        let data = try await request("\(ServerConfig.ocrBase)/ocr",
                                     method: "POST",
                                     jsonBody: ocrPayload(imageBase64: imageBase64, boxes: boxes))
        return try ocrResultsArray(from: data).map { item in
            var candidate = OCRCandidate()
            if let dict = item as? [String: Any] {
                candidate.chinese = (dict["chinese"] as? String) ?? ""
                candidate.digit = dict["digit"].map { "\($0)" } ?? ""
                if candidate.chinese.isEmpty && candidate.digit.isEmpty {
                    candidate.text = (dict["text"] as? String)
                        ?? (dict["answer"] as? String)
                        ?? (dict["result"] as? String) ?? ""
                }
            } else if let str = item as? String {
                candidate.text = str
            }
            return candidate
        }
    }

    // Google OCR for the master answer key -> plain text per box.
    func ocrMaster(imageBase64: String, boxes: [[Double]]) async throws -> [String] {
        if DemoData.isEnabled { return DemoData.shared.ocr(count: boxes.count) }
        let data = try await request("\(ServerConfig.ocrGoogleBase)/ocr_google",
                                     method: "POST",
                                     jsonBody: ocrPayload(imageBase64: imageBase64, boxes: boxes))
        return try ocrResultsArray(from: data).map { item in
            if let dict = item as? [String: Any] {
                return (dict["google_text"] as? String)
                    ?? (dict["text"] as? String)
                    ?? (dict["answer"] as? String) ?? ""
            }
            return (item as? String) ?? ""
        }
    }
}
