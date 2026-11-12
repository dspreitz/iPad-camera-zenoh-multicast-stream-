// Swift-Hülle um den C-Kern sender/csrc/zv_sender.c (zenoh-pico).
// Alle zenoh-Aufrufe laufen auf einer eigenen seriellen Queue (z_open/TCP dürfen blockieren).
import Foundation

final class ZenohPublisher {
    enum State: Equatable { case idle, connecting, connected, failed(String) }

    let mode: String
    let locator: String
    let key: String
    var paceMicros: Int32 = 0
    /// Wird aufgerufen, wenn wegen Rückstau Frames verworfen wurden -> Encoder soll Keyframe liefern.
    var onNeedKeyframe: (() -> Void)?
    var onState: ((State) -> Void)?

    private let queue = DispatchQueue(label: "zenoh.publisher", qos: .userInitiated)
    private var sender: OpaquePointer?
    private let lock = NSLock()
    private var pending = 0
    private var waitForKey = false
    private(set) var droppedFrames = 0
    private var lastStats = zv_stats_t()
    private var stopped = false

    /// mode "client" + locator "tcp/<Server-1-IP>:7447" (Standard), oder "peer" + "udp/224.0.0.225:7447#iface=en0"
    init(mode: String = "client", locator: String, key: String) {
        self.mode = mode
        self.locator = locator
        self.key = key
    }

    func start() {
        stopped = false
        queue.async { self.connectLoop() }
    }

    private func connectLoop() {
        while !stopped && sender == nil {
            onState?(.connecting)
            sender = zv_open(mode, locator, key, Int32(ZV_DEFAULT_MAX_PAYLOAD))
            if sender == nil {
                onState?(.failed("keine Verbindung zu \(locator)"))
                Thread.sleep(forTimeInterval: 2)
            }
        }
        if sender != nil { onState?(.connected) }
    }

    /// Thread-sicher; verwirft Frames, wenn mehr als ~1 s Rückstau entsteht.
    func send(annexB: Data, keyframe: Bool, ptsMs: UInt32, maxPending: Int = 15) {
        lock.lock()
        if waitForKey && !keyframe {
            droppedFrames += 1
            lock.unlock()
            return
        }
        if pending >= maxPending {
            droppedFrames += 1
            waitForKey = true
            lock.unlock()
            onNeedKeyframe?()
            return
        }
        if keyframe { waitForKey = false }
        pending += 1
        lock.unlock()
        queue.async {
            defer { self.lock.lock(); self.pending -= 1; self.lock.unlock() }
            guard let s = self.sender else { return }
            annexB.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: UInt8.self).baseAddress!
                _ = zv_send_au(s, p, raw.count, ptsMs, keyframe ? Int32(ZV_FLAG_KEY | ZV_FLAG_CONFIG) : 0, self.paceMicros)
            }
            var st = zv_stats_t()
            zv_get_stats(s, &st)
            self.lock.lock(); self.lastStats = st; self.lock.unlock()
        }
    }

    /// Blockiert nie (Kopie des letzten Stands von der Sende-Queue).
    func stats() -> zv_stats_t {
        lock.lock(); defer { lock.unlock() }
        return lastStats
    }

    func stop() {
        stopped = true
        queue.async {
            if let s = self.sender { zv_close(s) }
            self.sender = nil
            self.onState?(.idle)
        }
    }
}
