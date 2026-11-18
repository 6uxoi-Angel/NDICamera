import Foundation
import AVFoundation

/// Захват микрофона (48 кГц) → Int16 (interleaved) → колбэк.
final class AudioCapturer {
    var onPCM: ((Data, Int, Int, Int, UInt64) -> Void)? // data, samples, channels, rate, timestampUs

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var accumulator = Data()
    private var pendingSamples = 0
    private var isRunning = false

    func prepare(rate: Int) throws {
        let input = engine.inputNode
        _ = input.outputFormat(forBus: 0)
        try? input.setVoiceProcessingEnabled(false)
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        // Используем РОДНОЙ формат входного узла — любой кастомный формат
        // может не совпасть и вызвать exception в installTap.
        let fmt = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(1024), format: fmt) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        isRunning = true
        AppLogger.info("Аудио запущено: \(Int(fmt.sampleRate)) Гц, \(fmt.channelCount) каналов")
    }

    func stop() {
        guard isRunning else { return }
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        isRunning = false
        accumulator.removeAll()
        pendingSamples = 0
    }

    private func handle(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frameLen = Int(buffer.frameLength)
        let chCount = Int(buffer.format.channelCount)
        let sampleRate = Int(buffer.format.sampleRate)
        guard chCount > 0, frameLen > 0 else { return }

        // NDI v3 / FLTP: float32 планар (сначала все сэмплы канала 0, затем канала 1...)
        var pcm = Data(capacity: frameLen * chCount * 4)
        for ch in 0..<chCount {
            for frame in 0..<frameLen {
                var sample = channelData[ch][frame]
                withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
            }
        }
        accumulator.append(pcm)
        pendingSamples += frameLen

        // Для синхронизации — время в 100нс единицах
        let time = CFAbsoluteTimeGetCurrent()
        let timestampUs = UInt64((time + 978307200) * 1e7) // эпоха 2001 → unix

        // Отдаём пакетами ~100 мс
        let chunkSamples = max(256, sampleRate / 10)
        if pendingSamples >= chunkSamples {
            onPCM?(accumulator, pendingSamples, chCount, sampleRate, timestampUs)
            accumulator.removeAll()
            pendingSamples = 0
        }
    }
}
