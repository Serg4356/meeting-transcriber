import XCTest
@testable import Terminus

final class UploaderTests: XCTestCase {
    func test_endpoint_adds_scheme_port_and_path() {
        let url = Uploader.endpoint(host: "mac.local")
        XCTAssertEqual(url?.absoluteString, "http://mac.local:8787/upload")
    }

    func test_endpoint_keeps_explicit_port() {
        let url = Uploader.endpoint(host: "192.168.1.5:9000")
        XCTAssertEqual(url?.absoluteString, "http://192.168.1.5:9000/upload")
    }

    func test_endpoint_nil_for_empty_host() {
        XCTAssertNil(Uploader.endpoint(host: "   "))
    }

    func test_body_has_both_parts_and_closing_boundary() {
        let data = Uploader.body(boundary: "B",
                                 meta: #"{"title":"x"}"#.data(using: .utf8)!,
                                 audio: Data([0xAA, 0xBB]),
                                 filename: "mic.m4a")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"meta\""))
        XCTAssertTrue(text.contains("name=\"audio\"; filename=\"mic.m4a\""))
        XCTAssertTrue(text.hasSuffix("--B--\r\n"), "нет закрывающего boundary — сервер повиснет на разборе")
        XCTAssertTrue(data.range(of: Data([0xAA, 0xBB])) != nil, "аудио потерялось в теле")
    }
}

final class SessionStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(_ id: String, meta: [String: Any]? = nil, audio: Bool = true) throws {
        let dir = root.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if audio {
            try Data([0x00]).write(to: dir.appendingPathComponent("mic.m4a"))
        }
        if let meta {
            let data = try JSONSerialization.data(withJSONObject: meta)
            try data.write(to: dir.appendingPathComponent("meeting.json"))
        }
    }

    func test_scan_sorts_newest_first_and_reads_meta() throws {
        try makeSession("2026-08-11 09-00-00", meta: ["title": "Старая", "duration": 61.0])
        try makeSession("2026-08-11 18-30-00", meta: ["title": "Свежая", "duration": 5.0, "uploaded": true])
        let found = SessionStore.scan(root: root)
        XCTAssertEqual(found.map(\.title), ["Свежая", "Старая"])
        XCTAssertTrue(found[0].uploaded)
        XCTAssertEqual(found[1].durationText, "1:01")
    }

    func test_scan_skips_session_without_audio() throws {
        try makeSession("2026-08-11 10-00-00", meta: ["title": "Оборвалась"], audio: false)
        XCTAssertTrue(SessionStore.scan(root: root).isEmpty)
    }

    func test_scan_survives_broken_meta() throws {
        try makeSession("2026-08-11 11-00-00")
        let dir = root.appendingPathComponent("2026-08-11 11-00-00")
        try "{не json".data(using: .utf8)!.write(to: dir.appendingPathComponent("meeting.json"))
        let found = SessionStore.scan(root: root)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].title, "2026-08-11 11-00-00")   // фолбэк на id
    }

    func test_scan_ignores_foreign_folders() throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Inbox"), withIntermediateDirectories: true)
        XCTAssertTrue(SessionStore.scan(root: root).isEmpty)
    }

    func test_meta_marks_single_track_for_mac_pipeline() {
        let s = RecSession(id: "2026-08-11 12-00-00", title: "Планёрка",
                           started: Date(), duration: 12, uploaded: false,
                           dir: root)
        XCTAssertEqual(s.metaJSON["single_track"] as? Bool, true,
                       "без флага Мак посчитает всю дорожку речью владельца")
        XCTAssertEqual(s.metaJSON["source"] as? String, "iphone")
    }

    func test_meta_carries_owner_name_only_when_set() {
        let s = RecSession(id: "2026-08-11 12-00-00", title: "x", started: Date(),
                           duration: 1, uploaded: false, dir: root)
        UserDefaults.standard.removeObject(forKey: "ownerName")
        XCTAssertNil(s.metaJSON["owner"])
        UserDefaults.standard.set("  ", forKey: "ownerName")
        XCTAssertNil(s.metaJSON["owner"], "пробелы — это не имя")
        UserDefaults.standard.set("Иванов", forKey: "ownerName")
        XCTAssertEqual(s.metaJSON["owner"] as? String, "Иванов")
        UserDefaults.standard.removeObject(forKey: "ownerName")
    }
}
