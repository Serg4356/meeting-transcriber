// Модель встречи из calendar_watch.py + запуск опроса календаря.

import Foundation

struct Meeting: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let start: String
    let minutesUntil: Double
    let meetingUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, title, start
        case minutesUntil = "minutes_until"
        case meetingUrl = "meeting_url"
    }

    var url: URL? { meetingUrl.flatMap { URL(string: $0) } }

    var startsInText: String {
        let m = Int(minutesUntil.rounded())
        if m <= 0 { return "начинается сейчас" }
        if m == 1 { return "через 1 минуту" }
        if m < 60 { return "через \(m) мин" }
        return "через \(m / 60) ч \(m % 60) мин"
    }
}

enum CalendarRunner {
    static func fetch(withinMinutes: Int = 60) -> [Meeting] {
        let project = AppPaths.projectRoot

        // Нет кредов — календарь не подключён, тихо возвращаем пусто.
        guard FileManager.default.fileExists(atPath: "\(project)/credentials.json"),
              FileManager.default.fileExists(atPath: "\(project)/.gcal_token.json")
        else { return [] }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: AppPaths.python)
        proc.arguments = [AppPaths.script("calendar_watch.py"),
                          "--upcoming", "--within", String(withinMinutes)]
        proc.currentDirectoryURL = URL(fileURLWithPath: project)
        proc.environment = AppPaths.childEnvironment
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return []
        }

        // Дренируем stderr параллельно — иначе полный pipe подвешивает подпроцесс
        // (и наш тред) навсегда.
        DispatchQueue.global().async {
            _ = try? errPipe.fileHandleForReading.readToEnd()
        }
        // Сторож: если опрос завис (сеть/OAuth) — убиваем подпроцесс.
        let watchdog = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)

        let data = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        proc.waitUntilExit()
        watchdog.cancel()
        guard proc.terminationStatus == 0 else { return [] }
        return (try? JSONDecoder().decode([Meeting].self, from: data)) ?? []
    }
}
