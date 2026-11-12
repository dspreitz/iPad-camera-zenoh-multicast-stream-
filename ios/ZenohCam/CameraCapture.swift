// Kamera-Erfassung mit AVCaptureSession (Rückkamera, 1280x720, feste Bildrate).
// UNGETESTET auf echter Hardware (kein iPad/Xcode in der Entwicklungsumgebung).
import AVFoundation

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private let queue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private var configured = false
    // Bildrate in Software begrenzen: Manche Kameras (z. B. die Mac-Kamera) ignorieren die
    // eingestellte Bildrate und liefern 30 fps. Überzählige Bilder werden vor dem Encoder verworfen.
    private var frameInterval = CMTime.invalid
    private var nextDue = CMTime.invalid
    private(set) var droppedForRate = 0

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { ok in DispatchQueue.main.async { done(ok) } }
    }

    func configure(fps: Int) throws {
        guard !configured else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // 1280x720 statt 640x360: Preset gibt es auf allen iPads; VideoToolbox skaliert beim Kodieren
        // (im macOS-Harness geprüft). Spart eine eigene Skalierung.
        session.sessionPreset = .hd1280x720
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "CameraCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "keine Kamera"])
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw NSError(domain: "CameraCapture", code: 2) }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw NSError(domain: "CameraCapture", code: 3) }
        session.addOutput(output)

        // Bildrate fest einstellen (spart Energie und hält die Bitrate pro Bild konstant)
        try device.lockForConfiguration()
        let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
        frameInterval = dur
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= Double(fps) }) {
            device.activeVideoMinFrameDuration = dur
            device.activeVideoMaxFrameDuration = dur
        }
        device.unlockForConfiguration()

        // Querformat (App ist auf Landscape festgelegt). Rückkamera: 0° = Landscape mit Home-Taste/USB rechts.
        if let conn = output.connection(with: .video) {
            #if os(iOS)
            if #available(iOS 17.0, *) {
                if conn.isVideoRotationAngleSupported(0) { conn.videoRotationAngle = 0 }
            } else if conn.isVideoOrientationSupported {
                conn.videoOrientation = .landscapeRight
            }
            if conn.isVideoStabilizationSupported { conn.preferredVideoStabilizationMode = .off } // Latenz
            #endif
        }
        configured = true
    }

    func start() { queue.async { if !self.session.isRunning { self.session.startRunning() } } }
    func stop() { queue.async { if self.session.isRunning { self.session.stopRunning() } } }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if frameInterval.isValid {
            // Toleranz von einem Viertel Intervall, damit leicht frühe Bilder nicht verworfen werden.
            let tolerance = CMTimeMultiplyByFloat64(frameInterval, multiplier: 0.25)
            if nextDue.isValid && CMTimeCompare(pts, CMTimeSubtract(nextDue, tolerance)) < 0 {
                droppedForRate += 1
                return
            }
            let next = nextDue.isValid ? CMTimeAdd(nextDue, frameInterval) : CMTimeAdd(pts, frameInterval)
            // Nach einer Lücke nicht aufholen, sondern vom aktuellen Bild aus weiterzählen.
            nextDue = CMTimeCompare(next, pts) <= 0 ? CMTimeAdd(pts, frameInterval) : next
        }
        onFrame?(pb, pts)
    }
}
