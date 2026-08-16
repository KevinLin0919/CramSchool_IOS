import CryptoKit
import Foundation
import UIKit

// Two servers, deliberately.
//
//   /api/v1/*   CramSchool_API — templates, images, grading results, auth.
//               One base URL, one bearer token, reached over the tailnet.
//
//   /predict    YOLO answer-box detection, and
//   /ocr_google standard-answer OCR. Both are only used when *building* a
//               template; grading itself runs entirely on device. They still
//               live wherever the inference boxes are, and the plan is to
//               proxy them behind the API so this collapses to one address —
//               until then they keep their own settings.

enum ServerConfig {
    static let apiKey = "server.api"
    static let predictKey = "server.predict"
    static let ocrKey = "server.ocr"
    static let ocrGoogleKey = "server.ocrGoogle"

    /// No sensible default exists: the address is a tailnet name unique to the
    /// school. Empty means "not configured", which the enrolment screen asks
    /// for rather than guessing.
    static let defaultAPI = ""
    static let defaultPredict = "http://140.115.54.241:8082"
    static let defaultOCR = "http://140.115.54.239:8083"
    static let defaultOCRGoogle = "http://140.115.54.241:8083"

    private static func value(_ key: String, _ fallback: String) -> String {
        let raw = UserDefaults.standard.string(forKey: key) ?? fallback
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let base = trimmed.isEmpty ? fallback : trimmed
        return base.hasSuffix("/") ? String(base.dropLast()) : base
    }

    static var apiBase: String { value(apiKey, defaultAPI) }
    static var predictBase: String { value(predictKey, defaultPredict) }
    static var ocrBase: String { value(ocrKey, defaultOCR) }
    static var ocrGoogleBase: String { value(ocrGoogleKey, defaultOCRGoogle) }

    static var isConfigured: Bool { !apiBase.isEmpty }
}

enum APIError: LocalizedError {
    case notConfigured
    case badURL
    case unauthorized
    case badStatus(Int)
    case badPayload
    case imageEncoding

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未設定伺服器位址，請至設定填寫"
        case .badURL: return "伺服器位址無效，請至設定檢查"
        case .unauthorized: return "裝置未註冊或授權已撤銷，請重新註冊"
        case .badStatus(let code): return "伺服器回應錯誤（\(code)）"
        case .badPayload: return "無法解析伺服器回應"
        case .imageEncoding: return "圖片編碼失敗"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    /// Posted on any 401 so the UI can send the teacher back to enrolment
    /// instead of showing a generic failure on every screen at once.
    static let unauthorizedNotification = Notification.Name("APIClient.unauthorized")

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
    }

    // MARK: - Plumbing

    private func makeRequest(path: String,
                             method: String = "GET",
                             query: [URLQueryItem] = [],
                             authenticated: Bool = true) throws -> URLRequest {
        guard ServerConfig.isConfigured else { throw APIError.notConfigured }
        guard var components = URLComponents(string: ServerConfig.apiBase + path) else {
            throw APIError.badURL
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.badURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if authenticated {
            guard let token = Credentials.token else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }
        if http.statusCode == 401 {
            // The credential is gone or revoked. Say so once, loudly, rather
            // than letting every screen invent its own wording for it.
            NotificationCenter.default.post(name: Self.unauthorizedNotification, object: nil)
            throw APIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.badPayload
        }
    }

    private func json(_ request: inout URLRequest, body: some Encodable) throws {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
    }

    // MARK: - Auth

    struct InvitePayload: Encodable {
        let invite_code: String
        let device_name: String
    }

    /// Swaps a single-use invite code for this device's token.
    func redeemInvite(code: String, deviceName: String) async throws -> TokenResponse {
        var request = try makeRequest(path: "/api/v1/auth/token",
                                      method: "POST",
                                      authenticated: false)
        try json(&request, body: InvitePayload(invite_code: code, device_name: deviceName))
        return try decode(TokenResponse.self, from: try await send(request))
    }

    func me() async throws -> TeacherDTO {
        try decode(TeacherDTO.self, from: try await send(try makeRequest(path: "/api/v1/auth/me")))
    }

    // MARK: - Templates

    /// `updatedSince` is the cursor the server handed back last time, passed
    /// through untouched. Omitting it asks for everything currently live.
    func listTemplates(updatedSince: String? = nil) async throws -> TemplateListDTO {
        var query: [URLQueryItem] = []
        if let updatedSince, !updatedSince.isEmpty {
            query.append(URLQueryItem(name: "updated_since", value: updatedSince))
        }
        let request = try makeRequest(path: "/api/v1/templates", query: query)
        return try decode(TemplateListDTO.self, from: try await send(request))
    }

    func templateDetail(id: Int) async throws -> TemplateDetailDTO {
        let request = try makeRequest(path: "/api/v1/templates/\(id)")
        return try decode(TemplateDetailDTO.self, from: try await send(request))
    }

    func masterImage(templateID: Int, page: Int = 0, width: Int) async throws -> Data {
        let request = try makeRequest(path: "/api/v1/templates/\(templateID)/master",
                                      query: [URLQueryItem(name: "w", value: String(width)),
                                              URLQueryItem(name: "page", value: String(page))])
        return try await send(request)
    }

    func renameTemplate(id: Int, name: String) async throws {
        struct Body: Encodable { let exam_name: String }
        var request = try makeRequest(path: "/api/v1/templates/\(id)", method: "PATCH")
        try json(&request, body: Body(exam_name: name))
        _ = try await send(request)
    }

    func deleteTemplate(id: Int) async throws {
        _ = try await send(try makeRequest(path: "/api/v1/templates/\(id)", method: "DELETE"))
    }

    // MARK: - Images

    /// multipart, and a HEAD first. Hashing a few megabytes locally costs
    /// milliseconds; sending them over the school's uplink costs seconds, and
    /// the master sheet is the same bytes on every device that syncs it.
    func uploadImage(_ data: Data, filename: String = "image.jpg") async throws -> ImageRef {
        let digest = Self.sha256Hex(data)
        if let existing = try? await imageByDigest(digest) { return existing }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try makeRequest(path: "/api/v1/images", method: "POST")
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: image/jpeg\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        return try decode(ImageRef.self, from: try await send(request))
    }

    func imageByDigest(_ digest: String) async throws -> ImageRef {
        let request = try makeRequest(path: "/api/v1/images/sha256/\(digest)")
        return try decode(ImageRef.self, from: try await send(request))
    }

    struct ImageRef: Decodable {
        let id: Int
        let sha256: String
        let width: Int
        let height: Int
    }

    // MARK: - Template creation

    struct NewBox: Encodable {
        let question_no: Int
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        let answer: String
        let answer_type: String
    }

    struct NewPage: Encodable {
        let page_index: Int
        let image_id: Int
        let boxes: [NewBox]
    }

    struct NewTemplate: Encodable {
        let exam_name: String
        let grade: String?
        let subject: String?
        let pages: [NewPage]
    }

    func createTemplate(_ payload: NewTemplate) async throws -> TemplateDetailDTO {
        var request = try makeRequest(path: "/api/v1/templates", method: "POST")
        try json(&request, body: payload)
        return try decode(TemplateDetailDTO.self, from: try await send(request))
    }

    // MARK: - Inference services (template building only)

    private func inferenceRequest(_ urlString: String, body: [String: Any]) throws -> URLRequest {
        guard let url = URL(string: urlString) else { throw APIError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func sendPlain(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.badStatus(http.statusCode)
        }
        return data
    }

    /// Returns bboxes [x1, y1, x2, y2] in the submitted image's pixel space.
    func predict(imageBase64: String) async throws -> [[Double]] {
        if DemoData.isEnabled { return DemoData.shared.detect(imageBase64: imageBase64) }
        let request = try inferenceRequest("\(ServerConfig.predictBase)/predict",
                                           body: ["image_base64": imageBase64])
        let data = try await sendPlain(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badPayload
        }
        let detections = (root["detections"] as? [[String: Any]])
            ?? (((root["body"] as? [String: Any])?["json"] as? [String: Any])?["detections"]
                    as? [[String: Any]])
            ?? []
        return detections.compactMap { detection in
            guard let bbox = detection["bbox"] as? [Any], bbox.count >= 4 else { return nil }
            return bbox.prefix(4).map { ($0 as? NSNumber)?.doubleValue ?? 0 }
        }
    }

    /// Handwriting OCR for the one-shot capture path.
    ///
    /// Live grading does not use this — it recognises on device. This is the
    /// fallback taken when alignment never locks on, and it is the last thing
    /// in the app that needs a server to *grade* rather than to store. Folding
    /// it into the on-device pipeline would drop the dependency entirely.
    func ocrStudent(imageBase64: String, boxes: [[Double]]) async throws -> [OCRCandidate] {
        if DemoData.isEnabled {
            return DemoData.shared.ocr(count: boxes.count).map {
                var candidate = OCRCandidate()
                candidate.text = $0
                return candidate
            }
        }
        let payload: [String: Any] = [
            "image": imageBase64,
            "annotations": boxes.map { ["class": "答案區", "bbox": $0] },
        ]
        let request = try inferenceRequest("\(ServerConfig.ocrBase)/ocr", body: payload)
        let data = try await sendPlain(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badPayload
        }
        let results = (root["ocr_results"] as? [Any]) ?? (root["results"] as? [Any]) ?? []
        return results.map { item in
            var candidate = OCRCandidate()
            if let dict = item as? [String: Any] {
                candidate.chinese = (dict["chinese"] as? String) ?? ""
                candidate.digit = dict["digit"].map { "\($0)" } ?? ""
                if candidate.chinese.isEmpty && candidate.digit.isEmpty {
                    candidate.text = (dict["text"] as? String)
                        ?? (dict["answer"] as? String)
                        ?? (dict["result"] as? String) ?? ""
                }
            } else if let text = item as? String {
                candidate.text = text
            }
            return candidate
        }
    }

    /// Google OCR over the master sheet, to pre-fill the standard answers.
    func ocrMaster(imageBase64: String, boxes: [[Double]]) async throws -> [String] {
        if DemoData.isEnabled { return DemoData.shared.ocr(count: boxes.count) }
        let payload: [String: Any] = [
            "image": imageBase64,
            "annotations": boxes.map { ["class": "答案區", "bbox": $0] },
        ]
        let request = try inferenceRequest("\(ServerConfig.ocrGoogleBase)/ocr_google", body: payload)
        let data = try await sendPlain(request)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.badPayload
        }
        let results = (root["ocr_results"] as? [Any]) ?? (root["results"] as? [Any]) ?? []
        return results.map { item in
            if let dict = item as? [String: Any] {
                return (dict["google_text"] as? String)
                    ?? (dict["text"] as? String)
                    ?? (dict["answer"] as? String) ?? ""
            }
            return (item as? String) ?? ""
        }
    }

    // MARK: - Hashing

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
