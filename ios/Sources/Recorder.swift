import AVFoundation
import Foundation

// Запись микрофона в m4a. 16 кГц моно — ровно то, что жуют Whisper и pyannote;
// час встречи ≈ 15 МБ, аплоад по домашнему Wi-Fi мгновенный.

@MainActor
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var level: Double = 0        // 0…1 для индикатора
    @Published var lastError: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var startedAt = Date()
    private var currentDir: URL?

    private let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000.0,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32000,
    ]

    func requestPermission(_ done: @escaping (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            DispatchQueue.main.async { done(granted) }
        }
    }

    /// Стартует запись. Возвращает id сессии либо nil, если не вышло.
    @discardableResult
    func start(into root: URL) -> String? {
        guard !isRecording else { return nil }
        let now = Date()
        let id = SessionFormat.newID(at: now)
        let dir = root.appendingPathComponent(id, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let session = AVAudioSession.sharedInstance()
            // .record + .spokenAudio: система не глушит нас, когда экран гаснет
            try session.setCategory(.record, mode: .spokenAudio)
            try session.setActive(true)
            let rec = try AVAudioRecorder(url: dir.appendingPathComponent("mic.m4a"), settings: settings)
            rec.isMeteringEnabled = true
            rec.delegate = self
            guard rec.record() else { throw NSError(domain: "Terminus", code: 1) }
            recorder = rec
            currentDir = dir
            startedAt = now
            elapsed = 0
            isRecording = true
            startTicker()
            observeInterruptions()
            return id
        } catch {
            lastError = "Не удалось начать запись: \(error.localizedDescription)"
            try? FileManager.default.removeItem(at: dir)
            return nil
        }
    }

    /// Останавливает запись и отдаёт готовую сессию.
    func stop() -> RecSession? {
        guard let rec = recorder, let dir = currentDir else { return nil }
        let duration = rec.currentTime > 0 ? rec.currentTime : elapsed
        rec.stop()
        recorder = nil
        currentDir = nil
        isRecording = false
        timer?.invalidate(); timer = nil
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        // пустышка (тап по кнопке дважды) — не засоряем список
        guard duration >= 1 else { try? FileManager.default.removeItem(at: dir); return nil }
        return RecSession(id: dir.lastPathComponent,
                          title: dir.lastPathComponent,
                          started: startedAt,
                          duration: duration,
                          uploaded: false,
                          dir: dir)
    }

    private func startTicker() {
        timer?.invalidate()
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let rec = self.recorder else { return }
                self.elapsed = rec.currentTime
                rec.updateMeters()
                // dBFS (-160…0) → 0…1, с полом на -50 дБ: тише — это тишина
                let db = Double(rec.averagePower(forChannel: 0))
                self.level = max(0, min(1, (db + 50) / 50))
            }
        }
        RunLoop.main.add(t, forMode: .common)   // .common — не замирает при скролле списка
        timer = t
    }

    // Входящий звонок/будильник прерывает запись. Без обработки встреча
    // молча обрывается на середине — возобновляем, как только система отпустит.
    private func observeInterruptions() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            Task { @MainActor in
                guard let self, let rec = self.recorder else { return }
                switch type {
                case .began:
                    rec.pause()
                case .ended:
                    try? AVAudioSession.sharedInstance().setActive(true)
                    if !rec.record() {
                        self.lastError = "Запись прервана звонком и не возобновилась"
                    }
                @unknown default:
                    break
                }
            }
        }
    }
}

extension Recorder: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.lastError = "Сбой кодирования звука: \(error?.localizedDescription ?? "неизвестно")"
        }
    }
}
