// H.264-Encoder mit VideoToolbox (Hardware), Ausgabe als Annex-B-Access-Units.
// Läuft auf iOS und macOS (macOS nur für den Test-Harness in ios/mac-harness).
import CoreMedia
import Foundation
import VideoToolbox

final class H264Encoder {
    struct Config {
        var width = 640
        var height = 360
        var fps = 10
        var bitrate = 220_000          // bit/s, Mittelwert
        var maxBitrate = 250_000       // bit/s, harte Grenze über 1 s (DataRateLimits)
        var keyframeIntervalSec = 1.0  // max. Wartezeit nach Verlust bis zum Bild
    }

    /// annexB, isKeyframe, ptsMs (Wanduhr bei Aufnahme, ms mod 2^32)
    var onFrame: ((Data, Bool, UInt32) -> Void)?
    private(set) var config: Config
    private var session: VTCompressionSession?
    private var forceKey = false
    private static let startCode: [UInt8] = [0, 0, 0, 1]

    init(config: Config) throws {
        self.config = config
        try createSession()
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session {
            VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(s)
        }
        session = nil
    }

    /// Nächstes Bild als Keyframe erzwingen (z.B. nach verworfenen Frames oder neuem Empfänger).
    func requestKeyframe() { forceKey = true }

    private func createSession() throws {
        // Low-Latency-Ratenregelung (iOS 14.5+/macOS 11.3+): kein Frame-Reordering, gleichmäßige Rate.
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]
        var s: VTCompressionSession?
        let st = VTCompressionSessionCreate(
            allocator: nil, width: Int32(config.width), height: Int32(config.height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        guard st == noErr, let s else { throw NSError(domain: "H264Encoder", code: Int(st)) }
        session = s
        let profile: CFString
        if #available(iOS 15.0, macOS 12.0, *) {
            profile = kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
        } else {
            profile = kVTProfileLevel_H264_Baseline_AutoLevel
        }
        let props: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: profile,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_AverageBitRate: config.bitrate,
            // [Bytes, Sekunden]: höchstens maxBitrate/8 Bytes pro Sekunde
            kVTCompressionPropertyKey_DataRateLimits: [config.maxBitrate / 8, 1] as CFArray,
            kVTCompressionPropertyKey_ExpectedFrameRate: config.fps,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(Double(config.fps) * config.keyframeIntervalSec),
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: config.keyframeIntervalSec,
        ]
        for (k, v) in props {
            let r = VTSessionSetProperty(s, key: k, value: v as CFTypeRef)
            if r != noErr { NSLog("H264Encoder: Property %@ nicht gesetzt (%d)", k as String, r) }
        }
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// pixelBuffer darf eine andere Größe haben (z.B. 1280x720 von der Kamera); VideoToolbox skaliert.
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let s = session else { return }
        let wallMs = UInt32(truncatingIfNeeded: Int64(Date().timeIntervalSince1970 * 1000))
        var frameProps: CFDictionary?
        if forceKey {
            forceKey = false
            frameProps = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            s, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: frameProps, infoFlagsOut: nil
        ) { [weak self] status, _, sbuf in
            guard status == noErr, let sbuf, let self else { return }
            if let (data, key) = Self.annexB(from: sbuf) {
                self.onFrame?(data, key, wallMs)
            }
        }
    }

    /// AVCC (Längenpräfix) -> Annex-B (Startcodes); bei Keyframes SPS/PPS voranstellen.
    static func annexB(from sbuf: CMSampleBuffer) -> (Data, Bool)? {
        guard let block = CMSampleBufferGetDataBuffer(sbuf),
              let fmt = CMSampleBufferGetFormatDescription(sbuf) else { return nil }
        var isKey = true
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sbuf, createIfNecessary: false) as? [[CFString: Any]],
           let first = atts.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        var out = Data()
        var nalLenSize: Int32 = 4
        if isKey {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLenSize)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil) == noErr, let ptr {
                    out.append(contentsOf: startCode)
                    out.append(ptr, count: size)
                }
            }
        } else {
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: &nalLenSize)
        }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let ok = avcc.withUnsafeMutableBytes { raw -> Bool in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!) == noErr
        }
        guard ok else { return nil }
        let n = Int(nalLenSize)
        var off = 0
        avcc.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            let b = p.bindMemory(to: UInt8.self)
            while off + n <= total {
                var len = 0
                for i in 0..<n { len = (len << 8) | Int(b[off + i]) }
                off += n
                guard len > 0, off + len <= total else { break }
                out.append(contentsOf: startCode)
                out.append(b.baseAddress! + off, count: len)
                off += len
            }
        }
        return (out, isKey)
    }
}
