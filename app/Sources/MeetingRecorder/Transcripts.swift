// Список записанных встреч с тумблером «в общей базе».
// Один контрол закрывает три сценария: опубликовать сразу, опубликовать позже
// (передумал), убрать из базы (передумал обратно).

import AppKit
import CryptoKit
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

    static func transcriptText(_ session: URL) -> String {
        (try? String(contentsOf: session.appendingPathComponent("transcript.md"),
                     encoding: .utf8)) ?? ""
    }

    /// Отпечаток содержимого. Транскрипты меняются задним числом: библиотека
    /// голосов растёт, и «Собеседник 3» превращается в имя. Без хэша копия в
    /// базе тихо устаревает и при этом выглядит свежей.
    static func contentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Кто реально говорил — вытаскиваем из готового транскрипта.
    /// Даёт коллегам поиск «встречи, где говорил X» без чтения тела.
    static func speakers(in text: String) -> [String] {
        var found: Set<String> = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("**["), let close = line.range(of: "] "),
                  let colon = line.range(of: ":**") , close.upperBound < colon.lowerBound
            else { continue }
            let name = String(line[close.upperBound..<colon.lowerBound])
            if name != "Я" { found.insert(name) }
        }
        return found.sorted()
    }

    private static func metaList(_ session: URL, _ key: String) -> [String] {
        guard let d = try? Data(contentsOf: session.appendingPathComponent("meeting.json")),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let list = j[key] as? [String] else { return [] }
        return list
    }

    static func attendees(_ session: URL) -> [String] { metaList(session, "attendees") }

    /// Как звать автора записи в общей базе.
    ///
    /// Локально его реплики помечены «Я» — так удобно читать свой транскрипт.
    /// Но в общей базе «Я» у каждого свой: пятеро выгрузят встречи, и в каждой
    /// будет «Я» про разных людей. Поэтому при выгрузке подставляем имя.
    /// Берём его из календаря: это тот участник, которого нет среди «остальных».
    static func ownerName(_ session: URL) -> String {
        let others = Set(metaList(session, "others"))
        if let me = attendees(session).first(where: { !others.contains($0) }) { return me }
        return DBConfig.user.isEmpty ? "Автор записи" : DBConfig.user
    }

    /// Текст для общей базы: «Я» заменено на имя автора.
    /// Локальный файл не трогаем — там «Я» остаётся.
    static func bodyForSharing(_ session: URL) -> String {
        transcriptText(session)
            .replacingOccurrences(of: "] Я:**", with: "] \(ownerName(session)):**")
    }

    /// Что из моего уже лежит в базе: ключ → хэш опубликованной версии.
    /// Именно хэш, а не просто факт публикации — иначе не узнать, что версия
    /// на диске стала лучше той, что читают коллеги.
    static func publishedState() async throws -> [String: String] {
        // Спрашиваем саму таблицу, а не вью: её имя задаёт пользователь, и
        // угадывать имя вью подстановкой строки — прямой путь к мусору в запросе.
        let sql = "SELECT meeting_key, content_hash FROM \(DBConfig.table) FINAL "
            + "WHERE uploaded_by = currentUser() AND deleted = 0 FORMAT TSV"
        let text = try await CH.run(sql)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            if let k = parts.first { out[String(k)] = parts.count > 1 ? String(parts[1]) : "" }
        }
        return out
    }

    static func push(_ item: MeetingItem) async throws {
        try await insert(item: item, body: bodyForSharing(item.session), deleted: 0)
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
            "content_hash": deleted == 1 ? "" : contentHash(body),
            "attendees": attendees(item.session),
            "speakers": deleted == 1 ? [] : speakers(in: body),
        ]
        let json = try JSONSerialization.data(withJSONObject: row, options: [])
        let sql = "INSERT INTO \(DBConfig.table) (meeting_key, title, started_at, body, "
            + "deleted, content_hash, attendees, speakers) FORMAT JSONEachRow"
        _ = try await CH.run(sql, body: json)
    }
}

// MARK: - UI

@MainActor
final class TranscriptsModel: ObservableObject {
    @Published var items: [MeetingItem] = []
    @Published var error: String?
    @Published var loading = false
    @Published var staleUpdated = 0   // сколько устаревших версий догнали в базе

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
                let state = try await TranscriptStore.publishedState()
                for i in items.indices { items[i].published = state[items[i].id] != nil }
                await refreshStale(state)
            } catch {
                self.error = error.localizedDescription
            }
            loading = false
        }
    }

    /// Догоняем базу: если транскрипт на диске стал лучше (появились имена),
    /// обновляем УЖЕ опубликованные встречи. Согласие человека дано на встречу,
    /// а не на конкретную редакцию текста, поэтому уточнение имён не требует
    /// нового подтверждения. Неопубликованные не трогаем никогда.
    private func refreshStale(_ state: [String: String]) async {
        var updated = 0
        for item in items where item.published {
            let local = TranscriptStore.contentHash(TranscriptStore.bodyForSharing(item.session))
            guard let remote = state[item.id], !remote.isEmpty, remote != local else { continue }
            do {
                try await TranscriptStore.push(item)
                updated += 1
            } catch {
                self.error = "не удалось обновить «\(item.title)»: \(error.localizedDescription)"
            }
        }
        if updated > 0 { staleUpdated = updated }
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

            // Молчаливое обновление — плохо: человек должен видеть, что база
            // догнала диск (например, после того как голоса получили имена).
            if model.staleUpdated > 0 {
                Text("Обновлено в базе: \(model.staleUpdated) — появились имена спикеров")
                    .font(.caption).foregroundStyle(.green)
            }
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
