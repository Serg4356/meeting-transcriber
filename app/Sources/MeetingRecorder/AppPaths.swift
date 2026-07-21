// Единая точка правды по путям проекта. Чтобы приложение работало у любого,
// корень проекта берётся из Info.plist (ключ MTProjectRoot вписывает
// package_app.sh при сборке = папка клонированного репозитория), либо из env
// MT_PROJECT_ROOT (для `swift run`), либо дефолт.

import Foundation

enum AppPaths {
    static var projectRoot: String {
        // 1) вписан при сборке (package_app.sh → Info.plist)
        if let p = Bundle.main.object(forInfoDictionaryKey: "MTProjectRoot") as? String,
           !p.isEmpty {
            return (p as NSString).expandingTildeInPath
        }
        // 2) для `swift run` — переменная окружения
        if let e = ProcessInfo.processInfo.environment["MT_PROJECT_ROOT"], !e.isEmpty {
            return (e as NSString).expandingTildeInPath
        }
        // 3) ищем вверх от бинарника папку с transcribe.py (корень репозитория)
        var dir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<7 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("transcribe.py").path) {
                return dir.path
            }
            dir = dir.deletingLastPathComponent()
        }
        return FileManager.default.currentDirectoryPath
    }

    static var python: String { "\(projectRoot)/.venv/bin/python" }

    /// Окружение для дочерних процессов. Приложение, запущенное из Finder,
    /// получает урезанный PATH без /opt/homebrew/bin → Python не находит ffmpeg.
    /// Дополняем PATH путями Homebrew (Apple Silicon + Intel).
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let brew = "/opt/homebrew/bin:/usr/local/bin"
        let base = env["PATH"].map { $0.isEmpty ? nil : $0 } ?? nil
        env["PATH"] = base.map { "\(brew):\($0)" } ?? "\(brew):/usr/bin:/bin:/usr/sbin:/sbin"
        return env
    }

    /// Куда складываем записи встреч.
    ///
    /// ВАЖНО: пользовательские данные не должны лежать внутри папки с кодом.
    /// Раньше это был `<projectRoot>/mac-capture/recordings`, то есть архив
    /// записей оказывался там, откуда ставили приложение (например в Загрузках),
    /// и умирал вместе с чисткой папки или переустановкой.
    /// Теперь — видимая папка в Documents, меняется в настройках.
    static let recordingsDirKey = "recordingsDir"

    static var defaultRecordingsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Meeting Transcriber/Записи")
    }

    static var recordingsDir: URL {
        if let p = UserDefaults.standard.string(forKey: recordingsDirKey), !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return defaultRecordingsDir
    }

    static func setRecordingsDir(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: recordingsDirKey)
    }

    /// Прежнее место внутри папки с кодом — показываем в настройках, если там
    /// остались старые сессии, чтобы человек не потерял архив.
    static var legacyRecordingsDir: URL {
        URL(fileURLWithPath: "\(projectRoot)/mac-capture/recordings")
    }

    static func script(_ name: String) -> String { "\(projectRoot)/\(name)" }
}
