// Настройки: где хранить записи и учётка корпоративной БД для выгрузки транскриптов.
// Пароль живёт в Keychain, остальное — в UserDefaults. В файлы креды не пишем.

import AppKit
import Security
import SwiftUI

// MARK: - Keychain (только пароль)

enum Keychain {
    private static let service = "com.serg.meeting-transcriber.db"

    static func set(_ value: String, account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(account: String) -> String {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let d = item as? Data, let s = String(data: d, encoding: .utf8) else { return "" }
        return s
    }
}

// MARK: - Конфиг БД

enum DBConfig {
    private static let d = UserDefaults.standard

    static var host: String {
        get { d.string(forKey: "db.host") ?? "" }
        set { d.set(newValue, forKey: "db.host") }
    }
    static var user: String {
        get { d.string(forKey: "db.user") ?? "" }
        set { d.set(newValue, forKey: "db.user") }
    }
    /// Имя таблицы задаёт пользователь: оно зависит от политики его компании
    /// (и обычно меняется, когда временную схему заменяют на постоянную).
    /// Дефолта намеренно нет — в открытом коде не место внутренним именам схем.
    static var table: String {
        get { d.string(forKey: "db.table") ?? "" }
        set { d.set(newValue, forKey: "db.table") }
    }
    static var password: String {
        get { Keychain.get(account: "db.password") }
        set { Keychain.set(newValue, account: "db.password") }
    }

    static var isConfigured: Bool { !host.isEmpty && !user.isEmpty && !table.isEmpty }

    /// Полный URL HTTP-интерфейса ClickHouse. Порт по умолчанию 8123.
    static var url: URL? {
        var h = host.trimmingCharacters(in: .whitespaces)
        if !h.contains("://") { h = "http://" + h }
        if URL(string: h)?.port == nil { h += ":8123" }
        return URL(string: h)
    }
}

// MARK: - Клиент ClickHouse (HTTP)

enum CH {
    /// Выполняет запрос. Креды уходят заголовками, а не в URL — иначе пароль
    /// оседает в логах прокси и истории.
    static func run(_ sql: String, body: Data? = nil) async throws -> String {
        guard let base = DBConfig.url else { throw CHError.notConfigured }
        var req = URLRequest(url: base)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue(DBConfig.user, forHTTPHeaderField: "X-ClickHouse-User")
        req.setValue(DBConfig.password, forHTTPHeaderField: "X-ClickHouse-Key")
        if let body {
            var payload = Data((sql + "\n").utf8)
            payload.append(body)
            req.httpBody = payload
        } else {
            req.httpBody = Data(sql.utf8)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let text = String(data: data, encoding: .utf8) ?? ""
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw CHError.server(text.isEmpty ? "HTTP-ошибка" : String(text.prefix(300)))
        }
        return text
    }

    enum CHError: LocalizedError {
        case notConfigured
        case server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Не заданы хост и пользователь БД"
            case .server(let m): return m
            }
        }
    }
}

// MARK: - UI

/// Строка выбора папки. Вынесена отдельно, потому что папок теперь две
/// (записи и транскрипты), и дублировать одну и ту же вёрстку смысла нет.
private struct FolderRow: View {
    let title: String
    let hint: String
    let defaultPath: String
    @Binding var path: String

    private var shown: String { path.isEmpty ? defaultPath : path }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            Text(shown).font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled).lineLimit(1).truncationMode(.head)
            HStack(spacing: 8) {
                Button("Выбрать…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    p.directoryURL = URL(fileURLWithPath: shown)
                    if p.runModal() == .OK, let url = p.url { path = url.path }
                }
                Button("Открыть") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: shown))
                }
                if !path.isEmpty {
                    Button("По умолчанию") { path = "" }
                }
                Spacer()
            }
            .controlSize(.small)
            Text(hint).font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

struct SettingsView: View {
    @AppStorage(AppPaths.recordingsDirKey) private var recDir: String = ""
    @AppStorage(AppPaths.transcriptsDirKey) private var txtDir: String = ""
    @State private var host = DBConfig.host
    @State private var user = DBConfig.user
    @State private var table = DBConfig.table
    @State private var password = DBConfig.password
    @State private var checkResult: String?
    @State private var checking = false

    private var recPath: String {
        recDir.isEmpty ? AppPaths.defaultRecordingsDir.path : recDir
    }

    var body: some View {
        // Form/Section — стандартная для macOS группировка настроек;
        // ручные VStack+GroupBox выглядят самодельно и разъезжаются по отступам.
        Form {
            Section("Где хранить") {
                FolderRow(title: "Транскрипты",
                          hint: "Готовый текст встреч — его читаете вы",
                          defaultPath: AppPaths.defaultTranscriptsDir.path,
                          path: $txtDir)
                FolderRow(title: "Записи (аудио)",
                          hint: "Исходный звук, весит гигабайты — нужен для перепрогона",
                          defaultPath: AppPaths.defaultRecordingsDir.path,
                          path: $recDir)
                if legacyHasSessions {
                    Label("Старые записи остались в \(AppPaths.legacyRecordingsDir.path)",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption2).foregroundStyle(.orange)
                }
            }

            Section("Выгрузка в общую базу") {
                TextField("Хост", text: $host, prompt: Text("clickhouse.internal"))
                TextField("Пользователь", text: $user, prompt: Text("логин"))
                SecureField("Пароль", text: $password, prompt: Text("хранится в Keychain"))
                TextField("Таблица", text: $table, prompt: Text("схема.таблица"))
                HStack {
                    Button("Сохранить и проверить", action: saveAndCheck)
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    if let r = checkResult {
                        Text(r).font(.caption)
                            .foregroundStyle(r.hasPrefix("✓") ? .green : .red)
                            .lineLimit(2)
                    }
                }
                Text("Ничего не выгружается само — только встречи, которые вы отметите "
                     + "в «Мои встречи…».")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 640)
    }

    private var legacyHasSessions: Bool {
        let legacy = AppPaths.legacyRecordingsDir
        guard legacy.path != recPath,
              let items = try? FileManager.default.contentsOfDirectory(atPath: legacy.path)
        else { return false }
        return !items.isEmpty
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: recPath)
        if p.runModal() == .OK, let url = p.url { recDir = url.path }
    }

    private func saveAndCheck() {
        DBConfig.host = host
        DBConfig.user = user
        DBConfig.table = table
        DBConfig.password = password
        checking = true
        checkResult = nil
        Task {
            do {
                let who = try await CH.run("SELECT currentUser()")
                checkResult = "✓ подключено: \(who.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                checkResult = "✗ \(error.localizedDescription)"
            }
            checking = false
        }
    }
}

final class SettingsController {
    private var panel: NSPanel?

    func show() {
        if let panel { panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        let hosting = NSHostingView(rootView: SettingsView())
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.title = "Meeting Transcriber — настройки"
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)
        p.center()
        p.isReleasedWhenClosed = false
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
}
