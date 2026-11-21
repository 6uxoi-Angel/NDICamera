import Foundation
import Combine

struct BridgeConfig {
    var name: String
    var targetIP: String?          // ручной IP приёмника
    var discoveryServer: String?   // Discovery Server (fallback)
    var localIP: String?           // выбор интерфейса
    var fps: Int
}

extension BridgeConfig {
    init(settings: AppSettings) {
        name = settings.ndiName
        targetIP = settings.transportMode == .manual && !settings.manualIP.isEmpty ? settings.manualIP : nil
        discoveryServer = settings.transportMode == .discoveryServer && !settings.discoveryServerIP.isEmpty ? settings.discoveryServerIP : nil
        localIP = settings.localInterfaceIP.isEmpty ? nil : settings.localInterfaceIP
        fps = settings.fps
    }
    /// NTSC-подобные отношения для NDI (30 → 30000/1000)
    var fpsN: Int32 { Int32(fps * 1000) }
    var fpsD: Int32 { 1000 }
}

/// Фасад NDI: singleton. Отправляет видео/аудио, принимает tally.
///
/// Потокобезопасность:
/// - конфигурация и жизненный цикл — на сериальной `queue`;
/// - `isRunning` под лёгким замком (читается из потока камеры/аудио);
/// - Timer опроса tally создаётся/уничтожается ТОЛЬКО в main-потоке
///   (invalidate() из чужого потока — ещё один источник редких крэшей).
final class NDIBridge: ObservableObject {
    static let shared = NDIBridge()

    @Published private(set) var tally: TallyState = .none

    var onTally: ((TallyState) -> Void)?

    private let native = NDINative()
    private let queue = DispatchQueue(label: "ndi.bridge.queue")
    private let stateLock = NSLock()
    private var tallyTimer: Timer?          // только main-поток
    private var _config: BridgeConfig?
    private var _isRunning = false
    private var isPollScheduled = false

    private init() {}

    var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _isRunning
    }

    private func setRunning(_ v: Bool) {
        stateLock.lock(); _isRunning = v; stateLock.unlock()
    }

    private var config: BridgeConfig? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _config
    }

    // MARK: - Жизненный цикл

    func start(config: BridgeConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal()
            let ok = self.native.open(withName: config.name,
                                      targetIP: config.targetIP,
                                      discoveryServer: config.discoveryServer,
                                      localIP: config.localIP,
                                      fpsN: config.fpsN,
                                      fpsD: config.fpsD)
            if !ok {
                AppLogger.error("NDI не запустился: \(self.native.lastErrorMessage)")
                self.setRunning(false)
                return
            }
            self.stateLock.lock()
            self._config = config
            self._isRunning = true
            self.stateLock.unlock()
            self.startTallyPolling()
            AppLogger.info("NDI запущен: \(config.name) @\(config.fps)fps")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    /// Вызывается только с `queue`.
    private func stopInternal() {
        guard isRunning else { return }
        // Сначала гасим polling (safe invalidate в main), потом закрываем SDK.
        DispatchQueue.main.async {
            self.tallyTimer?.invalidate()
            self.tallyTimer = nil
        }
        native.close()
        setRunning(false)
        DispatchQueue.main.async {
            self.tally = .none
            self.onTally?(.none)
        }
        AppLogger.info("NDI остановлен")
    }

    func reconnect(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            // Переподключение нужно только когда трансляция реально шла.
            guard let cfg = self.config, self.isRunning else { return }
            AppLogger.info("NDI: переподключение (\(reason))")
            self.stopInternal()
            let ok = self.native.open(withName: cfg.name,
                                      targetIP: cfg.targetIP,
                                      discoveryServer: cfg.discoveryServer,
                                      localIP: cfg.localIP,
                                      fpsN: cfg.fpsN,
                                      fpsD: cfg.fpsD)
            if ok {
                self.setRunning(true)
                self.startTallyPolling()
                AppLogger.info("NDI: переподключение выполнено")
            } else {
                AppLogger.error("NDI: переподключение не удалось: \(self.native.lastErrorMessage)")
            }
        }
    }

    // MARK: - Отправка (вызывается из потоков камеры/аудио; безопасность — в NDINative)

    func sendVideoNV12(_ payload: Data, width: Int, height: Int, timecodeUs: UInt64) {
        guard isRunning else { return }
        native.sendVideoNV12(payload,
                             width: Int32(width),
                             height: Int32(height),
                             timecodeUs: Int64(timecodeUs))
    }

    func sendAudioFLTP(data: Data, samples: Int, channels: Int, sampleRate: Int, timecodeUs: UInt64) {
        guard isRunning, samples > 0 else { return }
        native.sendAudioFLTP(data,
                             channels: Int32(channels),
                             sampleRate: Int32(sampleRate),
                             timecodeUs: Int64(timecodeUs))
    }

    // MARK: - Tally

    private func startTallyPolling() {
        DispatchQueue.main.async {
            self.tallyTimer?.invalidate()
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.pollOnce()
            }
            RunLoop.main.add(timer, forMode: .common)
            self.tallyTimer = timer
        }
    }

    private func pollOnce() {
        // Не наслаиваем опросы, если очередь SDK занята отправкой
        stateLock.lock()
        if isPollScheduled { stateLock.unlock(); return }
        isPollScheduled = true
        stateLock.unlock()
        native.pollTally { [weak self] result in
            guard let self else { return }
            self.stateLock.lock(); self.isPollScheduled = false; self.stateLock.unlock()
            let state: TallyState = result == "program" ? .program : (result == "preview" ? .preview : .none)
            if self.tally != state {
                self.tally = state
                self.onTally?(state)
            }
        }
    }
}
