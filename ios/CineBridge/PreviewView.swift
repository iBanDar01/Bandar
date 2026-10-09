import SwiftUI
import AVFoundation

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onTapDevicePoint: (CGPoint) -> Void

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.previewView = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.previewLayer.session = session
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTapDevicePoint: onTapDevicePoint)
    }

    final class Coordinator: NSObject {
        weak var previewView: PreviewUIView?
        private let onTapDevicePoint: (CGPoint) -> Void

        init(onTapDevicePoint: @escaping (CGPoint) -> Void) {
            self.onTapDevicePoint = onTapDevicePoint
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = previewView else { return }
            let layerPoint = recognizer.location(in: view)
            let devicePoint = view.previewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onTapDevicePoint(devicePoint)
        }
    }
}
