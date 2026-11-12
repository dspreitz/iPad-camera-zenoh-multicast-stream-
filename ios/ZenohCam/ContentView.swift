// Oberfläche: Kameravorschau, Server-Adresse, Start/Stopp, Statistik.
// UNGETESTET auf echter Hardware.
import AVFoundation
import SwiftUI

struct ContentView: View {
    @StateObject private var ctl = StreamController()

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: ctl.camera.session).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("tcp/<zenoh-Server-1>:7447", text: $ctl.server)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .disabled(ctl.running)
                    Stepper("\(ctl.bitrateKbit) kbit/s", value: $ctl.bitrateKbit, in: 150...2000, step: 50)
                        .frame(maxWidth: 230)
                        .disabled(ctl.running)
                    Button(ctl.running ? "Stopp" : "Start") { ctl.running ? ctl.stop() : ctl.start() }
                        .buttonStyle(.borderedProminent)
                        .tint(ctl.running ? .red : .green)
                }
                Text(ctl.status).font(.headline)
                Text(ctl.statsText).font(.caption.monospaced())
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding()
        }
    }
}

/// AVCaptureVideoPreviewLayer in SwiftUI.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
