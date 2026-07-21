// Модель встречи из calendar_watch.py + запуск опроса календаря.

import Foundation

struct Meeting: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let start: String
    let minutesUntil: Double
    let meetingUrl: String?
    /// Кто приглашён — идёт в шапку транскрипта: метка «Собеседник 7» сама по
    /// себе бесполезна, список участников хотя бы даёт читателю контекст.
    let attendees: [String]
    /// Сколько подтвердили — ВЕРХНЯЯ граница числа говорящих для диаризации.
    let acceptedCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, start, attendees
        case minutesUntil = "minutes_until"
        case meetingUrl = "meeting_url"
        case acceptedCount = "accepted_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        start = try c.decode(String.self, forKey: .start)
        minutesUntil = try c.decode(Double.self, forKey: .minutesUntil)
        meetingUrl = try c.decodeIfPresent(String.self, forKey: .meetingUrl)
        attendees = try c.decodeIfPresent([String].self, forKey: .attendees) ?? []
        acceptedCount = try c.decodeIfPresent(Int.self, forKey: .acceptedCount) ?? 0
    }

    init(id: String, title: String, start: String, minutesUntil: Double,
         meetingUrl: String?, attendees: [String] = [], acceptedCount: Int = 0) {
        self.id = id; self.title = title; self.start = start
        self.minutesUntil = minutesUntil; self.meetingUrl = meetingUrl
        self.attendees = attendees; self.acceptedCount = acceptedCount
    }

    var url: URL? { meetingUrl.flatMap { URL(string: $0) } }

    /// Идёт ли встреча прямо сейчас (началась, но не закончилась).
    var isRunning: Bool { minutesUntil < 0 }

    var startsInText: String {
        let m = Int(minutesUntil.rounded())
        if m < -1 { return "идёт \(-m) мин" }
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
