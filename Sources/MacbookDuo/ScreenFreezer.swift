import AppKit
import CoreImage
import CoreMedia
import ScreenCaptureKit

/// Keeps one recent, clean frame of the built-in display available so that the moment
/// the lid starts moving we can freeze the screen exactly as it looked just before.
///
/// The stream runs only while the lid is at rest and at a few frames per second.
@MainActor
final class ScreenFreezer: NSObject {
    private var stream: SCStream?
    /// Incremented on every start/stop. A start that finishes after its generation has
    /// been superseded tears its own stream down instead of leaking it.
    private var generation = 0

    nonisolated private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleQueue = DispatchQueue(label: "com.macbookduo.capture")

    /// `latest` is only ever touched while `latestLock` is held; that lock is the entire
    /// reason this is safe to read from the sample queue and the main actor alike.
    nonisolated private let latestLock = NSLock()
    nonisolated(unsafe) private var latest: CGImage?
    nonisolated(unsafe) private var latestTime: TimeInterval = 0

    private(set) var isRunning = false

    /// The most recent clean frame, or nil when there is none recent enough to trust.
    /// A stale frame would put content back on screen that the user has since moved past.
    nonisolated var frozenFrame: CGImage? {
        latestLock.lock()
        defer { latestLock.unlock() }
        guard let latest, ProcessInfo.processInfo.systemUptime - latestTime < Config.maxFrameAge
        else { return nil }
        return latest
    }

    nonisolated private func clearFrame() {
        latestLock.lock()
        latest = nil
        latestTime = 0
        latestLock.unlock()
    }

    func start(displayID: CGDirectDisplayID, pixelScale: Double) async {
        guard !isRunning else { return }
        isRunning = true
        generation += 1
        let myGeneration = generation

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                if generation == myGeneration { isRunning = false }
                return
            }
            // Never capture our own overlay: it would feed the blurred plate into itself.
            let ownApps = content.applications.filter {
                $0.bundleIdentifier == Bundle.main.bundleIdentifier
                    || $0.processID == ProcessInfo.processInfo.processIdentifier
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

            let config = SCStreamConfiguration()
            // SCDisplay reports points; capture at native pixels so the plate stays sharp.
            config.width = Int(Double(display.width) * pixelScale * Config.captureScale)
            config.height = Int(Double(display.height) * pixelScale * Config.captureScale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: Config.idleCaptureFPS)
            config.queueDepth = 3
            // A baked-in cursor would sit at its capture-time position while the live one
            // moves, showing as a doubled cursor exactly when the plate realigns.
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.capturesAudio = false

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
            try await stream.startCapture()

            // A stop() landed while this start was suspended: this stream is already
            // obsolete, so shut it down rather than leaving it running forever.
            guard generation == myGeneration else {
                try? await stream.stopCapture()
                return
            }
            self.stream = stream
        } catch {
            if generation == myGeneration { isRunning = false }
            NSLog("MacbookDuo: capture failed to start: \(error.localizedDescription)")
        }
    }

    func stop() async {
        generation += 1
        isRunning = false
        // The last frame is deliberately kept. The stream is stopped every time the plate
        // goes up, and restarting it takes long enough that discarding the frame here would
        // leave the next fold with nothing to freeze — the effect would simply not fire.
        // `frozenFrame` already refuses anything older than `maxFrameAge`, so staleness is
        // handled without throwing away a frame that is still good.
        guard let stream else { return }
        self.stream = nil
        try? stream.removeStreamOutput(self, type: .screen)
        try? await stream.stopCapture()
    }

    /// ScreenCaptureKit tears streams down on display reconfiguration and on permission
    /// changes. Without this the stale stream would block every future start.
    private func handleStreamStopped(_ error: Error) {
        NSLog("MacbookDuo: capture stopped: \(error.localizedDescription)")
        generation += 1
        stream = nil
        isRunning = false
        clearFrame()
    }
}

extension ScreenFreezer: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.handleStreamStopped(error)
        }
    }
}

extension ScreenFreezer: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              CMSampleBufferGetNumSamples(sampleBuffer) > 0,
              CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        latestLock.lock()
        latest = cgImage
        latestTime = ProcessInfo.processInfo.systemUptime
        latestLock.unlock()
    }
}
