// Движок захвата: системный звук — ScreenCaptureKit, микрофон — AVAudioEngine.
//
// Почему микрофон НЕ через ScreenCaptureKit.captureMicrophone: он дерётся за
// устройство с Zoom/Meet и отваливается, как только звонок захватывает мик
// (проверено: mic-дорожка обрывалась на ~13с, пока system шёл 147с).
// AVAudioEngine — обычный разделяемый HAL-клиент, уживается со звонком.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: Error, LocalizedError {
    case noDisplay
    case noMicFormat
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Нет доступного дисплея для захвата"
        case .noMicFormat: return "Микрофон недоступен (нулевой формат входа)"
        }
    }
}

// Ленивая запись семплов системного звука (CMSampleBuffer) в AVAudioFile.
final class TrackWriter {
    private let url: URL
    private var file: AVAudioFile?
    let label: String

    init(url: URL, label: String) {
        self.url = url
        self.label = label
    }

    func write(_ sampleBuffer: CMSampleBuffer) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)
        else { return }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0,
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { return }
        pcm.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames),
            into: pcm.mutableAudioBufferList)
        guard status == noErr else { return }

        do {
            if file == nil {
                file = try AVAudioFile(forWriting: url, settings: format.settings,
                                       commonFormat: format.commonFormat,
                                       interleaved: format.isInterleaved)
            }
            try file?.write(from: pcm)
        } catch {
            NSLog("[\(label)] ошибка записи: \(error)")
        }
    }
}

// Разделяемый флаг паузы (проверяется на аудио-потоках захвата и микрофона).
final class PauseFlag {
    var paused = false
}

// Приёмник только системного звука (микрофон идёт отдельно через AVAudioEngine).
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let systemTrack: TrackWriter
    let pauseFlag: PauseFlag

    init(systemTrack: TrackWriter, pauseFlag: PauseFlag) {
        self.systemTrack = systemTrack
        self.pauseFlag = pauseFlag
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if type == .audio && !pauseFlag.paused {
            systemTrack.write(sampleBuffer)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("SCStream STOPPED with error: \(error) — системный звук дальше не пишется!")
    }
}

final class Recorder {
    private var stream: SCStream?
    private var output: StreamOutput?
    private var micEngine = AVAudioEngine()
    private var micFile: AVAudioFile?
    private let pauseFlag = PauseFlag()
    private(set) var sessionURL: URL?

    /// Пауза/продолжение: перестаём/начинаем писать звук обеих дорожек.
    /// Захват продолжает крутиться, но семплы во время паузы отбрасываются —
    /// пустое ожидание не попадает в файлы и в транскрипт.
    func setPaused(_ paused: Bool) { pauseFlag.paused = paused }

    private func makeSession(_ base: URL) -> URL {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let dir = base.appendingPathComponent(fmt.string(from: Date()))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Свежий движок под сессию + гарантированно живой вход.
    ///
    /// Когда HAL в момент старта переключает устройство (типично после сна
    /// Мака), `inputNode` приходит НЕ привязанным к движку. Тогда `installTap`
    /// кидает ObjC-исключение `required condition is false: NULL != engine`,
    /// Swift его не ловит и процесс умирает с SIGABRT — пять крэшей
    /// 07–16.09.2026. Поэтому привязку проверяем сами и отдаём nil.
    ///
    /// Порядок строг: узел → проверка → `prepare()`. На пустом графе сам
    /// `prepare()` кидает `inputNode != nullptr || outputNode != nullptr`
    /// (воспроизведено смоук-скриптом), то есть до проверки его звать нельзя.
    private func makeMicInput() -> AVAudioInputNode? {
        micEngine.stop()
        micEngine = AVAudioEngine()
        let input = micEngine.inputNode
        guard input.engine != nil else { return nil }
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return nil }
        input.removeTap(onBus: 0)
        micEngine.prepare()
        return input
    }

    func start(baseDir: URL) async throws -> URL {
        // Флаг живёт дольше сессии: стоп во время паузы оставлял paused=true,
        // и все следующие записи молча писали 0 байт (02–04.09.2026).
        pauseFlag.paused = false
        let session = makeSession(baseDir)

        // --- Системный звук: ScreenCaptureKit ---
        let systemTrack = TrackWriter(url: session.appendingPathComponent("system.caf"),
                                      label: "система")
        let out = StreamOutput(systemTrack: systemTrack, pauseFlag: pauseFlag)

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: config, delegate: out)
        let queue = DispatchQueue(label: "capture.system")
        try newStream.addStreamOutput(out, type: .audio, sampleHandlerQueue: queue)
        try await newStream.startCapture()

        // --- Микрофон: AVAudioEngine (уживается с Zoom) ---
        let micURL = session.appendingPathComponent("mic.caf")
        do {
            // Вторая попытка через паузу: первая часто ловит HAL в момент
            // переконфигурации устройства (после сна Мака).
            var candidate = makeMicInput()
            if candidate == nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
                candidate = makeMicInput()
            }
            guard let input = candidate else { throw RecorderError.noMicFormat }
            let micFormat = input.outputFormat(forBus: 0)
            let file = try AVAudioFile(forWriting: micURL, settings: micFormat.settings)
            self.micFile = file
            let pf = pauseFlag
            input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
                guard !pf.paused else { return }
                do { try file.write(from: buffer) } catch { NSLog("[микрофон] запись: \(error)") }
            }
            try micEngine.start()
        } catch {
            // Системный захват уже идёт — без этого он остался бы висеть
            // навсегда (в self.stream попадает только успешный старт).
            try? await newStream.stopCapture()
            throw error
        }

        self.stream = newStream
        self.output = out
        self.sessionURL = session
        return session
    }

    func stop() async throws {
        micEngine.inputNode.removeTap(onBus: 0)
        micEngine.stop()
        micFile = nil
        try await stream?.stopCapture()
        stream = nil
        output = nil
    }
}
