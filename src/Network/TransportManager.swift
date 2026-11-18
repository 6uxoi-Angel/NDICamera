import Foundation
import Network
import Combine

/// Мониторинг сети + авто-reconnect.
/// При смене интерфейса/обрыве — пересоздаёт NDI-отправителя.
final class TransportManager {
    private let settings: AppSettings
    private let bridge: NDIBridge
    private let onStats: (StreamStats) -> Void
    private var monitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var healthTimer: Timer?

    init(settings: AppSettings, bridge: NDIBridge, stats: @escaping (StreamStats) -> Void) {
        self.settings = settings
        self.bridge = bridge
        self.onStats = stats
    }

    func attach() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let status = path.status
            self.lastPathStatus = status
            if status == .satisfied {
                AppLogger.info("Сеть: доступна (\(path.availableInterfaces.map { $0.name }))")
                // Если стрим должен идти, а NDI не активен — перезапускаем
                if self.settings.transportMode != .manual {
                    self.bridge.reconnect()
                }
            } else {
                AppLogger.warn("Сеть: потеряна связи (\(status))")
            }
        }
        m.start(queue: DispatchQueue(label: "transport.monitor"))
        monitor = m

        healthTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.bridge.isRunning {
                self.onStats(StreamStats(fps: self.bridge.isRunning ? 1 : 0, bitrateKbps: 0, status: "NDI активен"))
            }
        }
    }

    deinit {
        monitor?.cancel()
        healthTimer?.invalidate()
    }
}
