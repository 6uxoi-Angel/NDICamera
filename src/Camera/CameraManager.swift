import Foundation
import AVFoundation
import UIKit

/// Управление камерой: AVCaptureSession + AVCaptureVideoDataOutput.
final class CameraManager: NSObject, ObservableObject {
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "camera.session.queue")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var currentDevice: AVCaptureDevice?
    private var currentPosition: AppSettings.CameraSelection = .back

    var previewLayer: AVCaptureVideoPreviewLayer { AVCaptureVideoPreviewLayer(session: session) }
    var sessionQueue: DispatchQueue { queue }

    var isRunning: Bool { session.isRunning }

    var torchAvailable: Bool {
        guard let d = currentDevice else { return false }
        return d.hasTorch
    }

    func startStream(settings: AppSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.configure(settings: settings)
            self.session.startRunning()
        }
    }

    func stopStream() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    /// Список камер, реально доступных на устройстве
    static var availableCameras: [CameraSelection] {
        var result: [CameraSelection] = []
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) != nil { result.append(.back) }
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil { result.append(.ultraWide) }
        if AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil { result.append(.front) }
        return result
    }

    func switchCamera(to position: AppSettings.CameraSelection) {
        queue.async { [weak self] in
            guard let self else { return }
            self.currentPosition = position
            self.reconfigureCamera()
        }
    }

    func setTorch(on: Bool) {
        queue.async { [weak self] in
            guard let self, let d = self.currentDevice, d.hasTorch else { return }
            try? d.lockForConfiguration()
            d.torchMode = on ? .on : .off
            d.unlockForConfiguration()
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

    /// Точка фокуса в координатах превью (0...1). Tap-to-focus + блокировка экспозиции.
    func tapToFocus(at point: CGPoint) {
        queue.async { [weak self] in
            guard let self, let d = self.currentDevice else { return }
            let poi = CGPoint(x: point.x, y: point.y)
            guard d.isFocusPointOfInterestSupported, d.isExposurePointOfInterestSupported else { return }
            try? d.lockForConfiguration()
            d.focusPointOfInterest = poi
            d.focusMode = .autoFocus
            d.exposurePointOfInterest = poi
            d.exposureMode = .autoExpose
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
        currentPosition = settings.camera
        session.beginConfiguration()

        // Выбор устройства
        guard let device = device(for: settings.camera) else {
            AppLogger.error("Камера недоступна: \(settings.camera.rawValue)")
            session.commitConfiguration()
            return
        }
        currentDevice = device

        // Формат с нужным разрешением и fps
        let (w, h) = settings.resolution.size
        let targetFps = settings.fps
        var selectedFormat: AVCaptureDevice.Format?
        for format in device.formats {
            let desc = format.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            guard dims.width >= w, dims.height >= h else { continue }
            let ranges = format.videoSupportedFrameRateRanges
            guard ranges.contains(where: { $0.minFrameRate <= Double(targetFps) && $0.maxFrameRate >= Double(targetFps) }) else { continue }
            selectedFormat = format
            break
        }
        guard let format = selectedFormat ?? device.formats.first else {
            AppLogger.error("Нет подходящего формата")
            session.commitConfiguration()
            return
        }

        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        try? device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(targetFps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(targetFps))
        device.unlockForConfiguration()

        // Вход
        if session.inputs.isEmpty, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        } else if let existing = session.inputs.first as? AVCaptureDeviceInput {
            session.removeInput(existing)
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
            }
        }

        // Выход видео
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
        }

        // Ориентация потока
        if let connection = out.connection(with: .video) {
            applyOrientation(to: connection, camera: settings.camera)
        }

        session.commitConfiguration()
    }

    private func reconfigureCamera() {
        guard session.isRunning else {
            AppLogger.info("Сессия не запущена — конфигурация при старте")
            return
        }
        let wasRunning = session.isRunning
        session.stopRunning()
        session.beginConfiguration()
        if let input = session.inputs.first as? AVCaptureDeviceInput {
            session.removeInput(input)
        }
        guard let device = device(for: currentPosition) else {
            session.commitConfiguration()
            return
        }
        currentDevice = device
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
        }
        if let connection = videoOutput?.connection(with: .video) {
            applyOrientation(to: connection, camera: currentPosition)
        }
        session.commitConfiguration()
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
        guard connection.isVideoRotationAngleSupported(90) else { return }
        var angle: CGFloat
        switch orientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 180
        case .landscapeRight: angle = 0
        default: angle = 90
        }
        if camera == .front { angle = (360 - angle).truncatingRemainder(dividingBy: 360) }
        connection.videoRotationAngle = angle
    }
}

// MARK: - Сэмпл-делегат

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
