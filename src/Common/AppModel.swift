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
        /// Приблизительный поток Full NDI (несжатый NV12), Мбит/с
        func approxMbps(fps: Int) -> Double {
            let (w, h) = size
            return Double(w * h * 3 / 2 * 8 * fps) / 1_000_000.0
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
    @Published var bitrateMbps: Double { didSet { save() } }        // наследие HX, не используется
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
        // По умолчанию 720p30: Full NDI по Wi-Fi тянет только такой поток
        resolution = VideoResolution(rawValue: d.string(forKey: "resolution") ?? "") ?? .r720p
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
    private var transport: TransportManager?          // должен ЖИТЬ — иначе монитор сети не работает
    private var statsTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func setup() {
        camera.onFrame = { [weak self] sb in self?.encoder.encode(sb) }
        encoder.onEncodedFrame = { [weak self] frame in
            self?.bridge.sendVideoNV12(frame.payload,
                                       width: frame.width,
                                       height: frame.height,
                                       timecodeUs: frame.timecodeUs)
        }
        audio.onPCM = { [weak self] data, samples, ch, rate, ts in
            self?.bridge.sendAudioFLTP(data: data, samples: samples, channels: ch, sampleRate: rate, timecodeUs: ts)
        }
        bridge.onTally = { [weak self] t in self?.tally = t }

        let transport = TransportManager(settings: settings, bridge: bridge)
        transport.attach()
        self.transport = transport

        // Статистика раз в секунду из реальных счётчиков энкодера
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.isStreaming {
                let fps = self.encoder.currentFPS
                let kbps = self.encoder.currentBitrateKbps * 1000.0
                let state = self.bridge.isRunning ? "NDI активен" : "NDI восстанавливается…"
                self.stats = StreamStats(fps: fps, bitrateKbps: kbps, status: state)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        statsTimer = timer

        let stopObserver = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                guard let self, self.isStreaming else { return }
                self.stopStreaming(reason: "Приложение свернуто")
            }
        stopObserver.store(in: &cancellables)
    }

    func requestPermissions() async -> Bool {
        let cam = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        permissionGranted = cam && mic
        if !cam { AppLogger.error("Нет доступа к камере — включи в Настройки → Конфиденциальность") }
        if !mic { AppLogger.warn("Нет доступа к микрофону — звук передаваться не будет") }
        return permissionGranted
    }

    func toggleStreaming() {
        isStreaming ? stopStreaming(reason: "Остановлено пользователем") : startStreaming()
    }

    func startStreaming() {
        guard !isStreaming else { return }
        guard permissionGranted else {
            AppLogger.error("Нет разрешений (камера/микрофон) — транслировать нечем")
            Task { await requestPermissions() }
            return
        }
        AppLogger.info("Запуск трансляции: \(settings.ndiName), \(settings.resolution.rawValue)@\(settings.fps), транспорт \(settings.transportMode.rawValue), ~\(Int(settings.resolution.approxMbps(fps: settings.fps))) Мбит/с")
        if settings.transportMode == .manual, settings.manualIP.isEmpty {
            AppLogger.error("Ручной режим: не указан IP компьютера")
            return
        }
        if !AppSettings.CameraSelection.availableCameras.contains(settings.camera) {
            AppLogger.warn("Камера \(settings.camera.rawValue) недоступна — переключаюсь на заднюю")
            settings.camera = .back
        }
        do {
            AppLogger.info("[stage] подготовка аудио...")
            try audio.prepare(rate: 48000)
            if settings.audioEnabled {
                AppLogger.info("[stage] запуск аудио-tap...")
                try audio.start()
                AppLogger.info("[stage] аудио запущено")
            }
        } catch {
            AppLogger.error("Аудио: \(error.localizedDescription) — продолжаю без звука")
        }
        AppLogger.info("[stage] старт NDI-моста...")
        bridge.start(config: BridgeConfig(settings: settings))
        AppLogger.info("[stage] NDI-мост запускается, старт видео...")
        encoder.start(config: EncoderConfig(settings: settings))
        AppLogger.info("[stage] камера стартует...")
        camera.startStream(settings: settings)
        isStreaming = true
        if settings.keepAwake { UIApplication.shared.isIdleTimerDisabled = true }
    }

    func stopStreaming(reason: String) {
        guard isStreaming else { return }
        isStreaming = false
        AppLogger.info("Остановка трансляции: \(reason)")
        camera.stopStream()
        encoder.stop()
        audio.stop()
        bridge.stop()
        tally = .none
        stats = StreamStats()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    deinit {
        statsTimer?.invalidate()
        transport?.detach()
    }
}
