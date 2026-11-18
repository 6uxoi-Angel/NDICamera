import Foundation
import AVFoundation

/// Захват микрофона (48 кГц) → Int16 (interleaved) → колбэк.
final class AudioCapturer {
    var onPCM: ((Data, Int, Int, Int, UInt64) -> Void)? // data, samples, channels, rate, timestampUs

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private let chunkSamples = 4800 // 100 мс @48k
    private var accumulator = Data()
    private var pendingSamples = 0
    private var rate = 48000
    private var channels = 1
    private var isRunning = false

    func prepare(rate: Int) throws {
        self.rate = rate
        let input = engine.inputNode
        _ = input.outputFormat(forBus: 0)
        try? input.setVoiceProcessingEnabled(false)
    }

    func start() throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        let targetFmt = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: fmt.channelCount)!
        input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(chunkSamples), format: targetFmt) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        isRunning = true
        AppLogger.info("Аудио запущено: \(rate) Гц, \(channels) каналов")
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
        guard chCount > 0 else { return }

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

        if pendingSamples >= chunkSamples {
            onPCM?(accumulator, pendingSamples, chCount, rate, timestampUs)
            accumulator.removeAll()
            pendingSamples = 0
        }
    }
}
