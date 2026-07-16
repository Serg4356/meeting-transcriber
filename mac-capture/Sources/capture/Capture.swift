// Прототип захвата встречи через ScreenCaptureKit (macOS 15+).
// Пишет ДВА файла: system.caf (звук любого приложения — Zoom.app/браузер/…)
// и mic.caf (микрофон). Разделение на дорожки нужно для диаризации:
// mic = "я", system = собеседники.
//
// Запуск:  swift run capture [папка_вывода]
// Стоп:    Enter (или Ctrl+C)
//
// Требует разрешений: Screen & System Audio Recording + Microphone
// (macOS сам покажет запрос при первом запуске).

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

// Обёртка над AVAudioFile: файл создаётся лениво, когда придёт первый семпл
// (чтобы взять реальный формат потока, а не угадывать).
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
                FileHandle.standardError.write(
                    Data("[\(label)] пишу \(url.lastPathComponent) — "
                         .utf8))
                FileHandle.standardError.write(
                    Data("\(Int(format.sampleRate))Hz \(format.channelCount)ch\n".utf8))
            }
            try file?.write(from: pcm)
        } catch {
            FileHandle.standardError.write(
                Data("[\(label)] ошибка записи: \(error)\n".utf8))
        }
    }
}

// Приёмник семплов от SCStream: раскидывает по дорожкам.
final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let systemTrack: TrackWriter
    let micTrack: TrackWriter

    init(systemTrack: TrackWriter, micTrack: TrackWriter) {
        self.systemTrack = systemTrack
        self.micTrack = micTrack
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            systemTrack.write(sampleBuffer)
        case .microphone:
            micTrack.write(sampleBuffer)
        default:
            break  // .screen — видео игнорируем
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("Поток остановлен с ошибкой: \(error)\n".utf8))
    }
}

func timestampDir(_ base: URL) -> URL {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let dir = base.appendingPathComponent(fmt.string(from: Date()))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@main
struct Main {
    static func main() async {
        let args = CommandLine.arguments
        let baseDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "recordings")
        let session = timestampDir(baseDir)

        let systemTrack = TrackWriter(url: session.appendingPathComponent("system.caf"),
                                      label: "система")
        let micTrack = TrackWriter(url: session.appendingPathComponent("mic.caf"),
                                   label: "микрофон")
        let output = StreamOutput(systemTrack: systemTrack, micTrack: micTrack)

        do {
            // Запрос доступа к экрану/звуку — тут macOS покажет prompt.
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else {
                FileHandle.standardError.write(Data("Нет доступного дисплея\n".utf8))
                exit(1)
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            let config = SCStreamConfiguration()
            config.capturesAudio = true               // системный звук
            config.excludesCurrentProcessAudio = true // не писать свой же звук
            config.sampleRate = 48000
            config.channelCount = 2
            config.captureMicrophone = true           // микрофон (macOS 15+)
            // Видео нам не нужно — минимизируем.
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let stream = SCStream(filter: filter, configuration: config, delegate: output)
            let queue = DispatchQueue(label: "capture.audio")
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: queue)
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: queue)

            try await stream.startCapture()
            print("● Запись → \(session.path)")
            print("  Нажми Enter для остановки.")
            _ = readLine()

            try await stream.stopCapture()
            print("■ Остановлено. Файлы в \(session.path)")
        } catch {
            FileHandle.standardError.write(Data("Ошибка: \(error)\n".utf8))
            exit(1)
        }
    }
}
