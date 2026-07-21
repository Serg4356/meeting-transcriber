// Скриншоты интерфейсов для README. Лого — через ImageRenderer (кастомная
// отрисовка, рисуется корректно). UI-экраны (с системными иконками/кнопками)
// ImageRenderer рисует плохо → показываем их живыми окнами и снимаем
// системным screencapture (нужно разрешение Screen Recording — у приложения есть).
//
// Запуск: MeetingTranscriber --render-shots <output-dir>

import AppKit
import SwiftUI

enum RenderShots {
    @MainActor static var heldWindows: [(String, NSWindow)] = []
    @MainActor static var gifFrame = 0
    // Настоящие пути пользователя, подменённые на время рендера.
    // Восстанавливаем ПЕРЕД выходом: рендер асинхронный, и defer
    // отработал бы раньше, чем снимутся кадры (так и было).
    @MainActor static var savedRecordingsDir: String?
    @MainActor static var savedTranscriptsDir: String?

    @MainActor
    static func restorePaths() {
        let d = UserDefaults.standard
        if let v = savedRecordingsDir { d.set(v, forKey: AppPaths.recordingsDirKey) }
        else { d.removeObject(forKey: AppPaths.recordingsDirKey) }
        if let v = savedTranscriptsDir { d.set(v, forKey: AppPaths.transcriptsDirKey) }
        else { d.removeObject(forKey: AppPaths.transcriptsDirKey) }
    }

    @MainActor
    static func run(outputDir: String) {
        let dir = URL(fileURLWithPath: outputDir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // 1) Лого — ImageRenderer (без системных символов, рисуется чисто).
        renderLogo(to: dir.appendingPathComponent("logo.png"))

        // Скриншоты уходят в публичный репозиторий, а окно настроек показывает
        // РЕАЛЬНЫЕ пути — вместе с именем пользователя macOS. Текстовые гейты
        // картинку не читают, поэтому утечка проходит незамеченной (так и было:
        // в опубликованном скриншоте светилось /Users/<имя>/… ).
        // Подставляем обезличенные пути на время рендера и возвращаем как было.
        let d = UserDefaults.standard
        let savedRec = d.string(forKey: AppPaths.recordingsDirKey)
        let savedTxt = d.string(forKey: AppPaths.transcriptsDirKey)
        d.set("/Users/user/Documents/Meeting Transcriber/Записи", forKey: AppPaths.recordingsDirKey)
        d.set("/Users/user/Documents/Транскрипты встреч", forKey: AppPaths.transcriptsDirKey)
        savedRecordingsDir = savedRec
        savedTranscriptsDir = savedTxt

        // 2) UI — живые окна + screencapture.
        NSApp.setActivationPolicy(.regular)
        let model = AppModel(preview: true)
        let meeting = Meeting(id: "d", title: "Weekly Sync — Product",
                              start: "2026-07-16T15:00:00+05:00",
                              minutesUntil: 1, meetingUrl: "https://zoom.us/j/123")

        var windows: [(String, NSWindow)] = []
        windows.append(("window", makeWindow(ContentView(model: model),
                                              title: "Meeting Transcriber",
                                              at: NSPoint(x: 120, y: 360))))
        windows.append(("popup", makeWindow(MeetingPopupView(meeting: meeting,
                                              onJoinRecord: {}, onDismiss: {}),
                                              title: nil, at: NSPoint(x: 480, y: 520))))
        windows.append(("pill", makeWindow(RecordingControlView(model: model, onStop: {}),
                                              title: nil, at: NSPoint(x: 480, y: 300))))
        windows.append(("meetings", makeWindow(TranscriptsView(),
                                              title: "Мои встречи",
                                              at: NSPoint(x: 820, y: 700))))
        windows.append(("settings", makeWindow(SettingsView(),
                                              title: "Настройки",
                                              at: NSPoint(x: 820, y: 300))))

        heldWindows = windows
        // даём окнам отрисоваться, снимаем статичные PNG, потом — кадры для gif плашки
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            for (name, w) in heldWindows {
                capture(window: w, to: dir.appendingPathComponent("\(name).png"))
                print("→ \(name).png")
            }
            captureGifFrames(dir: dir)
        }
    }

    /// Кадры анимированной плашки → gif. Timer не блокирует run loop, поэтому
    /// SwiftUI-анимация «дышащего» эквалайзера успевает продвигаться между кадрами.
    @MainActor
    private static func captureGifFrames(dir: URL) {
        guard let pill = heldWindows.first(where: { $0.0 == "pill" })?.1 else { restorePaths(); exit(0) }
        // светлый непрозрачный фон окна → gif без чёрного (ffmpeg иначе красит альфу в чёрный)
        pill.isOpaque = true
        pill.backgroundColor = NSColor(calibratedRed: 0.93, green: 0.93, blue: 0.95, alpha: 1)
        let framesDir = dir.appendingPathComponent("_frames")
        try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
        let totalFrames = 16
        Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { timer in
            let f = String(format: "f%02d.png", gifFrame)
            capture(window: pill, to: framesDir.appendingPathComponent(f))
            gifFrame += 1
            if gifFrame >= totalFrames {
                timer.invalidate()
                makeGif(framesDir: framesDir, out: dir.appendingPathComponent("pill.gif"))
                try? FileManager.default.removeItem(at: framesDir)
                print("→ pill.gif")
                restorePaths()
                exit(0)
            }
        }
    }

    @MainActor
    private static func makeGif(framesDir: URL, out: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
        p.arguments = ["-y", "-framerate", "11", "-i",
                       framesDir.appendingPathComponent("f%02d.png").path,
                       "-vf", "scale=200:-1:flags=lanczos", "-loop", "0", out.path]
        try? p.run(); p.waitUntilExit()
    }

    @MainActor
    private static func capture(window: NSWindow, to url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-o", "-x", "-l\(window.windowNumber)", url.path]
        try? p.run(); p.waitUntilExit()
    }

    @MainActor
    private static func renderLogo(to url: URL) {
        let renderer = ImageRenderer(content: AppLogo(size: 256))
        renderer.scale = 2
        if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
           let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
            print("→ logo.png")
        }
    }

    @MainActor
    private static func makeWindow<V: View>(_ view: V, title: String?,
                                            at origin: NSPoint) -> NSWindow {
        let hosting = NSHostingView(rootView: view.padding(title == nil ? 20 : 0))
        let style: NSWindow.StyleMask = title == nil ? [.borderless] : [.titled, .closable]
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: style, backing: .buffered, defer: false)
        if let title { w.title = title } else {
            w.isOpaque = false
            w.backgroundColor = .clear
        }
        w.contentView = hosting
        w.setContentSize(hosting.fittingSize)
        w.setFrameOrigin(origin)
        w.makeKeyAndOrderFront(nil)
        return w
    }
}
