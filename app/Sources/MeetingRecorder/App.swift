// Menu-bar приложение: запись встречи + транскрипт по кнопке.
// Захват — Recorder (ScreenCaptureKit). Транскрипт — локальный transcribe.py
// через venv (дёргаем как процесс).

import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    // Фаза — ТОЛЬКО про захват звука. Расшифровка живёт отдельно (bgJobs) и
    // никогда не блокирует старт следующей записи: встречи бывают стык в стык.
    enum Phase { case idle, recording }

    @Published var phase: Phase = .idle
    @Published var bgJobs: Int = 0          // сколько расшифровок крутится фоном
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
    private let settings = SettingsController()
    private let transcripts = TranscriptsController()

    func openSettings() { settings.show() }
    func openTranscripts() { transcripts.show() }
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
        case .recording: return "record.circle.fill"
        case .idle: return bgJobs > 0 ? "waveform" : "record.circle"
        }
    }

    var isRecording: Bool { phase == .recording }

    private var baseDir: URL { AppPaths.recordingsDir }

    func toggleRecording() {
        switch phase {
        case .idle: startRecording()
        case .recording: stopRecording()
        }
    }

    /// Встреча, которая идёт прямо сейчас (по календарю).
    private func currentMeeting() -> Meeting? {
        guard let m = nextMeeting, m.minutesUntil <= 2 else { return nil }
        return m
    }

    /// Кладём рядом с записью данные встречи из календаря — транскрайбер возьмёт
    /// оттуда название, список участников (в шапку) и верхнюю границу числа
    /// говорящих для диаризации.
    private func writeMeetingMeta(session: URL) {
        guard let m = currentMeeting() else { return }
        let meta: [String: Any] = ["title": activeMeetingTitle ?? m.title,
                                   "attendees": m.attendees,
                                   "accepted_count": m.acceptedCount]
        guard let data = try? JSONSerialization.data(withJSONObject: meta,
                                                     options: [.prettyPrinted]) else { return }
        try? data.write(to: session.appendingPathComponent("meeting.json"))
    }

    /// Название встречи, которая идёт прямо сейчас (для имени файла при ручной записи).
    private func currentMeetingTitle() -> String? {
        return currentMeeting()?.title
    }

    func startRecording(title: String? = nil) {
        lastTranscript = nil
        activeMeetingTitle = title ?? currentMeetingTitle()
        Task {
            do {
                let session = try await recorder.start(baseDir: baseDir)
                lastSession = session
                writeMeetingMeta(session: session)
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
        // Контекст встречи забираем в локальные переменные и СРАЗУ освобождаем слоты —
        // следующая запись может стартовать, пока эта ещё расшифровывается.
        let session = lastSession
        let title = activeMeetingTitle
        let proc = liveProc
        lastSession = nil
        activeMeetingTitle = nil
        liveProc = nil
        Task {
            do {
                try await recorder.stop()
                Log.write("STOP done — capture torn down")
            } catch {
                Log.write("STOP FAILED: \(error)")
                status = "Ошибка остановки: \(error.localizedDescription)"
            }
            phase = .idle   // захват свободен — новую встречу можно писать немедленно
            if let session {
                finalize(session: session, title: title, proc: proc)
            } else {
                updateIdleStatus()
            }
        }
    }

    /// Фоновая финализация: маркер .stopped → ждём live-воркер (текст уже накоплен
    /// по чанкам, остаётся диаризация) → сохраняем в Documents.
    /// НЕ трогает `phase`: в это время уже может идти запись следующей встречи.
    private func finalize(session: URL, title: String?, proc: Process?) {
        bgJobs += 1
        updateIdleStatus()
        // название встречи кладём рядом с записью — иначе в списке «Мои встречи»
        // и в общей базе будут голые таймстемпы вместо человеческих имён.
        if let title, !title.isEmpty {
            try? title.write(to: session.appendingPathComponent("title.txt"),
                             atomically: true, encoding: .utf8)
        }
        // маркер остановки для live_transcribe.py
        try? "stop".write(to: session.appendingPathComponent(".stopped"),
                          atomically: true, encoding: .utf8)
        Task {
            let ok = await Task.detached { () -> Bool in
                if let proc { proc.waitUntilExit(); return proc.terminationStatus == 0 }
                // воркера нет (напр. запущено не тем путём) — фолбэк на whole-file
                return TranscribeRunner.run(session: session).isSuccess
            }.value
            if ok || FileManager.default.fileExists(
                atPath: session.appendingPathComponent("transcript.md").path) {
                lastTranscript = TranscribeRunner.saveToDocuments(session: session, title: title)
                // Пополняем библиотеку голосов на свежих данных — со временем
                // приложение начинает отличать владельца от эха само.
                TranscribeRunner.updateVoiceLibrary()
            } else {
                Log.write("TRANSCRIBE FAILED: \(session.lastPathComponent)")
            }
            bgJobs -= 1
            updateIdleStatus()
        }
    }

    /// Статус вне записи: показываем, сколько расшифровок ещё крутится фоном.
    private func updateIdleStatus() {
        guard phase != .recording else { return }
        if bgJobs > 0 {
            status = bgJobs == 1 ? "Фоном: расшифровка…" : "Фоном: расшифровок \(bgJobs)"
        } else {
            status = lastTranscript.map { "Готово: \($0.lastPathComponent)" } ?? "Готов к записи"
        }
    }
}

enum TranscribeRunner {
    enum Outcome {
        case success
        case failure(String)
        var isSuccess: Bool { if case .success = self { return true }; return false }
    }

    /// Папка с готовыми транскриптами (человекочитаемая). Меняется в настройках.
    static var transcriptsDir: URL { AppPaths.transcriptsDir }

    /// Пополняет библиотеку голосов: определяет, какой голос принадлежит
    /// владельцу этого Mac, и вносит его под именем из календаря.
    ///
    /// Нужно, чтобы отличать реплики владельца от собеседников, попавших в
    /// микрофон из колонок. Запускается после расшифровки, в фоне и с низким
    /// приоритетом: диаризация нескольких встреч — дорогая операция, но она
    /// кэшируется, поэтому каждый следующий запуск считает только новую запись.
    static func updateVoiceLibrary() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/taskpolicy")
        // Папку записей передаём явно: пользователь мог сменить её в настройках,
        // а дефолт внутри скрипта об этом не знает.
        proc.arguments = ["-b", AppPaths.python, AppPaths.script("owner.py"),
                          "--enroll", "--dir", AppPaths.recordingsDir.path]
        proc.currentDirectoryURL = URL(fileURLWithPath: AppPaths.projectRoot)
        proc.environment = AppPaths.childEnvironment
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch {
            Log.write("VOICE-LIB start failed: \(error)")
            return
        }
        DispatchQueue.global().async {
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            proc.waitUntilExit()
            let tail = String(data: data, encoding: .utf8)?
                .split(separator: "\n").suffix(2).joined(separator: " | ") ?? ""
            Log.write("VOICE-LIB done (код \(proc.terminationStatus)): \(tail)")
        }
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

/// Однородная строка меню: иконка + название, кликается вся ширина.
/// Раньше нижние пункты были разнокалиберными кнопками — из-за этого панель
/// выглядела собранной из случайных частей, а «Настройки…» терялись в тексте.
private struct MenuRow: View {
    let title: String
    let systemImage: String
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 16)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppLogo(size: 20)
                Text("Meeting Transcriber").font(.headline)
                Spacer()
            }

            // Одно главное действие панели — и оно единственное акцентное.
            // Фоновая расшифровка его НЕ блокирует: встречи бывают стык в стык.
            Button(action: model.toggleRecording) {
                Label(model.isRecording ? "Остановить запись" : "Начать запись",
                      systemImage: model.isRecording ? "stop.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(model.isRecording ? .red : .accentColor)

            // Статус — следствие действия, поэтому стоит ПОД кнопкой, а не над.
            HStack(spacing: 6) {
                if model.bgJobs > 0 { ProgressView().controlSize(.small) }
                Text(model.status)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let nm = model.nextMeeting {
                Divider()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Следующая встреча").font(.caption2).foregroundStyle(.tertiary)
                    Text(nm.title).font(.caption).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(nm.startsInText).font(.caption2).foregroundStyle(.secondary)
                        Button("проверить напоминание") { model.testPopup() }
                            .buttonStyle(.link).font(.caption2)
                    }
                }
            }

            Divider()

            // Все переходы — одинаковыми строками. «Последний транскрипт» тоже
            // строка, а не вторая большая кнопка: раньше он визуально дублировал
            // «Папку транскриптов», хотя открывает конкретный файл, а не папку.
            VStack(alignment: .leading, spacing: 1) {
                if let dest = model.lastTranscript {
                    MenuRow(title: "Открыть последний транскрипт",
                            systemImage: "doc.text") {
                        NSWorkspace.shared.activateFileViewerSelecting([dest])
                    }
                }
                MenuRow(title: "Мои встречи…", systemImage: "list.bullet") {
                    model.openTranscripts()
                }
                MenuRow(title: "Все транскрипты в Finder", systemImage: "folder") {
                    NSWorkspace.shared.open(AppPaths.transcriptsDir)
                }
                MenuRow(title: "Настройки…", systemImage: "gearshape") {
                    model.openSettings()
                }
            }

            Divider()

            Toggle("Запускать при входе", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }))
                .toggleStyle(.checkbox)
                .font(.caption)
                .padding(.horizontal, 6)

            MenuRow(title: "Выход", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 290)
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
