// macOS-Test-Harness für den iPad-Code OHNE iPad/Xcode:
// synthetische Kamerabilder (1280x720, wie AVCaptureSession .hd1280x720) -> H264Encoder (VideoToolbox, skaliert auf
// 640x360) -> ZenohPublisher (zenoh-pico, C-Kern) -> zenoh-Server 1.
// Aufruf: zv-mac-harness [locator=tcp/127.0.0.1:17447] [sekunden=30] [kbit=220] [fps=10] [camera]
//   "camera" = statt Testbild die Mac-Kamera über CameraCapture.swift (derselbe Code wie auf dem iPad;
//   macOS fragt beim ersten Mal nach Kamerazugriff für das Terminal). Nicht automatisiert getestet.
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

let args = CommandLine.arguments
let locator = args.count > 1 ? args[1] : "tcp/127.0.0.1:17447"
let seconds = args.count > 2 ? Double(args[2])! : 30
let kbit = args.count > 3 ? Int(args[3])! : 220
let fps = args.count > 4 ? Int(args[4])! : 10

var cfg = H264Encoder.Config()
cfg.bitrate = kbit * 1000
cfg.maxBitrate = Int(Double(kbit) * 1.1) * 1000
cfg.fps = fps
let encoder = try H264Encoder(config: cfg)
let publisher = ZenohPublisher(mode: "client", locator: locator, key: "video/ipad/h264")
publisher.onState = { print("[harness] zenoh: \($0)") }
publisher.onNeedKeyframe = { encoder.requestKeyframe() }
var frames = 0, keyframes = 0, bytes = 0, maxAU = 0
let statLock = NSLock()
encoder.onFrame = { data, key, pts in
    statLock.lock(); frames += 1; keyframes += key ? 1 : 0; bytes += data.count; maxAU = max(maxAU, data.count); statLock.unlock()
    publisher.send(annexB: data, keyframe: key, ptsMs: pts)
}
publisher.start()
Thread.sleep(forTimeInterval: 1.5)

// Pixelbuffer-Pool 1280x720 BGRA; Inhalt: bewegte Balken + Rauschen-Streifen + Uhr-Balken
let W = 1280, H = 720
var pool: CVPixelBufferPool?
CVPixelBufferPoolCreate(nil, nil, [
    kCVPixelBufferWidthKey: W, kCVPixelBufferHeightKey: H,
    kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
    kCVPixelBufferIOSurfacePropertiesKey: [:],
] as CFDictionary, &pool)

func render(_ pb: CVPixelBuffer, _ n: Int) {
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: W, height: H, bitsPerComponent: 8,
                        bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)  // Ursprung oben links wie im Pixelbuffer
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(1,1,1),(1,1,0),(0,1,1),(0,1,0),(1,0,1),(1,0,0),(0,0,1)]
    for (i, c) in colors.enumerated() {
        ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
        ctx.fill(CGRect(x: i * W / 7, y: 0, width: W / 7 + 1, height: H))
    }
    ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
    let x = (n * 12) % W
    ctx.fill(CGRect(x: x, y: H / 3, width: 120, height: 120))
    // Sekundenzeiger-Balken: Breite = Millisekunden der aktuellen Sekunde
    let ms = Int(Date().timeIntervalSince1970 * 1000) % 1000
    ctx.fill(CGRect(x: 0, y: H - 60, width: ms * W / 1000, height: 60))
    // etwas "Sensorrauschen"
    for _ in 0..<300 {
        ctx.setFillColor(gray: CGFloat.random(in: 0...1), alpha: 1)
        ctx.fill(CGRect(x: Int.random(in: 0..<W), y: Int.random(in: 0..<H), width: 4, height: 4))
    }
}

if args.count > 5 && args[5] == "camera" {
    let cam = CameraCapture()
    let sem = DispatchSemaphore(value: 0)
    var granted = false
    AVCaptureDevice.requestAccess(for: .video) { granted = $0; sem.signal() }
    sem.wait()
    guard granted else { print("[harness] kein Kamerazugriff"); exit(1) }
    try cam.configure(fps: fps)
    cam.onFrame = { pb, pts in encoder.encode(pb, pts: pts) }
    cam.start()
    let t0 = Date()
    while Date().timeIntervalSince(t0) < seconds {
        Thread.sleep(forTimeInterval: 5)
        let el = Date().timeIntervalSince(t0); let st = publisher.stats()
        statLock.lock()
        print(String(format: "[harness] %d frames (%.1f fps), %d key, Encoder %.0f kbit/s, max AU %d B | zenoh %.0f kbit/s, verworfen %d",
                     frames, Double(frames) / el, keyframes, Double(bytes) * 8 / el / 1000, maxAU, Double(st.bytes) * 8 / el / 1000, publisher.droppedFrames))
        statLock.unlock(); fflush(stdout)
    }
    cam.stop(); encoder.invalidate(); publisher.stop(); Thread.sleep(forTimeInterval: 0.5)
    exit(0)
}

let start = Date()
var n = 0
var lastPrint = Date()
while Date().timeIntervalSince(start) < seconds {
    let due = start.addingTimeInterval(Double(n) / Double(fps))
    let wait = due.timeIntervalSinceNow
    if wait > 0 { Thread.sleep(forTimeInterval: wait) }
    var pb: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
    render(pb!, n)
    encoder.encode(pb!, pts: CMTime(value: CMTimeValue(n), timescale: CMTimeScale(fps)))
    n += 1
    if Date().timeIntervalSince(lastPrint) >= 5 {
        lastPrint = Date()
        let el = Date().timeIntervalSince(start)
        let st = publisher.stats()
        statLock.lock()
        print(String(format: "[harness] %d frames (%.1f fps), %d key, Encoder %.0f kbit/s, max AU %d B | zenoh: %llu frags, %.0f kbit/s, put_errors %llu, verworfen %d",
                     frames, Double(frames) / el, keyframes, Double(bytes) * 8 / el / 1000, maxAU,
                     st.fragments, Double(st.bytes) * 8 / el / 1000, st.put_errors, publisher.droppedFrames))
        statLock.unlock()
        fflush(stdout)
    }
}
encoder.invalidate()
Thread.sleep(forTimeInterval: 0.5)
publisher.stop()
Thread.sleep(forTimeInterval: 0.5)
print("[harness] fertig")
