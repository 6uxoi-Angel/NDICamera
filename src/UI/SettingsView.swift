import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var interfaces: [LocalInterface] = NetworkInterfaces.all()

    var body: some View {
        NavigationStack {
            Form {
                sourceSection
                transportSection
                videoSection
                audioSection
                behaviorSection
            }
            .navigationTitle("Настройки")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var sourceSection: some View {
        Section("Источник NDI") {
            TextField("Имя источника", text: $model.settings.ndiName)
            Text("Будет видно в OBS/DistroAV как \(model.settings.ndiName)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var transportSection: some View {
        Section("Транспорт") {
            Picker("Режим", selection: $model.settings.transportMode) {
                ForEach(AppSettings.TransportMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            if model.settings.transportMode == .manual {
                TextField("IP компьютера (напр. 192.168.1.50)", text: $model.settings.manualIP)
                    .keyboardType(.numbersAndPunctuation)
            }
            if model.settings.transportMode == .discoveryServer {
                TextField("Адрес Discovery Server", text: $model.settings.discoveryServerIP)
                    .keyboardType(.numbersAndPunctuation)
            }

            // Выбор интерфейса: Wi-Fi / USB / авто
            Picker("Интерфейс", selection: $model.settings.localInterfaceIP) {
                Text("Авто").tag("")
                ForEach(interfaces + missingCurrent) { i in
                    Text(i.label).tag(i.ip)
                }
            }
            .onAppear { interfaces = NetworkInterfaces.all() }

            Text(interfaceHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Если сохранённый IP уже не виден в списке (напр. отключили USB) —
    /// держим его в Picker'е, чтобы выбор не «слетал» молча.
    private var missingCurrent: [LocalInterface] {
        let sel = model.settings.localInterfaceIP
        guard !sel.isEmpty, !interfaces.contains(where: { $0.ip == sel }) else { return [] }
        return [LocalInterface(name: "?", ip: sel)]
    }

    private var interfaceHint: String {
        if let usb = interfaces.first(where: { $0.isUSB }) {
            return "Найден USB-интерфейс: \(usb.ip). Чтобы трафик шёл по кабелю, выключи Wi-Fi на iPhone (иначе NDI выберет Wi-Fi). На ПК: ipconfig /all — диапазон сети должен совпасть."
        }
        return "Для работы по USB: подключи iPhone кабелем, на iPhone включи Настройки → Personal Hotspot (режим USB), затем выбери USB-интерфейс здесь."
    }


    private var videoSection: some View {
        Section("Видео") {
            Picker("Разрешение", selection: $model.settings.resolution) {
                ForEach(AppSettings.VideoResolution.allCases) { r in
                    Text(r.rawValue).tag(r)
                }
            }
            Picker("fps", selection: $model.settings.fps) {
                Text("30").tag(30)
                Text("60").tag(60)
            }
            Text("Полный NDI (NV12, без сжатия): ~\(Int(model.settings.resolution.approxMbps(fps: model.settings.fps))) Мбит/с. Для Wi-Fi достаточно 720p30.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Камера", selection: $model.settings.camera) {
                ForEach(AppSettings.CameraSelection.allCases) { c in
                    Text(c.rawValue).tag(c)
                }
            }
            Toggle("Зеркалировать фронтальную", isOn: $model.settings.mirrorFront)
        }
    }

    private var audioSection: some View {
        Section("Аудио") {
            Toggle("Передавать звук (48 кГц)", isOn: $model.settings.audioEnabled)
        }
    }

    private var behaviorSection: some View {
        Section("Поведение") {
            Toggle("Не гасить экран при трансляции", isOn: $model.settings.keepAwake)
            Text("Изменения разрешения/fps применяются при следующем запуске")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LogsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List(AppLogger.shared.lines.reversed()) { line in
                HStack(alignment: .top) {
                    Text(line.level)
                        .font(.caption2.monospaced())
                        .foregroundStyle(line.level == "ERROR" ? .red : (line.level == "WARN" ? .orange : .secondary))
                        .frame(width: 44, alignment: .leading)
                    Text(line.message)
                        .font(.caption.monospaced())
                }
            }
            .navigationTitle("Лог")
        }
    }
}
