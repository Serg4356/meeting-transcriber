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
    var errorDescription: String? {
        switch self {
        case .noDisplay: return "Нет доступного дисплея для захвата"
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
    private let micEngine = AVAudioEngine()
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

    func start(baseDir: URL) async throws -> URL {
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
        let input = micEngine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: micURL, settings: micFormat.settings)
        self.micFile = file
        let pf = pauseFlag
        input.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            guard !pf.paused else { return }
            do { try file.write(from: buffer) } catch { NSLog("[микрофон] запись: \(error)") }
        }
        micEngine.prepare()
        try micEngine.start()

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
