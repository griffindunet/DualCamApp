import SwiftUI
import AVFoundation

struct CameraView: View {
    @StateObject private var camera = CameraManager()
    @State private var pipOffset: CGSize = .zero
    @State private var pipPosition: CGSize = CGSize(width: 0, height: 0)
    @State private var showFlash = false
    @State private var capturedPreview = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.permissionGranted {
                // Back camera full screen
                BackPreviewView(session: camera.session, cameraManager: camera)
                    .ignoresSafeArea()
                    .gesture(MagnificationGesture()
                        .onChanged { value in
                            camera.setZoom(camera.zoomFactor * value)
                        }
                    )

                // Front camera PiP
                FrontPreviewView(session: camera.session, cameraManager: camera)
                    .frame(width: 120, height: 213)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white, lineWidth: 2))
                    .shadow(radius: 8)
                    .offset(x: pipPosition.width + pipOffset.width,
                            y: pipPosition.height + pipOffset.height)
                    .gesture(DragGesture()
                        .onChanged { value in pipOffset = value.translation }
                        .onEnded { value in
                            pipPosition.width += value.translation.width
                            pipPosition.height += value.translation.height
                            pipOffset = .zero
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 16)
                    .padding(.bottom, 160)

                // Flash overlay
                if showFlash {
                    Color.white.ignoresSafeArea()
                        .transition(.opacity)
                }

                // Controls
                VStack {
                    Spacer()
                    controlsBar
                }

                // Recording indicator
                if camera.isRecording {
                    VStack {
                        HStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 12, height: 12)
                                .opacity(camera.recordingTime.truncatingRemainder(dividingBy: 1) < 0.5 ? 1 : 0.3)
                            Text(timeString(camera.recordingTime))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.white)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Capsule())
                        }
                        .padding(.top, 60)
                        Spacer()
                    }
                }

                // Toast message
                if let msg = camera.errorMessage {
                    VStack {
                        Text(msg)
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.black.opacity(0.75))
                            .clipShape(Capsule())
                            .padding(.top, 110)
                        Spacer()
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            camera.errorMessage = nil
                        }
                    }
                }

                // Photo preview flash feedback
                if capturedPreview {
                    Color.white.opacity(0.6).ignoresSafeArea()
                        .allowsHitTesting(false)
                }

            } else {
                permissionView
            }
        }
        .onAppear { camera.requestPermissions() }
        .animation(.easeInOut(duration: 0.2), value: camera.isRecording)
    }

    // MARK: - Controls Bar
    var controlsBar: some View {
        HStack(spacing: 40) {
            // Flash toggle
            Button {
                camera.toggleFlash()
            } label: {
                Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash.fill")
                    .font(.title2)
                    .foregroundColor(camera.flashEnabled ? .yellow : .white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }

            // Record / Stop
            Button {
                if camera.isRecording {
                    camera.stopRecording()
                } else {
                    camera.startRecording()
                }
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white, lineWidth: 3)
                        .frame(width: 80, height: 80)
                    if camera.isRecording {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red)
                            .frame(width: 32, height: 32)
                    } else {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 64, height: 64)
                    }
                }
            }

            // Photo capture
            Button {
                withAnimation(.easeInOut(duration: 0.1)) { capturedPreview = true }
                camera.capturePhoto()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation { capturedPreview = false }
                }
            } label: {
                Image(systemName: "camera.fill")
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 52, height: 52)
                    .background(Color.white.opacity(0.15))
                    .clipShape(Circle())
            }
        }
        .padding(.bottom, 50)
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        )
    }

    // MARK: - Permission View
    var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.white.opacity(0.6))
            Text("Autorisation caméra requise")
                .font(.headline)
                .foregroundColor(.white)
            Text("Va dans Réglages > DualCam > Caméra & Micro")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Ouvrir les réglages") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .padding()
            .background(Color.white.opacity(0.2))
            .clipShape(Capsule())
            .foregroundColor(.white)
        }
    }

    // MARK: - Helpers
    func timeString(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - Preview Layers (UIViewRepresentable)

struct BackPreviewView: UIViewRepresentable {
    let session: AVCaptureMultiCamSession
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.videoOrientation = .portrait
        view.layer.addSublayer(layer)
        cameraManager.backPreviewLayer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        cameraManager.backPreviewLayer?.frame = uiView.bounds
    }
}

struct FrontPreviewView: UIViewRepresentable {
    let session: AVCaptureMultiCamSession
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.clipsToBounds = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.connection?.videoOrientation = .portrait
        if let conn = layer.connection, conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = true
        }
        view.layer.addSublayer(layer)
        cameraManager.frontPreviewLayer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        cameraManager.frontPreviewLayer?.frame = uiView.bounds
    }
}
