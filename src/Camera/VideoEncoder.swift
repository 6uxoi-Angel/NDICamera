import Foundation
import CoreVideo
import CoreMedia
import AVFoundation
import QuartzCore

struct EncoderConfig {
    var width: Int
    var height: Int
    var fps: Int
    var bitrate: Int          // бит/с (для Full NDI не используется — несжатый поток)
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

struct RawFrame {
    var payload: Data            // NV12, плотно упакованный (строка = width байт)
    var width: Int
    var height: Int
    var timecodeUs: UInt64       // 100 нс от unix-эпохи (требование NDI)
}

/// Отдаёт кадры в формате NV12 (420f/420v) — Full NDI, без H.264.
/// SDK 6.3.2 для iOS не умеет отправку HX (H.264): только несжатые форматы.
///
/// Важно: CVPixelBuffer от камеры может иметь выравнивание строк
/// (bytesPerRow > width). Копируем ПОСТРОЧНО, иначе картинка «перекашивается»,
/// а размеры, переданные в NDI (line_stride), перестают соответствовать буферу.
final class VideoEncoder {
    var onEncodedFrame: ((RawFrame) -> Void)?

    private(set) var isRunning = false
    private var config: EncoderConfig?
    private var loggedFormatIssue = false

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
        loggedFormatIssue = false
        isRunning = true
        AppLogger.info("Видео: Full NDI (NV12), цель \(config.width)x\(config.height)@\(config.fps)")
    }

    func stop() {
        isRunning = false
        AppLogger.info("Видео остановлено")
    }

    func forceKeyFrame() {
        // Full NDI не требует ключевых кадров
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning, config != nil else { return }
        guard let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = CVPixelBufferGetWidth(px)
        let h = CVPixelBufferGetHeight(px)
        guard w > 1, h > 1, w & 1 == 0, h & 1 == 0 else { return }

        let fmtType = CVPixelBufferGetPixelFormatType(px)
        let isPlanar420 = fmtType == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                       || fmtType == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        guard isPlanar420 else {
            if !loggedFormatIssue {
                loggedFormatIssue = true
                let code = UInt32(fmtType)
                let fourcc = FourCharCode(code).fourCCString()
                AppLogger.error("Неожиданный формат кадров \(fourcc) — ожидался NV12 (420v/420f). Кадры пропускаются.")
            }
            return
        }

        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(px, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(px, 1) else { return }
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(px, 1)
        guard yRow >= w, uvRow >= w, yRow != 0, uvRow != 0 else { return }

        // Плотный NV12: Y (w*h) + CbCr (w*h/2), строки по w байт
        let total = w * h * 3 / 2
        var payload = Data(count: total)
        payload.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            // Y-плоскость
            yBase.withMemoryRebound(to: UInt8.self, capacity: yRow * h) { src in
                for row in 0..<h {
                    memcpy(dst + row * w, src + row * yRow, w)
                }
            }
            // CbCr-плоскость сразу за Y
            let chromaDst = dst + w * h
            uvBase.withMemoryRebound(to: UInt8.self, capacity: uvRow * (h / 2)) { src in
                for row in 0..<(h / 2) {
                    memcpy(chromaDst + row * w, src + row * uvRow, w)
                }
            }
        }

        // 100 нс от unix-эпохи (CFAbsoluteTime — с 2001 г., +978307200 с)
        let timecodeUs = UInt64((CFAbsoluteTimeGetCurrent() + 978307200) * 1e7)

        let now = CACurrentMediaTime()
        statLock.lock()
        frameCount += 1
        if now - lastIntervalStart >= 2.0 {
            currentFPS = Double(frameCount) / (now - lastIntervalStart)
            currentBitrateKbps = Double(payload.count) * 8.0 * currentFPS / 1_000_000.0
            frameCount = 0
            lastIntervalStart = now
        }
        statLock.unlock()

        let frame = RawFrame(payload: payload, width: w, height: h, timecodeUs: timecodeUs)
        onEncodedFrame?(frame)
    }
}

extension FourCharCode {
    /// Разбор FOURCC ('420v' и т.п.) для человекочитаемого лога
    func fourCCString() -> String {
        let chars = [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF),
                     UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)]
        return String(bytes: chars, encoding: .ascii) ?? "?"
    }
}
