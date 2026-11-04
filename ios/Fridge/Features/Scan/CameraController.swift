import AVFoundation
import SwiftUI
import UIKit

/// F1.1: the back camera via AVCaptureSession. Photos are delivered as in-memory Data;
/// nothing is saved to the camera roll or disk.
@MainActor
final class CameraController: NSObject, ObservableObject {
    enum Access { case unknown, granted, denied, unavailable }

    @Published private(set) var access: Access = .unknown
    @Published private(set) var isCapturing = false

    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var onPhoto: ((Data) -> Void)?

    func requestAccessAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: access = .granted
        case .notDetermined:
            access = await AVCaptureDevice.requestAccess(for: .video) ? .granted : .denied
        default: access = .denied
        }
        guard access == .granted else { return }
        guard configure() else { access = .unavailable; return }
        let session = self.session
        await Task.detached { if !session.isRunning { session.startRunning() } }.value
    }

    func stop() {
        let session = self.session
        Task.detached { if session.isRunning { session.stopRunning() } }
    }

    func capture(_ completion: @escaping (Data) -> Void) {
        guard configured, !isCapturing else { return }
        isCapturing = true
        onPhoto = completion
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    private func configure() -> Bool {
        if configured { return true }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return false }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
        return true
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        let data = photo.fileDataRepresentation()
        Task { @MainActor in
            self.isCapturing = false
            if let data { self.onPhoto?(data) }
            self.onPhoto = nil
        }
    }
}

/// Live camera preview.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}
}
