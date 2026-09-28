// Настройки: где хранить записи и учётка корпоративной БД для выгрузки транскриптов.
// Секреты — в файле 0600 рядом с voiceprints.json, остальное — в UserDefaults.
// Раньше секреты жили в Keychain, но его ACL привязан к подписи бинаря:
// каждая пересборка (self-signed cert без trust-анкора) ломала доверие и
// приложение спрашивало пароль связки на КАЖДОЕ чтение. Файл этим не страдает.

import AppKit
import Security
import SwiftUI

// MARK: - Секреты (токен сервиса, ключ ЛЛМ)

enum Secrets {
    private static let service = "com.serg.meeting-transcriber.db"
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Meeting Transcriber/secrets.json")

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let d = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return d
    }

    static func set(_ value: String, account: String) {
        var d = load()
        if value.isEmpty { d.removeValue(forKey: account) } else { d[account] = value }
        guard let data = try? JSONEncoder().encode(d) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    static func get(account: String) -> String {
        if let v = load()[account] { return v }
        // Миграция из Keychain: одно чтение (последний запрос пароля) → в файл.
        let legacy = keychainGet(account: account)
        if !legacy.isEmpty { set(legacy, account: account) }
        return legacy
    }

    private static func keychainGet(account: String) -> String {
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

// MARK: - Конфиг сервиса выгрузки

/// Выгрузка идёт через HTTP-сервис выгрузки, НЕ напрямую в БД:
/// у пользователя в приложении только личный токен (SSO-страница сервиса),
/// креды базы живут на сервере. uploaded_by штампует сервис из токена.
enum ServiceConfig {
    private static let d = UserDefaults.standard

    static var url: String {
        get { d.string(forKey: "svc.url") ?? "" }
        set { d.set(newValue, forKey: "svc.url") }
    }
    static var token: String {
        get { Secrets.get(account: "svc.token") }
        set { Secrets.set(newValue, account: "svc.token") }
    }
    static var isConfigured: Bool { !url.isEmpty && !token.isEmpty }
}

// MARK: - Конфиг ЛЛМ (локальная очистка + саммари)

enum LLMConfig {
    private static let d = UserDefaults.standard
    /// По нему transcribe.py чистит транскрипт и делает саммари на этой машине.
    static var key: String {
        get { Secrets.get(account: "llm.key") }
        set { Secrets.set(newValue, account: "llm.key") }
    }
    static var model: String {
        get { d.string(forKey: "llm.model") ?? "" }
        set { d.set(newValue, forKey: "llm.model") }
    }
    /// Пусто → Anthropic. Задан (например https://api.openai.com/v1 или
    /// http://localhost:11434/v1) → OpenAI-совместимый endpoint, модель обязательна.
    static var baseURL: String {
        get { d.string(forKey: "llm.baseURL") ?? "" }
        set { d.set(newValue, forKey: "llm.baseURL") }
    }
    static var isConfigured: Bool { !key.isEmpty }
}

// MARK: - Клиент сервиса выгрузки (HTTP + Bearer)

enum Service {
    /// GET (json == nil) или POST c JSON-телом. Токен — заголовком, не в URL.
    static func call(_ path: String, json: [String: Any]? = nil) async throws -> Data {
        guard ServiceConfig.isConfigured,
              let url = URL(string: ServiceConfig.url.trimmingCharacters(in: .whitespaces)
                                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                            + path)
        else { throw ServiceError.notConfigured }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("Bearer \(ServiceConfig.token)", forHTTPHeaderField: "Authorization")
        if let json {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            if code == 401 { throw ServiceError.server("токен не принят — получите новый в настройках") }
            throw ServiceError.server(text.isEmpty ? "HTTP \(code)" : String(text.prefix(300)))
        }
        return data
    }

    enum ServiceError: LocalizedError {
        case notConfigured
        case server(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Не заданы URL сервиса и токен"
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
    @State private var svcUrl = ServiceConfig.url
    @State private var svcToken = ServiceConfig.token
    @State private var llmKey = LLMConfig.key
    @State private var llmModel = LLMConfig.model
    @State private var llmBase = LLMConfig.baseURL
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
                TextField("URL сервиса", text: $svcUrl,
                          prompt: Text("https://meetings.example.internal"))
                SecureField("Токен", text: $svcToken, prompt: Text("хранится локально (0600)"))
                HStack {
                    Button("Получить токен…") {
                        if let u = URL(string: svcUrl.trimmingCharacters(in: .whitespaces)) {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    Button("Сохранить и проверить", action: saveAndCheck)
                        .disabled(checking)
                    if checking { ProgressView().controlSize(.small) }
                    if let r = checkResult {
                        Text(r).font(.caption)
                            .foregroundStyle(r.hasPrefix("✓") ? .green : .red)
                            .lineLimit(2)
                    }
                }
                Text("Личные креды БД не нужны: войдите на странице сервиса через корп-SSO, "
                     + "скопируйте токен сюда. Само ничего не уходит — после обработки встречи "
                     + "приложение спросит (уйдут только очищенная версия и саммари, не сырой).")
                    .font(.caption2).foregroundStyle(.secondary)
            }

            Section("Очистка и саммари (локально)") {
                SecureField("Ключ ЛЛМ", text: $llmKey, prompt: Text("хранится локально (0600)"))
                TextField("Модель", text: $llmModel, prompt: Text("claude-sonnet-5"))
                TextField("Base URL (не-Claude)", text: $llmBase,
                          prompt: Text("пусто = Anthropic"))
                Text("Транскрипты чистятся и саммаризируются на вашем Маке этим ключом — "
                     + "звук и текст никуда не уходят. Без ключа остаётся только сырой транскрипт. "
                     + "Другая ЛЛМ (OpenAI, DeepSeek, Ollama…): укажите её OpenAI-совместимый "
                     + "Base URL (например http://localhost:11434/v1) и имя модели — обязательно.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Сохранение — сразу при вводе: раньше ключ ЛЛМ записывался только по
            // кнопке «Сохранить и проверить» из секции БД, и без неё молча терялся.
            .onChange(of: llmKey) { LLMConfig.key = llmKey.trimmingCharacters(in: .whitespacesAndNewlines) }
            .onChange(of: llmModel) { LLMConfig.model = llmModel.trimmingCharacters(in: .whitespacesAndNewlines) }
            .onChange(of: llmBase) { LLMConfig.baseURL = llmBase.trimmingCharacters(in: .whitespacesAndNewlines) }

            Section("О программе") {
                LabeledContent("Версия", value: Self.versionLine)
                Text("Если после обновления настройки выглядят по-старому — "
                     + "перезапустите приложение: окно могло остаться от старого процесса.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
    }

    /// «2026.08.07 (сборка ae4b36a)» — из Info.plist, штампует package_app.sh.
    /// Запуск из swift run (без бандла) — «dev».
    static var versionLine: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        guard let v, let b else { return "dev" }
        return "\(v) (сборка \(b))"
    }

    /// Есть ли в старом месте РЕАЛЬНЫЕ записи. Скрытые файлы не считаем:
    /// одного забытого .DS_Store хватало, чтобы вечно показывать предупреждение
    /// про «старые записи», которых там давно нет.
    private var legacyHasSessions: Bool {
        let legacy = AppPaths.legacyRecordingsDir
        guard legacy.path != recPath,
              let items = try? FileManager.default.contentsOfDirectory(atPath: legacy.path)
        else { return false }
        return items.contains { !$0.hasPrefix(".") }
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
        ServiceConfig.url = svcUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        ServiceConfig.token = svcToken.trimmingCharacters(in: .whitespacesAndNewlines)
        checking = true
        checkResult = nil
        Task {
            do {
                _ = try await Service.call("/api/state")
                checkResult = "✓ подключено, токен принят"
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
        let hosting = NSHostingView(rootView: SettingsView()
            .tint(Color.brandCream.opacity(0.85)))
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        p.appearance = NSAppearance(named: .darkAqua)  // бренд TERMINUS — тёмный
        p.title = "Terminus — настройки"
        p.contentView = hosting
        p.setContentSize(hosting.fittingSize)
        p.center()
        p.isReleasedWhenClosed = false
        p.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel = p
    }
}
