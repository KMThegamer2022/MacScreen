import Foundation
import ScreenCaptureKit
import CoreMedia

/// Captures one display (the virtual one) with ScreenCaptureKit.
final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "macscreen.capture", qos: .userInteractive)
    var onFrame: ((CVPixelBuffer) -> Void)?
    var onStop: ((Error) -> Void)?
    private(set) var frames = 0

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var display: SCDisplay?
        // The virtual display can take a moment to show up as shareable.
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let display else {
            throw NSError(domain: "MacScreen", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Virtual display \(displayID) not visible to ScreenCaptureKit"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 3
        cfg.showsCursor = true
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func updateFPS(_ fps: Int, width: Int, height: Int) {
        guard let stream else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.queueDepth = 3
        cfg.showsCursor = true
        Task { try? await stream.updateConfiguration(cfg) }
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = arr.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        frames += 1
        onFrame?(pb)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onStop?(error) }
}
