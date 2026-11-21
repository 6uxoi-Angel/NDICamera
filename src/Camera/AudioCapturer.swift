import Foundation
import AVFoundation

/// Захват микрофона → float32 ПЛАНАРНЫЙ (FLTP) → колбэк.
///
/// NDI audio v3 ждёт FLTP: сначала ВСЕ семплы канала 0, затем канала 1…,
/// каждый пакет — самодостаточный. Прежняя версия склеивала несколько
/// буферов в один «планарный» массив (получался межблочный interleave →
/// каша вместо звука) и гоняла данные через общий аккумулятор без блокировок.
/// Теперь каждый tap-буфер конвертируется и отправляется отдельно —
/// просто и без гонок (колбэк выполняется в потоке аудиодвижка AVAudioEngine).
final class AudioCapturer {
    /// data — FLTP; samples — семплов на канал; channels; sampleRate; timecodeUs (100 нс, unix)
    var onPCM: ((Data, Int, Int, Int, UInt64) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var isRunning = false

    func prepare(rate: Int) throws {
        // Формат входного узла проверяем заранее; кастомный формат на
        // installTap ронял процесс (AURemoteIO) — используем родной.
        _ = engine.inputNode.outputFormat(forBus: 0)
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
        try session.setActive(true)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "AudioCapturer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Невалидный формат входа: \(format)"])
        }
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(2048), format: nil) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        isRunning = true
        AppLogger.info("Аудио запущено: \(Int(format.sampleRate)) Гц, \(format.channelCount) кан., FLTP")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard isRunning, let onPCM else { return }
        guard let channelData = buffer.floatChannelData else { return }
        let frameLen = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        guard frameLen > 0, chCount > 0, sampleRate > 0 else { return }

        // Планарно: канал за каналом (floatChannelData уже планарная)
        let bytesPerChannel = frameLen * MemoryLayout<Float>.size
        var data = Data(count: bytesPerChannel * chCount)
        data.withUnsafeMutableBytes { raw in
            guard let base = raw.bindMemory(to: Float.self).baseAddress else { return }
            for ch in 0..<chCount {
                let src = channelData[ch]
                memcpy(base + ch * frameLen, src, bytesPerChannel)
            }
        }
        let timecodeUs = UInt64((CFAbsoluteTimeGetCurrent() + 978307200) * 1e7)
        onPCM(data, frameLen, chCount, sampleRate, timecodeUs)
    }
}
