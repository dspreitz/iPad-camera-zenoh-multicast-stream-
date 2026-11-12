// Verbindet Kamera -> H.264-Encoder -> zenoh-Publisher und stellt Zustand/Statistik für die UI bereit.
// UNGETESTET auf echter Hardware. Encoder + Publisher sind über ios/mac-harness auf macOS getestet.
import AVFoundation
import Combine
import Foundation
#if os(iOS)
import UIKit
#endif

final class StreamController: ObservableObject {
    // Einstellungen (persistiert)
    @Published var server: String = UserDefaults.standard.string(forKey: "server") ?? "tcp/192.168.1.10:7447"
    @Published var key: String = UserDefaults.standard.string(forKey: "key") ?? "video/ipad/h264"
    @Published var bitrateKbit: Int = UserDefaults.standard.object(forKey: "kbit") as? Int ?? 220
    @Published var fps: Int = UserDefaults.standard.object(forKey: "fps") as? Int ?? 10

    // Zustand
    @Published var running = false
    @Published var status = "gestoppt"
    @Published var statsText = ""

    let camera = CameraCapture()
    private var encoder: H264Encoder?
    private var publisher: ZenohPublisher?
    private var timer: Timer?
    private var started = Date()
    private var encodedFrames = 0
    private var encodedBytes = 0

    func start() {
        guard !running else { return }
        UserDefaults.standard.set(server, forKey: "server")
        UserDefaults.standard.set(key, forKey: "key")
        UserDefaults.standard.set(bitrateKbit, forKey: "kbit")
        UserDefaults.standard.set(fps, forKey: "fps")
        CameraCapture.requestAccess { ok in
            guard ok else { self.status = "kein Kamerazugriff (Einstellungen > Datenschutz)"; return }
            do { try self.startPipeline() } catch { self.status = "Fehler: \(error.localizedDescription)" }
        }
    }

    private func startPipeline() throws {
        var cfg = H264Encoder.Config()
        cfg.fps = fps
        cfg.bitrate = bitrateKbit * 1000
        cfg.maxBitrate = bitrateKbit * 1100
        let enc = try H264Encoder(config: cfg)
        let pub = ZenohPublisher(mode: "client", locator: server.trimmingCharacters(in: .whitespaces), key: key)
        pub.onState = { [weak self] st in
            DispatchQueue.main.async {
                switch st {
                case .idle: self?.status = "gestoppt"
                case .connecting: self?.status = "verbinde mit \(self?.server ?? "")…"
                case .connected: self?.status = "sende"; enc.requestKeyframe()
                case .failed(let m): self?.status = m
                }
            }
        }
        pub.onNeedKeyframe = { enc.requestKeyframe() }
        enc.onFrame = { [weak self] data, isKey, pts in
            self?.encodedFrames += 1
            self?.encodedBytes += data.count
            pub.send(annexB: data, keyframe: isKey, ptsMs: pts)
        }
        try camera.configure(fps: fps)
        camera.onFrame = { pb, pts in enc.encode(pb, pts: pts) }
        encoder = enc
        publisher = pub
        encodedFrames = 0
        encodedBytes = 0
        started = Date()
        pub.start()
        camera.start()
        running = true
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #endif
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
    }

    func stop() {
        camera.stop()
        camera.onFrame = nil
        encoder?.invalidate()
        publisher?.stop()
        encoder = nil
        publisher = nil
        timer?.invalidate()
        running = false
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #endif
    }

    private func updateStats() {
        guard let pub = publisher else { return }
        let el = max(1, Date().timeIntervalSince(started))
        let st = pub.stats()
        statsText = String(format: "%.1f fps · Encoder %.0f kbit/s · zenoh %.0f kbit/s · %llu Keyframes · %llu Fragmente · verworfen %d · Fehler %llu",
                           Double(encodedFrames) / el, Double(encodedBytes) * 8 / el / 1000,
                           Double(st.bytes) * 8 / el / 1000, st.keyframes, st.fragments, pub.droppedFrames, st.put_errors)
    }
}
