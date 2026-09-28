// Смоук микрофонной последовательности из Recorder.makeMicInput.
// Запуск: swift app/mic_smoke.swift — печатает кадры или причину отказа,
// но НИКОГДА не должен падать с abort (именно это ломало приложение).

import AVFoundation
// Повторяет порядок из Recorder.makeMicInput: prepare → inputNode → проверка
// привязки → installTap → start. Падение = abort, успех = печать кадров.
var engine = AVAudioEngine()
func makeInput() -> AVAudioInputNode? {
    engine.stop()
    engine = AVAudioEngine()
    let input = engine.inputNode
    guard input.engine != nil else { print("engine == nil → guard сработал"); return nil }
    let f = input.outputFormat(forBus: 0)
    guard f.sampleRate > 0, f.channelCount > 0 else { print("формат пуст → guard"); return nil }
    input.removeTap(onBus: 0)
    engine.prepare()
    return input
}
guard let input = makeInput() ?? makeInput() else { print("вход не поднялся — без крэша"); exit(0) }
var frames = 0
input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { b, _ in
    frames += Int(b.frameLength)
}
try engine.start()
Thread.sleep(forTimeInterval: 1.0)
engine.stop()
print("OK, кадров с микрофона: \(frames)")
