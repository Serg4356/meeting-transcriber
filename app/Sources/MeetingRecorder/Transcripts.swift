// Список записанных встреч с тумблером «в общей базе».
// Один контрол закрывает три сценария: опубликовать сразу, опубликовать позже
// (передумал), убрать из базы (передумал обратно).

import AppKit
import SwiftUI

struct MeetingItem: Identifiable {
    let id: String          // meeting_key в БД
    let session: URL
    let title: String
    let startedAt: Date
    var published: Bool = false
    var busy: Bool = false
}

enum TranscriptStore {
    /// Ключ встречи. Префикс пользователем — чтобы записи разных людей об одной
    /// встрече не перетирали друг друга (у каждого свой таймстемп старта).
    /// ponytail: одна встреча, записанная двумя людьми, ляжет двумя строками.
    /// Схлопывать — только если это реально начнёт мешать.
    static func key(user: String, session: URL) -> String {
        "\(user.isEmpty ? "local" : user)/\(session.lastPathComponent)"
    }

    private static let folderFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()

    /// Локальные сессии, у которых уже готов транскрипт (свежие сверху).
    static func localMeetings(limit: Int = 40) -> [MeetingItem] {
        let fm = FileManager.default
        let root = AppPaths.recordingsDir
        var dirs = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        // старое место внутри папки с кодом — показываем, пока человек не перенёс
        let legacy = AppPaths.legacyRecordingsDir
        if legacy.path != root.path,
           let old = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
            dirs += old
        }
        let user = DBConfig.user
        return dirs
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("transcript.md").path) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)
            .map { dir in
                let name = dir.lastPathComponent
                let title = (try? String(contentsOf: dir.appendingPathComponent("title.txt"),
                                         encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return MeetingItem(id: key(user: user, session: dir),
                                   session: dir,
                                   title: (title?.isEmpty == false ? title! : name),
                                   startedAt: folderFmt.date(from: name) ?? .distantPast)
            }
    }

    /// Что из моего уже лежит в общей базе.
    static func publishedKeys() async throws -> Set<String> {
        // Спрашиваем саму таблицу, а не вью: её имя задаёт пользователь, и
        // угадывать имя вью подстановкой строки — прямой путь к мусору в запросе.
        let sql = "SELECT meeting_key FROM \(DBConfig.table) FINAL "
            + "WHERE uploaded_by = currentUser() AND deleted = 0 FORMAT TSV"
        let text = try await CH.run(sql)
        return Set(text.split(separator: "\n").map(String.init))
    }

    static func push(_ item: MeetingItem) async throws {
        let body = try String(contentsOf: item.session.appendingPathComponent("transcript.md"),
                              encoding: .utf8)
        try await insert(item: item, body: body, deleted: 0)
    }

    /// Откат — не DELETE, а новая версия с флагом. Вью её не показывает.
    static func unpush(_ item: MeetingItem) async throws {
        try await insert(item: item, body: "", deleted: 1)
    }

    private static func insert(item: MeetingItem, body: String, deleted: Int) async throws {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let row: [String: Any] = [
            "meeting_key": item.id,
            "title": item.title,
            "started_at": f.string(from: item.startedAt == .distantPast ? Date() : item.startedAt),
            "body": body,
            "deleted": deleted,
        ]
        let json = try JSONSerialization.data(withJSONObject: row, options: [])
        let sql = "INSERT INTO \(DBConfig.table) "
            + "(meeting_key, title, started_at, body, deleted) FORMAT JSONEachRow"
        _ = try await CH.run(sql, body: json)
    }
}

// MARK: - UI

@MainActor
final class TranscriptsModel: ObservableObject {
    @Published var items: [MeetingItem] = []
    @Published var error: String?
    @Published var loading = false

    func load() {
        items = TranscriptStore.localMeetings()
        guard DBConfig.isConfigured else {
            error = "Не настроена БД — открой «Настройки…»"
            return
        }
        loading = true
        error = nil
        Task {
            do {
                let keys = try await TranscriptStore.publishedKeys()
                for i in items.indices { items[i].published = keys.contains(items[i].id) }
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    func toggle(_ item: MeetingItem, to on: Bool) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].busy = true
        items[i].published = on          // оптимистично: реплика может отдать не сразу
        error = nil
        Task {
            do {
                if on { try await TranscriptStore.push(items[i]) }
                else { try await TranscriptStore.unpush(items[i]) }
            } catch {
                items[i].published = !on
                self.error = error.localizedDescription
            }
            items[i].busy = false
        }
    }
}

struct TranscriptsView: View {
    @StateObject private var model = TranscriptsModel()

    private static let human: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM, HH:mm"
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Обновить") { model.load() }.font(.caption)
            }
            Text("Тумблер = встреча в общей базе отдела. Выключишь — уберётся оттуда.")
                .font(.caption2).foregroundStyle(.secondary)

            if let e = model.error {
                Text(e).font(.caption).foregroundStyle(.red).lineLimit(3)
            }

            if model.items.isEmpty {
                Text("Записей пока нет").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.items) { item in
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.callout).lineLimit(1)
                                    Text(item.startedAt == .distantPast ? item.session.lastPathComponent
                                         : Self.human.string(from: item.startedAt))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if item.busy { ProgressView().controlSize(.small) }
                                Toggle("", isOn: Binding(
                                    get: { item.published },
                                    set: { model.toggle(item, to: $0) }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .disabled(!DBConfig.isConfigured)
                            }
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                .frame(height: 300)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onAppear { model.load() }
    }
}

final class TranscriptsController {
    private var panel: NSPanel?

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingView(rootView: TranscriptsView())
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Мои встречи"
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)
        p.center()
        p.isReleasedWhenClosed = false
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
}
