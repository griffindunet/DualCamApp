import AVFoundation
import UIKit
import Photos

class CameraManager: NSObject, ObservableObject {

    // MARK: - Published
    @Published var isRecording = false
    @Published var recordingTime: Double = 0
    @Published var flashEnabled = false
    @Published var zoomFactor: CGFloat = 1.0
    @Published var permissionGranted = false
    @Published var errorMessage: String? = nil
    @Published var lastCapturedImage: UIImage? = nil

    // MARK: - Session
    let session = AVCaptureMultiCamSession()

    // Back camera
    var backPreviewLayer: AVCaptureVideoPreviewLayer?
    var backOutput = AVCaptureMovieFileOutput()
    var backPhotoOutput = AVCapturePhotoOutput()
    var backDeviceInput: AVCaptureDeviceInput?

    // Front camera
    var frontPreviewLayer: AVCaptureVideoPreviewLayer?
    var frontOutput = AVCaptureMovieFileOutput()
    var frontPhotoOutput = AVCapturePhotoOutput()
    var frontDeviceInput: AVCaptureDeviceInput?

    // MARK: - Recording
    private var backTempURL: URL?
    private var frontTempURL: URL?
    private var backRecordingDone = false
    private var frontRecordingDone = false
    private var recordingTimer: Timer?

    // MARK: - Setup
    func requestPermissions() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if granted {
                AVCaptureDevice.requestAccess(for: .audio) { audioGranted in
                    DispatchQueue.main.async {
                        self.permissionGranted = granted && audioGranted
                        if self.permissionGranted {
                            self.setupSession()
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.permissionGranted = false
                    self.errorMessage = "Accès caméra refusé."
                }
            }
        }
    }

    func setupSession() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async {
                self.errorMessage = "Multi-caméra non supporté sur cet appareil."
            }
            return
        }

        session.beginConfiguration()

        // Back camera
        if let backDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let backInput = try? AVCaptureDeviceInput(device: backDevice) {
            if session.canAddInput(backInput) {
                session.addInputWithNoConnections(backInput)
                backDeviceInput = backInput
            }
            if session.canAddOutput(backOutput) {
                session.addOutputWithNoConnections(backOutput)
            }
            if session.canAddOutput(backPhotoOutput) {
                session.addOutputWithNoConnections(backPhotoOutput)
            }
            if let port = backInput.ports(for: .video, sourceDeviceType: backDevice.deviceType, sourceDevicePosition: .back).first {
                let backConnection = AVCaptureConnection(inputPorts: [port], output: backOutput)
                if session.canAddConnection(backConnection) { session.addConnection(backConnection) }
                let backPhotoConnection = AVCaptureConnection(inputPorts: [port], output: backPhotoOutput)
                if session.canAddConnection(backPhotoConnection) { session.addConnection(backPhotoConnection) }
            }
        }

        // Front camera
        if let frontDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           let frontInput = try? AVCaptureDeviceInput(device: frontDevice) {
            if session.canAddInput(frontInput) {
                session.addInputWithNoConnections(frontInput)
                frontDeviceInput = frontInput
            }
            if session.canAddOutput(frontOutput) {
                session.addOutputWithNoConnections(frontOutput)
            }
            if session.canAddOutput(frontPhotoOutput) {
                session.addOutputWithNoConnections(frontPhotoOutput)
            }
            if let port = frontInput.ports(for: .video, sourceDeviceType: frontDevice.deviceType, sourceDevicePosition: .front).first {
                let frontConnection = AVCaptureConnection(inputPorts: [port], output: frontOutput)
                if session.canAddConnection(frontConnection) { session.addConnection(frontConnection) }
                let frontPhotoConnection = AVCaptureConnection(inputPorts: [port], output: frontPhotoOutput)
                if session.canAddConnection(frontPhotoConnection) { session.addConnection(frontPhotoConnection) }
            }
        }

        // Audio
        if let audioDevice = AVCaptureDevice.default(for: .audio),
           let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
           session.canAddInput(audioInput) {
            session.addInputWithNoConnections(audioInput)
            for output in [backOutput, frontOutput] {
                if let audioPort = audioInput.ports(for: .audio, sourceDeviceType: audioDevice.deviceType, sourceDevicePosition: .unspecified).first {
                    let audioConn = AVCaptureConnection(inputPorts: [audioPort], output: output)
                    if session.canAddConnection(audioConn) { session.addConnection(audioConn) }
                }
            }
        }

        session.commitConfiguration()

        DispatchQueue.global(qos: .userInitiated).async {
            self.session.startRunning()
        }
    }

    // MARK: - Record Video
    func startRecording() {
        backTempURL = tempVideoURL(prefix: "back")
        frontTempURL = tempVideoURL(prefix: "front")
        backRecordingDone = false
        frontRecordingDone = false

        if let backURL = backTempURL {
            backOutput.startRecording(to: backURL, recordingDelegate: self)
        }
        if let frontURL = frontTempURL {
            frontOutput.startRecording(to: frontURL, recordingDelegate: self)
        }

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingTime = 0
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                self.recordingTime += 0.1
            }
        }
    }

    func stopRecording() {
        backOutput.stopRecording()
        frontOutput.stopRecording()
        recordingTimer?.invalidate()
        DispatchQueue.main.async { self.isRecording = false }
    }

    private func tempVideoURL(prefix: String) -> URL {
        let temp = FileManager.default.temporaryDirectory
        return temp.appendingPathComponent("\(prefix)_\(UUID().uuidString).mov")
    }

    // MARK: - Merge & Save
    private func checkAndMerge() {
        guard backRecordingDone && frontRecordingDone,
              let backURL = backTempURL,
              let frontURL = frontTempURL else { return }
        mergeVideos(backURL: backURL, frontURL: frontURL)
    }

    private func mergeVideos(backURL: URL, frontURL: URL) {
        let composition = AVMutableComposition()
        let videoComposition = AVMutableVideoComposition()

        let backAsset = AVAsset(url: backURL)
        let frontAsset = AVAsset(url: frontURL)

        guard let backVideoTrack = backAsset.tracks(withMediaType: .video).first,
              let frontVideoTrack = frontAsset.tracks(withMediaType: .video).first else { return }

        let duration = min(backAsset.duration, frontAsset.duration)
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        guard let compBackVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let compFrontVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { return }

        try? compBackVideo.insertTimeRange(timeRange, of: backVideoTrack, at: .zero)
        try? compFrontVideo.insertTimeRange(timeRange, of: frontVideoTrack, at: .zero)

        // Audio
        if let backAudioTrack = backAsset.tracks(withMediaType: .audio).first,
           let compAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? compAudio.insertTimeRange(timeRange, of: backAudioTrack, at: .zero)
        }

        // Layout : back full screen, front PiP bottom-right
        let outputSize = CGSize(width: 1080, height: 1920)
        let pipSize = CGSize(width: 270, height: 480)
        let pipOrigin = CGPoint(x: outputSize.width - pipSize.width - 20, y: outputSize.height - pipSize.height - 120)

        let backTransform = videoTransform(for: backVideoTrack, outputSize: outputSize, rect: CGRect(origin: .zero, size: outputSize))
        let frontTransform = videoTransform(for: frontVideoTrack, outputSize: outputSize, rect: CGRect(origin: pipOrigin, size: pipSize))

        let backInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compBackVideo)
        backInstruction.setTransform(backTransform, at: .zero)

        let frontInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: compFrontVideo)
        frontInstruction.setTransform(frontTransform, at: .zero)

        let mainInstruction = AVMutableVideoCompositionInstruction()
        mainInstruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        mainInstruction.layerInstructions = [frontInstruction, backInstruction]

        videoComposition.instructions = [mainInstruction]
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: 30)
        videoComposition.renderSize = outputSize

        // Export
        let outputURL = tempVideoURL(prefix: "merged")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { return }
        exporter.outputURL = outputURL
        exporter.outputFileType = .mov
        exporter.videoComposition = videoComposition

        exporter.exportAsynchronously {
            if exporter.status == .completed {
                PHPhotoLibrary.requestAuthorization { status in
                    if status == .authorized {
                        PHPhotoLibrary.shared().performChanges({
                            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                        }) { success, error in
                            DispatchQueue.main.async {
                                if success {
                                    self.errorMessage = "Vidéo sauvegardée ✅"
                                } else {
                                    self.errorMessage = "Erreur sauvegarde: \(error?.localizedDescription ?? "?")"
                                }
                            }
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.errorMessage = "Export échoué: \(exporter.error?.localizedDescription ?? "?")"
                }
            }
        }
    }

    private func videoTransform(for track: AVAssetTrack, outputSize: CGSize, rect: CGRect) -> CGAffineTransform {
        let trackSize = track.naturalSize
        let scaleX = rect.width / trackSize.width
        let scaleY = rect.height / trackSize.height
        let scale = CGAffineTransform(scaleX: scaleX, y: scaleY)
        let translate = CGAffineTransform(translationX: rect.origin.x, y: rect.origin.y)
        return scale.concatenating(translate)
    }

    // MARK: - Capture Photo
    func capturePhoto() {
        let settings = AVCapturePhotoSettings()
        if flashEnabled, let device = backDeviceInput?.device, device.hasFlash {
            settings.flashMode = .on
        }
        backPhotoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Zoom
    func setZoom(_ factor: CGFloat) {
        guard let device = backDeviceInput?.device else { return }
        let clamped = max(1.0, min(factor, device.activeFormat.videoMaxZoomFactor))
        try? device.lockForConfiguration()
        device.videoZoomFactor = clamped
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.zoomFactor = clamped }
    }

    // MARK: - Flash toggle
    func toggleFlash() {
        flashEnabled.toggle()
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate
extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        if output === backOutput {
            backRecordingDone = true
        } else if output === frontOutput {
            frontRecordingDone = true
        }
        checkAndMerge()
    }
}

// MARK: - AVCapturePhotoCaptureDelegate
extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { return }

        // Also capture front
        let frontSettings = AVCapturePhotoSettings()
        frontPhotoOutput.capturePhoto(with: frontSettings, delegate: FrontPhotoCaptureDelegate(backImage: image, manager: self))
    }
}

// Delegate pour fusionner les 2 photos
class FrontPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let backImage: UIImage
    weak var manager: CameraManager?

    init(backImage: UIImage, manager: CameraManager) {
        self.backImage = backImage
        self.manager = manager
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let frontImage = UIImage(data: data) else { return }

        let merged = mergePhotos(back: backImage, front: frontImage)
        DispatchQueue.main.async {
            self.manager?.lastCapturedImage = merged
        }
        UIImageWriteToSavedPhotosAlbum(merged, nil, nil, nil)
    }

    private func mergePhotos(back: UIImage, front: UIImage) -> UIImage {
        let size = back.size
        UIGraphicsBeginImageContextWithOptions(size, false, back.scale)
        back.draw(in: CGRect(origin: .zero, size: size))

        let pipW = size.width * 0.25
        let pipH = size.height * 0.25
        let pipX = size.width - pipW - 20
        let pipY = size.height - pipH - 120
        front.draw(in: CGRect(x: pipX, y: pipY, width: pipW, height: pipH))

        // Border around PiP
        let ctx = UIGraphicsGetCurrentContext()
        ctx?.setStrokeColor(UIColor.white.cgColor)
        ctx?.setLineWidth(3)
        ctx?.stroke(CGRect(x: pipX, y: pipY, width: pipW, height: pipH))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? back
    }
}
