import Foundation
import VideoToolbox
import CoreMedia
import CoreImage

/// Hardware H.264 encoder tuned for low latency. Emits Annex-B access units.
final class H264Encoder {
    private var session: VTCompressionSession?
    private var pts: Int64 = 0
    /// (annexB data, isKeyframe, codecString if keyframe)
    var onFrame: ((Data, Bool, String?) -> Void)?

    init?(width: Int, height: Int, fps: Int, bitrateMbps: Int) {
        var s: VTCompressionSession?
        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        if st != noErr || s == nil {
            spec.removeValue(forKey: kVTVideoEncoderSpecification_EnableLowLatencyRateControl)
            st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
                                            codecType: kCMVideoCodecType_H264,
                                            encoderSpecification: spec as CFDictionary,
                                            imageBufferAttributes: nil, compressedDataAllocator: nil,
                                            outputCallback: nil, refcon: nil, compressionSessionOut: &s)
        }
        guard st == noErr, let sess = s else { return nil }
        session = sess
        func set(_ k: CFString, _ v: Any) { VTSessionSetProperty(sess, key: k, value: v as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrateMbps * 1_000_000)
        let bytesPerSec = Double(bitrateMbps) * 1_000_000 / 8 * 2
        set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerSec, 1.0] as [Double])
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 4)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    deinit { invalidate() }

    func invalidate() {
        if let s = session { VTCompressionSessionInvalidate(s) }
        session = nil
    }

    func encode(_ pb: CVPixelBuffer, forceKey: Bool) {
        guard let session else { return }
        pts += 1
        let t = CMTime(value: pts, timescale: 1000)
        var props: CFDictionary?
        if forceKey { props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pb, presentationTimeStamp: t,
                                        duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sb in
            guard status == noErr, let sb, let self else { return }
            self.convert(sb)
        }
    }

    private let startCode: [UInt8] = [0, 0, 0, 1]

    private func convert(_ sb: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        var isKey = true
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let a = arr.first {
            isKey = !((a[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
        }
        var out = Data()
        var codec: String?
        if isKey, let fd = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil, parameterSetCountOut: &count,
                                                               nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var sz = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fd, parameterSetIndex: i, parameterSetPointerOut: &p,
                                                                   parameterSetSizeOut: &sz, parameterSetCountOut: nil,
                                                                   nalUnitHeaderLengthOut: nil)
                if let p {
                    out.append(contentsOf: startCode)
                    out.append(p, count: sz)
                    if i == 0, sz >= 4 { codec = String(format: "avc1.%02x%02x%02x", p[1], p[2], p[3]) }
                }
            }
        }
        var lenAtOffset = 0, total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lenAtOffset,
                                          totalLengthOut: &total, dataPointerOut: &ptr) == kCMBlockBufferNoErr,
              let base = ptr else { return }
        var off = 0
        while off + 4 <= total {
            var n: UInt32 = 0
            memcpy(&n, base + off, 4)
            let len = Int(UInt32(bigEndian: n))
            off += 4
            if len <= 0 || off + len > total { break }
            out.append(contentsOf: startCode)
            out.append(UnsafeBufferPointer(start: UnsafeRawPointer(base + off).assumingMemoryBound(to: UInt8.self), count: len))
            off += len
        }
        onFrame?(out, isKey, codec)
    }
}

/// GPU-assisted JPEG encoder, used when the browser can't use WebCodecs (plain-http pages).
final class JPEGEncoder {
    private let ctx = CIContext(options: [.useSoftwareRenderer: false])
    private let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    var quality: CGFloat = 0.6

    func encode(_ pb: CVPixelBuffer) -> Data? {
        let img = CIImage(cvPixelBuffer: pb)
        return ctx.jpegRepresentation(of: img, colorSpace: cs,
                                      options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
    }
}
