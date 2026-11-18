import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

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
            TextField("Локальный IP (пусто = авто, для выбора Wi-Fi/USB)", text: $model.settings.localInterfaceIP)
                .keyboardType(.numbersAndPunctuation)
        }
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
            VStack {
                HStack {
                    Text("Битрейт")
                    Spacer()
                    Text(String(format: "%.0f Мбит/с", model.settings.bitrateMbps))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $model.settings.bitrateMbps, in: 4...25, step: 1)
            }
            Picker("Камера", selection: $model.settings.camera) {
                ForEach(AppSettings.CameraSelection.allCases) { c in
                    Text(c.rawValue).tag(c)
                }
            }
            Toggle("Зеркалировать фронтальную", isOn: $model.settings.mirrorFront)
            Picker("Формат H.264", selection: $model.settings.h264Format) {
                ForEach(AppSettings.H264Format.allCases) { f in
                    Text(f.rawValue).tag(f)
                }
            }
            Text("Если в OBS чёрный экран — переключи формат (AVCC ↔ Annex-B)")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            Text("Изменения разрешения/битрейта применяются при следующем запуске")
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
