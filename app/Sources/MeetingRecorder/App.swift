// Menu-bar приложение: запись встречи + транскрипт по кнопке.
// Захват — Recorder (ScreenCaptureKit). Транскрипт — локальный transcribe.py
// через venv (дёргаем как процесс).

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    enum Phase { case idle, recording, transcribing }

    @Published var phase: Phase = .idle
    @Published var status: String = "Готов к записи"
    @Published var lastTranscript: URL?
    @Published var nextMeeting: Meeting?
    @Published var elapsed: String = ""
    @Published var launchAtLogin: Bool = false
    @Published var isPaused: Bool = false
    private var pauseStart: Date?

    private let recorder = Recorder()
    private var lastSession: URL?
    private var liveProc: Process?
    private var recStart: Date?
    private var recTimer: Timer?
    private var activeMeetingTitle: String?

    // --- Запись/календарь UI ---
    private let recControl = RecordingControlController()
    private let popup = MeetingPopupController()
    private var calendarTimer: Timer?
    private var alertedIDs = Set<String>()
    private let leadMinutes = 1.0  // за сколько минут до встречи показать всплывашку

    init() {
        refreshLoginStatus()
        startWatchingCalendar()
    }

    /// Инициализация для рендера скриншотов: без таймеров/подпроцессов, с демо-данными.
    init(preview: Bool) {
        status = "Готов к записи"
        elapsed = "12:34"
        nextMeeting = Meeting(id: "demo", title: "Weekly Sync — Product",
                              start: "2026-07-16T15:00:00+05:00",
                              minutesUntil: 3, meetingUrl: "https://zoom.us/j/123")
        lastTranscript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Транскрипты встреч/2026-07-16 Weekly Sync.md")
    }

    func refreshLoginStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "Автозагрузка недоступна (запусти собранное приложение, не swift run)"
        }
        refreshLoginStatus()
    }

    func startWatchingCalendar() {
        pollCalendar()
        calendarTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCalendar() }
        }
    }

    func pollCalendar() {
        // Во время записи НЕ дёргаем Python-опрос календаря: за длинную встречу
        // это сотни спавнов подпроцессов, они накапливаются и подвешивают аппку.
        if phase != .idle { return }
        Task {
            let meetings = await Task.detached { CalendarRunner.fetch(withinMinutes: 1440) }.value
            nextMeeting = meetings.first
            for m in meetings where m.minutesUntil <= leadMinutes && !alertedIDs.contains(m.id) {
                alertedIDs.insert(m.id)
                presentPopup(m)
                break
            }
        }
    }

    /// Ручной показ всплывашки для следующей встречи (проверка UI без ожидания).
    func testPopup() {
        if let m = nextMeeting { presentPopup(m) }
    }

    private func presentPopup(_ meeting: Meeting) {
        popup.show(
            meeting: meeting,
            onJoinRecord: { [weak self] in
                if let url = meeting.url { NSWorkspace.shared.open(url) }
                self?.startRecording(title: meeting.title)
            }
        )
    }

    var menuIcon: String {
        switch phase {
        case .idle: return "record.circle"
        case .recording: return "record.circle.fill"
        case .transcribing: return "waveform"
        }
    }

    var isRecording: Bool { phase == .recording }

    private var baseDir: URL { AppPaths.recordingsDir }

    func toggleRecording() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .transcribing: break
        }
    }

    /// Название встречи, которая идёт прямо сейчас (для имени файла при ручной записи).
    private func currentMeetingTitle() -> String? {
        guard let m = nextMeeting, m.minutesUntil <= 2 else { return nil }
        return m.title
    }

    func startRecording(title: String? = nil) {
        lastTranscript = nil
        activeMeetingTitle = title ?? currentMeetingTitle()
        Task {
            do {
                let session = try await recorder.start(baseDir: baseDir)
                lastSession = session
                phase = .recording
                startElapsedTimer()
                recControl.show(model: self) { [weak self] in self?.requestStop() }
                // Live-транскрипция во время записи: воркер читает растущие .caf.
                liveProc = TranscribeRunner.startLive(session: session)
                Log.write("REC start → \(session.lastPathComponent)")
            } catch {
                phase = .idle
                status = "Ошибка записи: \(error.localizedDescription)"
                Log.write("REC start FAILED: \(error)")
            }
        }
    }

    private func startElapsedTimer() {
        recStart = Date()
        elapsed = "0:00"
        recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.recStart, !self.isPaused else { return }
                let s = Int(Date().timeIntervalSince(start))
                self.elapsed = String(format: "%d:%02d", s / 60, s % 60)
                self.status = "● Идёт запись  \(self.elapsed)"
            }
        }
    }

    private func stopElapsedTimer() {
        recTimer?.invalidate()
        recTimer = nil
        recStart = nil
        elapsed = ""
        isPaused = false
        pauseStart = nil
    }

    /// Остановка записи извне (плавающая кнопка «Стоп»).
    func requestStop() {
        if phase == .recording { stopRecording() }
    }

    /// Пауза/продолжение записи. Во время паузы звук не пишется и таймер стоит —
    /// пустое ожидание не попадает в транскрипт.
    func togglePause() {
        guard phase == .recording else { return }
        isPaused.toggle()
        recorder.setPaused(isPaused)
        if isPaused {
            pauseStart = Date()
            status = "⏸ Пауза  \(elapsed)"
        } else {
            if let ps = pauseStart, let rs = recStart {
                recStart = rs.addingTimeInterval(Date().timeIntervalSince(ps))
            }
            pauseStart = nil
        }
    }

    private func stopRecording() {
        stopElapsedTimer()
        recControl.close()
        Log.write("STOP requested")
        Task {
            do {
                try await recorder.stop()
                Log.write("STOP done — capture torn down")
                if let session = lastSession {
                    finalize(session: session)
                } else {
                    phase = .idle
                }
            } catch {
                phase = .idle
                status = "Ошибка остановки: \(error.localizedDescription)"
            }
        }
    }

    /// После «Стоп»: ставим маркер, ждём финализацию live-воркера (текст уже
    /// накоплен по чанкам — остаётся диаризация), сохраняем в Documents.
    private func finalize(session: URL) {
        phase = .transcribing
        status = "Финализирую (диаризация)…"
        // маркер остановки для live_transcribe.py
        try? "stop".write(to: session.appendingPathComponent(".stopped"),
                          atomically: true, encoding: .utf8)
        let proc = liveProc
        Task {
            let ok = await Task.detached { () -> Bool in
                if let proc { proc.waitUntilExit(); return proc.terminationStatus == 0 }
                // воркера нет (напр. запущено не тем путём) — фолбэк на whole-file
                return TranscribeRunner.run(session: session).isSuccess
            }.value
            liveProc = nil
            if ok || FileManager.default.fileExists(
                atPath: session.appendingPathComponent("transcript.md").path) {
                let dest = TranscribeRunner.saveToDocuments(session: session,
                                                            title: activeMeetingTitle)
                lastTranscript = dest
                status = dest.map { "Готово: \($0.lastPathComponent)" }
                    ?? "Готово (файл в папке записи)"
            } else {
                status = "Ошибка транскрипции (см. лог)"
            }
            phase = .idle
        }
    }
}

enum TranscribeRunner {
    enum Outcome {
        case success
        case failure(String)
        var isSuccess: Bool { if case .success = self { return true }; return false }
    }

    /// Папка с готовыми транскриптами (человекочитаемая).
    static var transcriptsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/Транскрипты встреч")
    }

    /// Запускает live_transcribe.py на время записи (читает растущие .caf).
    /// Возвращает процесс — на «Стоп» ему ставят маркер .stopped и ждут выхода.
    static func startLive(session: URL) -> Process? {
        let proc = Process()
        // Background-QoS: live-транскрипция во время встречи не должна тормозить
        // передний план (Zoom и т.п.). `taskpolicy -b` → efficiency-ядра, низкий
        // приоритет CPU/GPU. Модель под железо подбирает сам live_transcribe.py.
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        proc.arguments = ["-b", AppPaths.python,
                          AppPaths.script("live_transcribe.py"), session.path]
        proc.currentDirectoryURL = URL(fileURLWithPath: AppPaths.projectRoot)
        proc.environment = AppPaths.childEnvironment
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        do { try proc.run() } catch { return nil }
        // Дренируем вывод, иначе полный pipe подвесит воркер.
        for pipe in [outPipe, errPipe] {
            DispatchQueue.global().async { _ = try? pipe.fileHandleForReading.readToEnd() }
        }
        return proc
    }

    static func run(session: URL) -> Outcome {
        let python = AppPaths.python
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = [AppPaths.script("transcribe.py"), session.path]
        proc.currentDirectoryURL = URL(fileURLWithPath: AppPaths.projectRoot)
        proc.environment = AppPaths.childEnvironment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return .failure("Не удалось запустить \(python): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let transcriptFile = session.appendingPathComponent("transcript.md")
        if FileManager.default.fileExists(atPath: transcriptFile.path) {
            return .success
        }
        let log = String(data: data, encoding: .utf8) ?? ""
        return .failure("транскрипт не создан (код \(proc.terminationStatus)): \(log.suffix(160))")
    }

    /// Копирует transcript.md сессии в ~/Documents/Транскрипты встреч/<имя>.md.
    /// Имя: "<дата время> — <название встречи>.md" (или по таймстампу, если встречи нет).
    static func saveToDocuments(session: URL, title: String?) -> URL? {
        let src = session.appendingPathComponent("transcript.md")
        guard FileManager.default.fileExists(atPath: src.path) else { return nil }
        let dir = transcriptsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // session.lastPathComponent = "2026-07-16_14-30-05" → "2026-07-16 14-30"
        let stamp = session.lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .prefix(2)
            .joined(separator: " ")
        var name = stamp
        if let title, !title.isEmpty {
            name += " — " + sanitizeFilename(title)
        }
        let dest = dir.appendingPathComponent(name + ".md")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.copyItem(at: src, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    private static func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|\n\r\t")
        let cleaned = s.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80))
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                AppLogo(size: 22)
                Text("Meeting Transcriber").font(.headline)
            }

            HStack(spacing: 6) {
                if model.phase == .transcribing {
                    ProgressView().controlSize(.small)
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: model.toggleRecording) {
                Label(model.isRecording ? "Стоп" : "Запись",
                      systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(model.phase == .transcribing)

            if let dest = model.lastTranscript {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                } label: {
                    Label("Показать транскрипт в Finder", systemImage: "doc.text.magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
            }

            if let nm = model.nextMeeting {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Следующая встреча").font(.caption2).foregroundStyle(.secondary)
                    Text(nm.title).font(.caption).lineLimit(1)
                    Text(nm.startsInText).font(.caption2).foregroundStyle(.secondary)
                }
                Button("Проверить напоминание") { model.testPopup() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }

            Button {
                NSWorkspace.shared.open(TranscribeRunner.transcriptsDir)
            } label: {
                Label("Папка транскриптов", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderless)
            .font(.caption)

            Divider()
            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)

            Button("Выход") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 280)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Рендер скриншотов для README — NSApp уже готов, SF Symbols рисуются.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-shots"), i + 1 < args.count {
            RenderShots.run(outputDir: args[i + 1])
            return
        }
        NSApp.setActivationPolicy(.accessory)  // без иконки в Dock — только строка меню
    }
}

@main
struct MeetingRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel()


    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            if model.isRecording {
                Image(systemName: "record.circle.fill")
                Text("REC \(model.elapsed)")
            } else {
                Image(systemName: model.menuIcon)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
