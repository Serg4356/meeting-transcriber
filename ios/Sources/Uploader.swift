import Foundation

// Отправка записи на Мак: multipart POST на ingest_server.py.
// Мак принимает файл, кладёт в recordings/<id>/ и запускает transcribe.py.

enum UploadState: Equatable {
    case idle
    case sending(Double)      // 0…1
    case done
    case failed(String)
}

enum Uploader {
    static let defaultPort = 8787

    /// Хост Мака из настроек: "mac.local" или "192.168.1.5" (порт опционален).
    static func endpoint(host: String) -> URL? {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var s = trimmed
        if !s.contains("://") { s = "http://" + s }
        guard var comps = URLComponents(string: s), comps.host != nil else { return nil }
        if comps.port == nil { comps.port = defaultPort }
        comps.path = "/upload"
        return comps.url
    }

    /// Тело multipart: meta (json) + аудио. Отдельной функцией — тестируется
    /// без сети (граница, где легко перепутать CRLF и хвостовой boundary).
    static func body(boundary: String, meta: Data, audio: Data, filename: String) -> Data {
        var out = Data()
        func add(_ s: String) { out.append(s.data(using: .utf8)!) }
        add("--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"meta\"; filename=\"meeting.json\"\r\n")
        add("Content-Type: application/json\r\n\r\n")
        out.append(meta)
        add("\r\n--\(boundary)\r\n")
        add("Content-Disposition: form-data; name=\"audio\"; filename=\"\(filename)\"\r\n")
        add("Content-Type: audio/m4a\r\n\r\n")
        out.append(audio)
        add("\r\n--\(boundary)--\r\n")
        return out
    }

    static func upload(_ session: RecSession, host: String,
                       progress: @escaping (Double) -> Void) async throws {
        guard let url = endpoint(host: host) else {
            throw NSError(domain: "Terminus", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Не задан адрес Мака"])
        }
        let audio = try Data(contentsOf: session.audio)
        let meta = try JSONSerialization.data(withJSONObject: session.metaJSON, options: [.sortedKeys])
        let boundary = "terminus-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(session.id, forHTTPHeaderField: "X-Session-Id")
        req.timeoutInterval = 600      // час записи по слабому Wi-Fi
        progress(0.05)
        let payload = body(boundary: boundary, meta: meta, audio: audio,
                           filename: session.audio.lastPathComponent)
        let (data, resp) = try await URLSession.shared.upload(for: req, from: payload)
        progress(1)
        guard let http = resp as? HTTPURLResponse else {
            throw NSError(domain: "Terminus", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Мак не ответил"])
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "Terminus", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "Мак ответил \(http.statusCode). \(text.prefix(120))"])
        }
    }
}
