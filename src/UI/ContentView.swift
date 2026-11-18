import SwiftUI
import AVFoundation
import UIKit

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    @State private var showSettings = false
    @State private var showLogs = false

    var body: some View {
        ZStack {
            LivePreviewView(camera: model.camera, mirror: model.settings.mirrorFront)
                .ignoresSafeArea()
                .overlay(tallyOverlay)
                .overlay(alignment: .top) { topBar }
                .overlay(alignment: .bottom) { bottomControls }
                .contentShape(Rectangle())
                .gesture(tapGesture)
                .simultaneousGesture(magnificationGesture)
        }
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: $showLogs) { LogsView().environmentObject(model) }
        .onAppear {
            Task {
                _ = await model.requestPermissions()
            }
        }
    }

    // MARK: - Tally

    @ViewBuilder private var tallyOverlay: some View {
        switch model.tally {
        case .program:
            TallyBorder(color: .red, label: "PROGRAM")
        case .preview:
            TallyBorder(color: .green, label: "PREVIEW")
        case .none:
            EmptyView()
        }
    }

    // MARK: - Верхняя панель

    private var topBar: some View {
        HStack {
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }

            Spacer()

            Text(streamStatusText)
                .font(.footnote.monospaced())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                showLogs = true
            } label: {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .padding(10)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var streamStatusText: String {
        if model.isStreaming {
            return String(format: "%.0f fps · %.0f kbps", model.stats.fps, model.stats.bitrateKbps)
        }
        return model.permissionGranted ? "Готово" : "Нет доступа"
    }

    // MARK: - Нижние элементы управления

    private var bottomControls: some View {
        VStack(spacing: 12) {
            // Экспозиция / фонарик / камера
            HStack(spacing: 20) {
                ControlButton(icon: "sun.max", label: "Эксп.") {
                    model.camera.toggleExposureLock()
                }
                if model.camera.torchAvailable {
                    ControlButton(icon: "flashlight.on.fill", label: "Фонарик") {
                        model.camera.setTorch(on: true)
                    }
                }
                ControlButton(icon: "arrow.triangle.2.circlepath", label: "Камера") {
                    switch model.settings.camera {
                    case .front: model.settings.camera = .back
                    case .back: model.settings.camera = .ultraWide
                    case .ultraWide: model.settings.camera = .front
                    }
                    model.camera.switchCamera(to: model.settings.camera)
                }
            }

            // Start/Stop
            Button(action: { model.toggleStreaming() }) {
                ZStack {
                    Circle()
                        .fill(model.isStreaming ? Color.red : Color.green)
                        .frame(width: 84, height: 84)
                    Circle()
                        .stroke(.white.opacity(0.9), lineWidth: 4)
                        .frame(width: 96, height: 96)
                    Text(model.isStreaming ? "STOP" : "START")
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.bottom, 24)
    }

    // MARK: - Жесты

    private var tapGesture: some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                model.camera.tapToFocus(at: CGPoint(x: value.location.x / UIScreen.main.bounds.width,
                                                    y: value.location.y / UIScreen.main.bounds.height))
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                // В новых SDK value — уже готовый коэффициент масштаба (CGFloat)
                model.camera.setZoom(value)
            }
    }
}

// MARK: - Tally рамка

struct TallyBorder: View {
    let color: Color
    let label: String

    var body: some View {
        ZStack {
            Rectangle()
                .stroke(color, lineWidth: 10)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Text(label)
                        .font(.headline.monospaced())
                        .foregroundStyle(color)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.6), in: Capsule())
                    Spacer()
                }
                Spacer()
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Кнопка

struct ControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .padding(10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
