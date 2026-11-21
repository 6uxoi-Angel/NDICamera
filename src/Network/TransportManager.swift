import Foundation
import Network

/// Мониторинг сети + авто-reconnect.
///
/// Было: reconnect() дёргался на КАЖДОМ обновлении NWPathMonitor (первое —
/// мгновенно при attach, дальше — на любые флуктуации роутинга) и убивал/
/// пересоздавал NDI-отправителя посреди трансляции, усиливая гонки в SDK.
/// Стало: переподключение только при реальной смене статуса/набора интерфейсов.
final class TransportManager {
    private let settings: AppSettings
    private let bridge: NDIBridge
    private let monitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "transport.monitor")
    private var lastSignature: String?
    private var started = false

    init(settings: AppSettings, bridge: NDIBridge) {
        self.settings = settings
        self.bridge = bridge
    }

    func attach() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let interfaces = path.availableInterfaces.map(\.name).sorted()
            let signature = "\(path.status):\(interfaces.joined(separator: ","))"
            // Первый вызов — просто запоминаем состояние, reconnect не нужен
            guard let previous = self.lastSignature else {
                self.lastSignature = signature
                AppLogger.info("Сеть: \(path.status == .satisfied ? "доступна" : "недоступна") [\(interfaces.joined(separator: ", "))]")
                return
            }
            guard signature != previous else { return }
            self.lastSignature = signature
            if path.status == .satisfied {
                AppLogger.info("Сеть: изменилась → [\(interfaces.joined(separator: ", "))]")
                if self.bridge.isRunning {
                    self.bridge.reconnect(reason: "смена сети")
                }
            } else {
                AppLogger.warn("Сеть: потеря связи (\(path.status))")
            }
        }
        monitor.start(queue: monitorQueue)
    }

    func detach() {
        guard started else { return }
        started = false
        monitor.cancel()
    }

    deinit {
        monitor.cancel()
    }
}
