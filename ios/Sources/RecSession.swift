import Foundation

// Запись = папка в Documents/sessions/<стамп>/ с mic.m4a и meeting.json.
// Тот же формат папки, что у мак-аппки (mac-capture/recordings/<стамп>),
// поэтому Мак принимает её без конвертаций.

struct RecSession: Identifiable, Equatable {
    let id: String            // "2026-08-11 14-05-33"
    var title: String
    var started: Date
    var duration: Double
    var uploaded: Bool
    var dir: URL

    var audio: URL { dir.appendingPathComponent("mic.m4a") }
    var metaFile: URL { dir.appendingPathComponent("meeting.json") }

    var durationText: String {
        let s = Int(duration.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// meeting.json — контракт с транскрайбером на Маке.
    /// `single_track` = все спикеры в одной дорожке (телефон пишет только
    /// микрофон): Мак обязан диаризовать mic, а не считать его речью владельца.
    var metaJSON: [String: Any] {
        var out: [String: Any] = [
            "title": title,
            "started": ISO8601DateFormatter().string(from: started),
            "duration": duration,
            "source": "iphone",
            "single_track": true,
        ]
        // Имя владельца — чтобы Мак подписал его реплики «Я» (сверяет с
        // библиотекой голосов). Пусто — все спикеры пойдут как «Собеседник N».
        let me = UserDefaults.standard.string(forKey: "ownerName") ?? ""
        if !me.trimmingCharacters(in: .whitespaces).isEmpty { out["owner"] = me }
        return out
    }
}

enum SessionFormat {
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func newID(at date: Date) -> String { stamp.string(from: date) }

    static func date(fromID id: String) -> Date? { stamp.date(from: id) }
}

@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [RecSession] = []

    static let root: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    init() { reload() }

    func reload() { sessions = Self.scan(root: Self.root) }

    /// Читает папку сессий. Битые/пустые записи пропускает молча — иначе одна
    /// оборванная запись роняет весь список.
    nonisolated static func scan(root: URL) -> [RecSession] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [RecSession] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let id = dir.lastPathComponent
            guard let started = SessionFormat.date(fromID: id) else { continue }
            guard fm.fileExists(atPath: dir.appendingPathComponent("mic.m4a").path) else { continue }
            var meta: [String: Any] = [:]
            if let data = try? Data(contentsOf: dir.appendingPathComponent("meeting.json")),
               let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                meta = obj
            }
            out.append(RecSession(
                id: id,
                title: meta["title"] as? String ?? id,
                started: started,
                duration: meta["duration"] as? Double ?? 0,
                uploaded: meta["uploaded"] as? Bool ?? false,
                dir: dir))
        }
        return out.sorted { $0.started > $1.started }
    }

    func write(meta: RecSession) {
        var dict = meta.metaJSON
        dict["uploaded"] = meta.uploaded
        guard let data = try? JSONSerialization.data(withJSONObject: dict,
                                                     options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? data.write(to: meta.metaFile)
    }

    func markUploaded(_ session: RecSession) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i].uploaded = true
        write(meta: sessions[i])
    }

    func rename(_ session: RecSession, to title: String) {
        guard let i = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        sessions[i].title = title
        write(meta: sessions[i])
    }

    func delete(_ session: RecSession) {
        try? FileManager.default.removeItem(at: session.dir)
        sessions.removeAll { $0.id == session.id }
    }
}
