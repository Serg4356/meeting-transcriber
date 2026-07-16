// Простой файловый лог — чтобы зависания/сбои были диагностируемы постфактум
// (NSLog от ad-hoc-приложения в системный лог не попадает).
// Файл: ~/Library/Logs/MeetingTranscriber.log

import Foundation

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("MeetingTranscriber.log")
    }()

    private static let queue = DispatchQueue(label: "mt.log")

    static func write(_ message: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "[\(fmt.string(from: Date()))] \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
