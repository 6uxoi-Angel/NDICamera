import SwiftUI
import AVFoundation

/// Превью с камеры (AVCaptureVideoPreviewLayer) с зеркалированием фронталки.
struct LivePreviewView: UIViewRepresentable {
    let camera: CameraManager
    let mirror: Bool

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = camera.previewLayer.session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if camera.isRunning {
            uiView.videoPreviewLayer.connection?.videoRotationAngle = camera.previewLayer.connection?.videoRotationAngle ?? 90
        }
        // Зеркалирование фронтальной камеры
        uiView.videoPreviewLayer.setAffineTransform(mirror ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
    }

    final class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
