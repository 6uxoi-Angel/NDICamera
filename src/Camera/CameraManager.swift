import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// Управление камерой: AVCaptureSession + AVCaptureVideoDataOutput.
final class CameraManager: NSObject, ObservableObject {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session.queue")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentDevice: AVCaptureDevice?
    private var lastSettings: AppSettings?

    var previewLayer: AVCaptureVideoPreviewLayer { AVCaptureVideoPreviewLayer(session: session) }
    var sessionQueue: DispatchQueue { queue }
    var isRunning: Bool { session.isRunning }

    var torchAvailable: Bool {
        currentDevice?.hasTorch ?? false
    }

    func startStream(settings: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.lastSettings = settings
            self.configure(settings: settings)
            self.session.startRunning()
            AppLogger.info("Камера: сессия запущена, \(settings.resolution.rawValue)@\(settings.fps), камера \(settings.camera.rawValue)")
        }
    }

    func stopStream() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            AppLogger.info("Камера: сессия остановлена")
        }
    }

    func switchCamera(to position: AppSettings.CameraSelection) {
        queue.async { [weak self] in
            guard let self else { return }
            self.reconfigureCamera(to: position)
        }
    }

    func setTorch(on: Bool) {
        queue.async { [weak self] in
            guard let self, let d = self.currentDevice, d.hasTorch else { return }
            do {
                try d.lockForConfiguration()
                d.torchMode = on ? .on : .off
                d.unlockForConfiguration()
            } catch {
                AppLogger.warn("Фонарик: не удалось (\(error.localizedDescription))")
            }
        }
    }

    func setZoom(_ factor: CGFloat) {
        queue.async { [weak self] in
            guard let self, let d = self.currentDevice else { return }
            let maxZoom = min(d.activeFormat.videoMaxZoomFactor, 12.0)
            let clamped = min(max(factor, 1.0), maxZoom)
            try? d.lockForConfiguration()
            d.videoZoomFactor = clamped
            d.unlockForConfiguration()
        }
    }

    /// Точка фокуса в координатах превью (0...1). Tap-to-focus + авто-экспозиция.
    func tapToFocus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let d = self.currentDevice else { return }
            try? d.lockForConfiguration()
            if d.isFocusPointOfInterestSupported {
                d.focusPointOfInterest = point
                d.focusMode = .autoFocus
            }
            if d.isExposurePointOfInterestSupported {
                d.exposurePointOfInterest = point
                d.exposureMode = .autoExpose
            }
            d.unlockForConfiguration()
        }
    }

    func toggleExposureLock() {
        queue.async { [weak self] in
            guard let self, let d = self.currentDevice else { return }
            try? d.lockForConfiguration()
            d.exposureMode = (d.exposureMode == .locked) ? .continuousAutoExposure : .locked
            d.unlockForConfiguration()
        }
    }

    // MARK: - Конфигурация

    private func configure(settings: AppSettings) {
        session.beginConfiguration()
        guard let device = device(for: settings.camera) else {
            AppLogger.error("Камера недоступна: \(settings.camera.rawValue)")
            session.commitConfiguration()
            return
        }
        currentDevice = device
        applyFormat(device: device, settings: settings)

        // Вход
        for input in session.inputs { session.removeInput(input) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        } else {
            AppLogger.error("Не удалось добавить вход камеры")
        }

        // Выход видео — NV12 (2-plane 420f), плотный для NDI
        if let out = videoOutput {
            session.removeOutput(out)
        }
        let out = AVCaptureVideoDataOutput()
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        out.alwaysDiscardsLateVideoFrames = true
        out.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(out) {
            session.addOutput(out)
            videoOutput = out
        } else {
            AppLogger.error("Не удалось добавить видеовыход")
        }
        if let connection = out.connection(with: .video) {
            applyOrientation(to: connection, camera: settings.camera)
        }
        session.commitConfiguration()
    }

    /// Выбор activeFormat: формат, ЧЬЯ ПЛОЩАДЬ ближе всего к запрашиваемому
    /// разрешению (учитывая, что поворот меняет местами w/h) и который тянет fps.
    /// Старый код брал первый формат с dims >= target → вместо 720p включался
    /// сенсор в 4K: лишние гигабиты и перегрев SE.
    private func applyFormat(device: AVCaptureDevice, settings: AppSettings) {
        let (tw, th) = settings.resolution.size
        let targetPixels = Double(tw * th)
        let targetFps = Double(settings.fps)
        var best: (format: AVCaptureDevice.Format, score: Double)?
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Double(dims.width) * Double(dims.height)
            guard pixels > 0 else { continue }
            let ranges = format.videoSupportedFrameRateRanges
            let supportsFps = ranges.contains { $0.maxFrameRate >= targetFps - 0.5 && $0.minFrameRate <= targetFps + 0.5 }
            // штраф за неверный fps — сильный, но не абсолютный (лучше 30 чем ничего)
            var score = abs(pixels - targetPixels) / max(targetPixels, 1)
            if !supportsFps { score += 10 }
            if score < (best?.score ?? .infinity) {
                best = (format, score)
            }
        }
        guard let chosen = best?.format else {
            AppLogger.error("Камера: нет ни одного формата")
            return
        }
        do {
            try device.lockForConfiguration()
            device.activeFormat = chosen
            let fps = settings.fps
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            device.unlockForConfiguration()
            let dims = CMVideoFormatDescriptionGetDimensions(chosen.formatDescription)
            AppLogger.info("Камера: формат \(dims.width)x\(dims.height)@\(fps) (запрошено \(tw)x\(th))")
        } catch {
            AppLogger.error("Камера: lockForConfiguration не удался: \(error.localizedDescription)")
        }
    }

    private func reconfigureCamera(to position: AppSettings.CameraSelection) {
        guard let settings = lastSettings else {
            AppLogger.info("Нет сохранённых настроек — конфигурация при старте")
            return
        }
        // AppSettings — класс: мутация через использованную ссылку меняет и модель.
        settings.camera = position
        lastSettings = settings
        let wasRunning = session.isRunning
        if wasRunning { session.stopRunning() }
        configure(settings: settings)
        if wasRunning { session.startRunning() }
    }
    private func device(for position: AppSettings.CameraSelection) -> AVCaptureDevice? {
        switch position {
        case .front:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        case .back:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .ultraWide:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
        }
    }

    private func applyOrientation(to connection: AVCaptureConnection, camera: AppSettings.CameraSelection) {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.interfaceOrientation }
            .first ?? .portrait
        var angle: CGFloat
        switch orientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        case .unknown: angle = 90
        @unknown default: angle = 90
        }
        if camera == .front, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        } else if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        } else if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }
}

// MARK: - Доступные камеры

extension AppSettings.CameraSelection {
    /// Список камер, реально доступных на устройстве
    static var availableCameras: [AppSettings.CameraSelection] {
        var result: [AppSettings.CameraSelection] = []
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil { result.append(.back) }
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil { result.append(.ultraWide) }
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil { result.append(.front) }
        return result
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
