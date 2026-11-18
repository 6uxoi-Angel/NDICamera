import Foundation
import SwiftUI
import Combine
import UIKit
import AVFoundation

// MARK: - Настройки приложения (сохраняются в UserDefaults)

final class AppSettings: ObservableObject {
    enum TransportMode: String, CaseIterable, Identifiable {
        case auto = "Авто (mDNS)"
        case manual = "Ручной IP"
        case discoveryServer = "NDI Discovery Server"
        var id: String { rawValue }
    }
    enum VideoResolution: String, CaseIterable, Identifiable {
        case r720p = "720p"
        case r1080p = "1080p"
        case r4K = "4K"
        var id: String { rawValue }
        var size: (Int, Int) {
            switch self {
            case .r720p: return (1280, 720)
            case .r1080p: return (1920, 1080)
            case .r4K: return (3840, 2160)
            }
        }
    }
    enum CameraSelection: String, CaseIterable, Identifiable {
        case front = "Фронтальная"
        case back = "Основная (задняя)"
        case ultraWide = "Ультраширик"
        var id: String { rawValue }
    }
    enum H264Format: String, CaseIterable, Identifiable {
        case avcc = "AVCC"
        case annexB = "Annex-B"
        var id: String { rawValue }
    }

    @Published var ndiName: String { didSet { save() } }
    @Published var transportMode: TransportMode { didSet { save() } }
    @Published var manualIP: String { didSet { save() } }
    @Published var discoveryServerIP: String { didSet { save() } }
    @Published var localInterfaceIP: String { didSet { save() } }   // пусто = авто
    @Published var resolution: VideoResolution { didSet { save() } }
    @Published var fps: Int { didSet { save() } }
    @Published var bitrateMbps: Double { didSet { save() } }
    @Published var camera: CameraSelection { didSet { save() } }
    @Published var mirrorFront: Bool { didSet { save() } }
    @Published var audioEnabled: Bool { didSet { save() } }
    @Published var h264Format: H264Format { didSet { save() } }
    @Published var keepAwake: Bool { didSet { save() } }

    init() {
        let d = UserDefaults.standard
        ndiName = d.string(forKey: "ndiName") ?? "iPhoneCamera"
        transportMode = TransportMode(rawValue: d.string(forKey: "transportMode") ?? "") ?? .auto
        manualIP = d.string(forKey: "manualIP") ?? ""
        discoveryServerIP = d.string(forKey: "discoveryServerIP") ?? ""
        localInterfaceIP = d.string(forKey: "localInterfaceIP") ?? ""
        resolution = VideoResolution(rawValue: d.string(forKey: "resolution") ?? "") ?? .r1080p
        fps = d.object(forKey: "fps") as? Int ?? 30
        bitrateMbps = d.object(forKey: "bitrateMbps") as? Double ?? 8.0
        camera = CameraSelection(rawValue: d.string(forKey: "camera") ?? "") ?? .back
        mirrorFront = d.object(forKey: "mirrorFront") as? Bool ?? true
        audioEnabled = d.object(forKey: "audioEnabled") as? Bool ?? true
        h264Format = H264Format(rawValue: d.string(forKey: "h264Format") ?? "") ?? .avcc
        keepAwake = d.object(forKey: "keepAwake") as? Bool ?? true
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(ndiName, forKey: "ndiName")
        d.set(transportMode.rawValue, forKey: "transportMode")
        d.set(manualIP, forKey: "manualIP")
        d.set(discoveryServerIP, forKey: "discoveryServerIP")
        d.set(localInterfaceIP, forKey: "localInterfaceIP")
        d.set(resolution.rawValue, forKey: "resolution")
        d.set(fps, forKey: "fps")
        d.set(bitrateMbps, forKey: "bitrateMbps")
        d.set(camera.rawValue, forKey: "camera")
        d.set(mirrorFront, forKey: "mirrorFront")
        d.set(audioEnabled, forKey: "audioEnabled")
        d.set(h264Format.rawValue, forKey: "h264Format")
        d.set(keepAwake, forKey: "keepAwake")
    }
}

// MARK: - Общая модель приложения

enum TallyState: Equatable {
    case none, preview, program
}

struct StreamStats: Equatable {
    var fps: Double = 0
    var bitrateKbps: Double = 0
    var status: String = "Остановлено"
}

final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var isStreaming = false
    @Published var tally: TallyState = .none
    @Published var stats = StreamStats()
    @Published var permissionGranted = false

    let camera = CameraManager()
    let encoder = VideoEncoder()
    let audio = AudioCapturer()
    let bridge = NDIBridge.shared
    private var transport = TransportManager()
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        camera.onFrame = { [weak self] sb in self?.encoder.encode(sb) }
        encoder.onEncodedFrame = { [weak self] frame in self?.bridge.sendEncodedVideo(frame) }
        audio.onPCM = { [weak self] data, samples, ch, rate, ts in
            self?.bridge.sendAudioPCM(data: data, samples: samples, channels: ch, sampleRate: rate, timestampUs: ts)
        }
        bridge.onTally = { [weak self] t in self?.tally = t }

        transport = TransportManager(settings: settings, bridge: bridge, stats: { [weak self] s in self?.stats = s })
        transport.attach()

        NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.isStreaming else { return }
                self.stopStreaming(reason: "Приложение свернуто")
            }.store(in: &cancellables)
    }

    func requestPermissions() async -> Bool {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        permissionGranted = cam && mic
        return permissionGranted
    }

    func toggleStreaming() {
        isStreaming ? stopStreaming(reason: "Остановлено пользователем") : startStreaming()
    }

    func startStreaming() {
        AppLogger.info("Запуск трансляции: \(settings.ndiName), \(settings.resolution.rawValue)@\(settings.fps), \(Int(settings.bitrateMbps)) Мбит/с, транспорт \(settings.transportMode.rawValue)")
        if settings.transportMode == .manual, settings.manualIP.isEmpty {
            AppLogger.error("Ручной режим: не указан IP компьютера")
            return
        }
        do {
            try audio.prepare(rate: 48000)
            if settings.audioEnabled { try audio.start() }
        } catch {
            AppLogger.error("Аудио: \(error.localizedDescription)")
        }
        bridge.start(config: BridgeConfig(settings: settings))
        encoder.start(config: EncoderConfig(settings: settings))
        camera.startStream(settings: settings)
        isStreaming = true
        if settings.keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
        // Принудительный ключевой кадр, чтобы OBS подхватил источник быстро
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.encoder.forceKeyFrame()
        }
    }

    func stopStreaming(reason: String) {
        guard isStreaming else { return }
        AppLogger.info("Остановка трансляции: \(reason)")
        camera.stopStream()
        encoder.stop()
        audio.stop()
        bridge.stop()
        isStreaming = false
        tally = .none
        stats = StreamStats()
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
