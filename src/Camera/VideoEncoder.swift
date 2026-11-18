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

/// Аппаратный H.264 энкодер на VideoToolbox.
final class VideoEncoder {
    var onEncodedFrame: ((EncodedFrame) -> Void)?
    private(set) var isRunning = false

    private var compressionSession: VTCompressionSession?
    private var config: EncoderConfig?
    private var cachedSPS: Data?
    private var cachedPPS: Data?

    // Статистика
    private var statLock = NSLock()
    private var frameCount = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var lastIntervalStart: CFTimeInterval = 0
    private var encodedBytes = 0
    private(set) var currentFPS: Double = 0
    private(set) var currentBitrateKbps: Double = 0

    func start(config: EncoderConfig) {
        stop()
        self.config = config
        cachedSPS = nil
        cachedPPS = nil
        frameCount = 0
        lastIntervalStart = CACurrentMediaTime()

        var status: OSStatus = noErr
        let attrs: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        compressionSession = nil
        status = VTCompressionSessionCreate(
            allocator: nil,
            width: config.width,
            height: config.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            sourceImageBufferAttributes: attrs,
            compressedDataAllocator: nil,
            outputCallback: { (_, _, status, flags, sampleBuffer, refcon) in
                guard let refcon else { return }
                let encoder = Unmanaged<VideoEncoder>.fromOpaque(refcon).takeUnretainedValue()
                encoder.handleOutput(status: status, flags: flags, sampleBuffer: sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque()
        )
        guard status == noErr, let session = compressionSession else {
            AppLogger.error("VTCompressionSessionCreate: \(status)")
            return
        }
        // Параметры кодирования
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: config.realTime)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: config.bitrate)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: config.fps)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: config.maxKeyIntervalFrames)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: Double(config.maxKeyIntervalFrames) / Double(config.fps))
        // Снижаем задержку: без B-кадров, минимальный GOP для быстрого подхвата OBS
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: false)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PixelTransferProperties, value: [kVTCompressionPropertyKey_RealTime: true])
        VTCompressionSessionPrepareToEncodeFrames(session)
        currentFPS = 0
        currentBitrateKbps = 0
        isRunning = true
    }

    func stop() {
        guard let session = compressionSession else { return }
        VTCompressionSessionInvalidate(session)
        compressionSession = nil
        isRunning = false
        AppLogger.info("Энкодер остановлен")
    }

    func forceKeyFrame() {
        guard let session = compressionSession else { return }
        VTCompressionSessionEncodeFrame(session, imageBuffer: nil, presentationTimeStamp: CMTime.zero, duration: .zero, frameProperties: [kVTEncodeFrameOptionKey_ForceKeyFrame: true], infoFlagsOut: nil, outputHandler: nil)
    }

    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let session = compressionSession, let px = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        VTCompressionSessionEncodeFrame(session, imageBuffer: px, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil, outputHandler: nil)
        // статистика fps
        let now = CACurrentMediaTime()
        statLock.lock()
        frameCount += 1
        if now - lastIntervalStart >= 2.0 {
            currentFPS = Double(frameCount) / (now - lastIntervalStart)
            currentBitrateKbps = (Double(encodedBytes) * 8.0 / 1000.0) / (now - lastIntervalStart)
            frameCount = 0
            encodedBytes = 0
            lastIntervalStart = now
        }
        statLock.unlock()
    }

    private func handleOutput(status: OSStatus, flags: VTEncodeInfoFlags, sampleBuffer: CMSampleBuffer?) {
        guard status == noErr, let sb = sampleBuffer else {
            if status != noErr { AppLogger.error("Энкодер status \(status)") }
            return
        }
        let isKeyframe: Bool
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as CFString] as? Bool {
            isKeyframe = !notSync
        } else {
            isKeyframe = true
        }

        // Извлекаем SPS/PPS один раз из description
        if cachedSPS == nil {
            extractParameterSets(from: sb)
        }

        guard let config else { return }
        let start = CFTimeInterval(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)))
        _ = start

        // Данные: CMBlockBuffer — это AVCC (длина-префикс). Преобразуем при необходимости.
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sb) else { return }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return }
        var dataPtr: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        var total: Int = 0
        let err = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: &total, dataPointerOut: &dataPtr)
        guard err == kCMBlockBufferNoErr, let p = dataPtr else { return }
        let rawData = Data(bytes: p, count: totalLength)

        // Единая временная база для видео и аудио: 100нс от эпохи 2001 (как в AudioCapturer)
        let timestampUs = UInt64((CFAbsoluteTimeGetCurrent() + 978307200) * 1e7)
        let avcc = true
        var payload = rawData

        if !avcc {
            payload = toAnnexB(rawData)
        }

        var spspps: Data?
        if let s = cachedSPS, let p = cachedPPS {
            if avcc {
                var combined = Data()
                combined.append(s)
                combined.append(p)
                spspps = combined
            } else {
                var combined = Data()
                combined.append(Data([0,0,0,1]))
                combined.append(s)
                combined.append(Data([0,0,0,1]))
                combined.append(p)
                spspps = combined
            }
        }

        statLock.lock()
        encodedBytes += payload.count
        statLock.unlock()

        let frame = EncodedFrame(payload: payload, width: config.width, height: config.height, spsPps: spspps, timestampUs: timestampUs, isKeyFrame: isKeyframe, avcc: avcc)
        onEncodedFrame?(frame)
    }

    private func extractParameterSets(from sb: CMSampleBuffer) {
        guard let fmt = CMSampleBufferGetFormatDescription(sb) else { return }
        var spsData: Data?
        var ppsData: Data?
        var count = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var size = 0
        var ptr: UnsafePointer<UInt8>?
        if count > 0, CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
            spsData = Data(bytes: p, count: size)
        }
        if count > 1, CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 1, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let p = ptr {
            ppsData = Data(bytes: p, count: size)
        }
        cachedSPS = spsData
        cachedPPS = ppsData
    }

    /// AVCC → Annex-B (старт-коды)
    private func toAnnexB(_ avcc: Data) -> Data {
        var out = Data()
        var idx = 0
        let bytes = [UInt8](avcc)
        while idx + 4 <= bytes.count {
            let len = Int(bytes[idx]) << 24 | Int(bytes[idx+1]) << 16 | Int(bytes[idx+2]) << 8 | Int(bytes[idx+3])
            idx += 4
            if len <= 0 || idx + len > bytes.count { break }
            out.append(contentsOf: [0,0,0,1])
            out.append(contentsOf: bytes[idx..<idx+len])
            idx += len
        }
        return out
    }
}
