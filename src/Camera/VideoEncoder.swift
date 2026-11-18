import Foundation
import VideoToolbox
import CoreMedia
import AVFoundation

struct EncoderConfig {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int          // бит/с
    var maxKeyIntervalFrames: Int
    var realTime: Bool = true
}

extension EncoderConfig {
    init(settings: AppSettings) {
        let (w, h) = settings.resolution.size
        width = w
        height = h
        fps = settings.fps
        bitrate = Int(settings.bitrateMbps * 1_000_000)
        maxKeyIntervalFrames = settings.fps * 2
        realTime = true
    }
}

struct EncodedFrame {
    var payload: Data            // H.264 (AVCC или Annex-B — задаётся форматом)
    var width: Int
    var height: Int
    var spsPps: Data?            // параметры кодека (SPS+PPS)
    var timestampUs: UInt64      // в 100нс единицах NDI
    var isKeyFrame: Bool
    var avcc: Bool               // true = AVCC (длина-префикс), false = Annex-B
}

/// Отдаёт кадры в формате NV12 (420f) — Full NDI, без H.264.
/// SDK 6.3.2 для iOS не умеет отправку HX (H.264): только несжатые форматы.
final class VideoEncoder {
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    private(set) var isRunning = false

    private var config: EncoderConfig?

    private var statLock = NSLock()
    private var frameCount = 0
    private var lastIntervalStart: CFTimeInterval = 0
    private(set) var currentFPS: Double = 0
    private(set) var currentBitrateKbps: Double = 0

    func start(config: EncoderConfig) {
        stop()
        self.config = config
        frameCount = 0
        lastIntervalStart = CACurrentMediaTime()
        currentFPS = 0
        currentBitrateKbps = 0
        isRunning = true
        AppLogger.info("Видео: подготовка к Full NDI (NV12) \(config.width)x\(config.height)@\(config.fps)")
    }

    func stop() {
        isRunning = false
        AppLogger.info("Видео остановлено")
    }

    func forceKeyFrame() {
        // Full NDI не требует ключевых кадров
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, let config else { return }
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)
        guard w > 0, h > 0 else { return }

        CVPixelBufferLockBaseAddress(px, [])
        defer { CVPixelBufferUnlockBaseAddress(px, []) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(px, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(px, 1) else {
            return
        }
        let yBytes = w * h
        let uvBytes = (w / 2) * (h / 2) * 2
        var payload = Data(capacity: yBytes + uvBytes)
        payload.append(Data(bytes: yBase, count: yBytes))
        payload.append(Data(bytes: uvBase, count: uvBytes))

        let timestampUs = UInt64((CFAbsoluteTimeGetCurrent() + 978307200) * 1e7)

        let now = CACurrentMediaTime()
        statLock.lock()
        frameCount += 1
        if now - lastIntervalStart >= 2.0 {
            currentFPS = Double(frameCount) / (now - lastIntervalStart)
            currentBitrateKbps = (Double(payload.count) * 8.0 / 1000.0) * currentFPS / 1000.0
            frameCount = 0
            lastIntervalStart = now
        }
        statLock.unlock()

        let frame = EncodedFrame(payload: payload,
                                 width: w,
                                 height: h,
                                 spsPps: nil,
                                 timestampUs: timestampUs,
                                 isKeyFrame: true,
                                 avcc: false)
        onEncodedFrame?(frame)
    }
}
