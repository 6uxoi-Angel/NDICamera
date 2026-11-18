import Foundation
import Combine

struct BridgeConfig {
    var name: String
    var targetIP: String?          // ручной IP приёмника
    var discoveryServer: String?   // Discovery Server (fallback)
    var localIP: String?           // выбор интерфейса
    var h264Format: AppSettings.H264Format
}

extension BridgeConfig {
    init(settings: AppSettings) {
        name = settings.ndiName
        targetIP = settings.transportMode == .manual && !settings.manualIP.isEmpty ? settings.manualIP : nil
        discoveryServer = settings.transportMode == .discoveryServer && !settings.discoveryServerIP.isEmpty ? settings.discoveryServerIP : nil
        localIP = settings.localInterfaceIP.isEmpty ? nil : settings.localInterfaceIP
        h264Format = settings.h264Format
    }
}

/// Фасад NDI: singleton, потокобезопасный. Отправляет видео/аудио, принимает tally.
final class NDIBridge: ObservableObject {
    static let shared = NDIBridge()

    @Published private(set) var tally: TallyState = .none

    var onTally: ((TallyState) -> Void)?

    private let native = NDINative()
    private let queue = DispatchQueue(label: "ndi.bridge.queue")
    private var tallyTimer: Timer?
    private var config: BridgeConfig?
    private(set) var isRunning = false
    private var lastKeyFrameSent = false

    private init() {}

    // MARK: - Жизненный цикл

    func start(config: BridgeConfig) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopInternal()
            var err: NSError?
            let ok = self.native.open(withName: config.name,
                                      targetIP: config.targetIP,
                                      discoveryServer: config.discoveryServer,
                                      localIP: config.localIP,
                                      error: &err)
            if !ok {
                AppLogger.error("NDI не запустился: \(err?.localizedDescription ?? "неизвестно")")
                return
            }
            self.config = config
            self.isRunning = true
            self.startTallyPolling()
            AppLogger.info("NDI запущен: \(config.name)")
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func stopInternal() {
        guard isRunning else { return }
        native.close()
        isRunning = false
        stopTallyPolling()
        DispatchQueue.main.async {
            self.tally = .none
        }
        AppLogger.info("NDI остановлен")
    }

    func reconnect() {
        queue.async { [weak self] in
            guard let self, let cfg = self.config else { return }
            self.stopInternal()
            var err: NSError?
            if self.native.open(withName: cfg.name,
                                targetIP: cfg.targetIP,
                                discoveryServer: cfg.discoveryServer,
                                localIP: cfg.localIP,
                                error: &err) {
                self.isRunning = true
                self.startTallyPolling()
                AppLogger.info("NDI: переподключение выполнено")
            } else {
                AppLogger.error("NDI: переподключение не удалось: \(err?.localizedDescription ?? "")")
            }
        }
    }

    // MARK: - Отправка

    func sendEncodedVideo(_ frame: EncodedFrame) {
        guard isRunning else { return }
        // формат при необходимости
        var payload = frame.payload
        if frame.avcc != (config?.h264Format == .avcc) {
            payload = frame.avcc ? toAnnexB(payload) : toAVCC(payload)
        }
        self.native.sendVideoH264(payload,
                                  width: Int32(frame.width),
                                  height: Int32(frame.height),
                                  timestampUs: Int64(frame.timestampUs),
                                  keyFrame: frame.isKeyFrame,
                                  formatIsAvcc: (config?.h264Format == .avcc))
    }

    func sendAudioPCM(data: Data, samples: Int, channels: Int, sampleRate: Int, timestampUs: UInt64) {
        guard isRunning else { return }
        native.sendAudioPCM(data, channels: Int32(channels), sampleRate: Int32(sampleRate), timestampUs: Int64(timestampUs))
    }

    // MARK: - Tally

    private func startTallyPolling() {
        stopTallyPolling()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            let result = self.native.pollTally()
            let state: TallyState = result == "program" ? .program : (result == "preview" ? .preview : .none)
            DispatchQueue.main.async {
                if self.tally != state {
                    self.tally = state
                    self.onTally?(state)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tallyTimer = timer
    }

    private func stopTallyPolling() {
        tallyTimer?.invalidate()
        tallyTimer = nil
    }

    // MARK: - Форматы H.264

    /// AVCC → Annex-B
    private func toAnnexB(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var idx = 0
        while idx + 4 <= bytes.count {
            let len = Int(bytes[idx]) << 24 | Int(bytes[idx+1]) << 16 | Int(bytes[idx+2]) << 8 | Int(bytes[idx+3])
            idx += 4
            guard len > 0, idx + len <= bytes.count else { break }
            out.append(contentsOf: [0, 0, 0, 1])
            out.append(contentsOf: bytes[idx..<(idx+len)])
            idx += len
        }
        return out
    }

    /// Annex-B → AVCC
    private func toAVCC(_ data: Data) -> Data {
        var out = Data()
        let bytes = [UInt8](data)
        var idx = 0
        while idx < bytes.count {
            // ищем старт-код
            guard bytes[idx] == 0, idx + 3 < bytes.count, bytes[idx+1] == 0, bytes[idx+2] == 0 else {
                // просто копируем остаток
                out.append(contentsOf: bytes[idx...])
                break
            }
            var naluStart = idx + 3
            if bytes[naluStart] == 1 { naluStart += 1 }
            else if bytes[naluStart] == 0 { naluStart += 1 } // 4-байтовый код
            // конец NAL
            var end = naluStart
            while end + 3 < bytes.count, !(bytes[end] == 0 && bytes[end+1] == 0 && (bytes[end+2] == 1 || (bytes[end+3] == 1 && bytes[end+2] == 0))) {
                end += 1
            }
            let len = end - naluStart
            out.append(contentsOf: withUnsafeBytes(of: UInt32(len).bigEndian) { Data($0) })
            out.append(contentsOf: bytes[naluStart..<end])
            idx = end
        }
        return out
    }
}
