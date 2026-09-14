import AppKit

/// Wires the lid sensor to the overlay: freeze, blur, world-lock, resolve.
@MainActor
final class FoldController {
    private let sensor = LidAngleSensor()
    private let freezer = ScreenFreezer()
    private var tracker: FoldTracker?
    private var overlay: FoldOverlayWindow?
    private var timer: DispatchSourceTimer?
    private var currentHz: Double?
    private var plateIsVisible = false
    /// While the resolve animation runs, per-tick updates must not overwrite it.
    private var isResolving = false
    /// Last time the plate was actually being driven. The lifetime cap measures from here,
    /// not from when the plate appeared, so a slow deliberate fold is never cut short — only
    /// a plate that has genuinely stopped being updated gets taken down.
    private var lastPlateMotion: TimeInterval = 0
    private var resolveFrom: Double = 0
    private var resolveStrength: Double = 0
    private var resolveStartedAt: TimeInterval = 0
    private var hasStopped = false
    private var lastCaptureRetry: TimeInterval = 0
    /// Screen Recording is missing, so polling drops to `noAccessPollHz` until it is granted.
    private var waitingForAccess = false
    /// Stands in for a captured frame so the rendering can be exercised without Screen
    /// Recording access. Debug only.
    var debugFrame: CGImage?
    /// The strength the plate is currently showing, so the resolve can continue from it
    /// instead of snapping to a different amount of blur first.
    private var lastStrength: Double = 0
    /// The angle the plate is actually drawn at. It chases the measured travel rather than
    /// snapping to it, which is what turns the sensor's whole-degree reports into motion.
    private var renderedTravel: Double = 0
    /// Turns the sensor's ten-a-second reports into an angle that moves every frame.
    private var reconstructor = AngleReconstructor()

    /// When set, `tick` uses this angle instead of the sensor. Used by the preview demo.
    private var demoAngle: Double?
    private var demoTimer: DispatchSourceTimer?

    private(set) var isEnabled = false
    /// Latest angle, for the status menu.
    private(set) var lastAngle: Double = 0

    var onStateChange: (() -> Void)?

    /// True once the user has granted Screen Recording. Without it there is nothing to
    /// freeze, so the effect stays idle rather than showing a blank overlay.
    var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    func requestScreenAccess() {
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
    }

    func start() -> Bool {
        guard sensor.open(), let angle = sensor.readAngle() else { return false }
        lastAngle = angle
        tracker = FoldTracker(initialAngle: angle)
        isEnabled = true
        rebuildOverlay()
        setPollRate(Config.idlePollHz)
        Task { await self.startCapture() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(willSleep),
            name: NSWorkspace.willSleepNotification, object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil
        )
        return true
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            if let angle = sensor.readAngle() { tracker?.reanchor(to: angle) }
            setPollRate(Config.idlePollHz)
            Task { await self.startCapture() }
        } else {
            setPollRate(nil)
            cancelDemo()
            hidePlate()
            Task { await self.freezer.stop() }
        }
        onStateChange?()
    }

    func stop() {
        hasStopped = true
        setPollRate(nil)
        cancelDemo()
        hidePlate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        overlay = nil
        sensor.close()
        Task { await self.freezer.stop() }
    }

    // MARK: - Screens

    /// The fold effect only makes sense on the built-in display: external monitors do not move.
    private var builtInScreen: NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    private var builtInDisplayID: CGDirectDisplayID? {
        guard let screen = builtInScreen,
              let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
              ] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    private func rebuildOverlay() {
        overlay?.orderOut(nil)
        overlay = nil
        guard let screen = builtInScreen else { return }
        overlay = FoldOverlayWindow(screen: screen)
    }

    @objc private func screensChanged() {
        hidePlate()
        rebuildOverlay()
        // The stream targets a specific display, and both that display and its scale can
        // change here, so it has to be torn down and re-established rather than left alone.
        Task {
            await self.freezer.stop()
            await self.startCapture()
        }
        // Nothing to drive on an external-only setup; stop burning sensor reads.
        setPollRate(builtInScreen == nil ? nil : Config.idlePollHz)
    }

    @objc private func willSleep() {
        hidePlate()
        cancelDemo()
        setPollRate(Config.idlePollHz)
        Task { await self.freezer.stop() }
    }

    @objc private func didWake() {
        guard !hasStopped else { return }
        // The lid angle almost always changed while asleep; that jump is not a fold.
        hidePlate()
        setPollRate(Config.idlePollHz)
        if let angle = sensor.readAngle() { tracker?.reanchor(to: angle) }
        if isEnabled { Task { await self.startCapture() } }
    }

    private func startCapture() async {
        guard isEnabled, !plateIsVisible, let displayID = builtInDisplayID else { return }
        let scale = builtInScreen?.backingScaleFactor ?? 2
        await freezer.start(displayID: displayID, pixelScale: Double(scale))
    }

    // MARK: - Polling

    private func setPollRate(_ hz: Double?) {
        guard hz != currentHz else { return }
        currentHz = hz
        timer?.cancel()
        timer = nil
        guard let hz else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Tight timing only matters while animating. At rest a generous leeway lets the
        // system coalesce these wakeups with others, which is most of the idle power cost.
        let leeway: DispatchTimeInterval = hz >= Config.activePollHz ? .milliseconds(1) : .milliseconds(15)
        timer.schedule(deadline: .now(), repeating: 1.0 / hz, leeway: leeway)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        guard isEnabled, let tracker else { return }

        // Checked before the sensor read: a sensor that stops answering must never be able
        // to strand an opaque overlay on the display.
        if plateIsVisible, CACurrentMediaTimeShim() - lastPlateMotion > Config.maxPlateLifetime {
            NSLog("MacbookDuo: plate exceeded its lifetime cap, taking it down")
            if let live = sensor.readAngle() { tracker.reanchor(to: live) }
            hidePlate()
            Task { await self.startCapture() }
            return
        }

        // If capture is not running — permission was granted after launch, or the stream
        // was torn down — bring it back rather than sitting enabled but inert.
        // The throttle is checked first so the permission query runs at most every 5 s.
        if waitingForAccess, freezer.isRunning {
            // Capture was brought up by another path (wake, screen change, re-enable) after
            // the grant. The retry below never runs while capture is up, so clear the flag
            // here or the effect would stay throttled to 1 Hz with a live stream.
            waitingForAccess = false
            if let live = sensor.readAngle() { tracker.reanchor(to: live) }
        }
        if !plateIsVisible, !freezer.isRunning {
            let now = CACurrentMediaTimeShim()
            if now - lastCaptureRetry > 5 {
                lastCaptureRetry = now
                let access = hasScreenAccess
                if access { Task { await self.startCapture() } }
                let wasWaiting = waitingForAccess
                waitingForAccess = !access && debugFrame == nil
                // The lid may have moved a long way while unpolled; that is not a fold.
                if wasWaiting, !waitingForAccess, let live = sensor.readAngle() {
                    tracker.reanchor(to: live)
                }
            }
        }
        // Without Screen Recording there is nothing to freeze, so reading the sensor at the
        // idle rate would be pure cost. Tick just often enough to notice the grant.
        if waitingForAccess, demoAngle == nil {
            setPollRate(Config.noAccessPollHz)
            return
        }

        guard let angle = demoAngle ?? sensor.readAngle() else { return }
        lastAngle = angle
        let sample = tracker.update(angle: angle)

        if sample.didStartMoving, isResolving {
            abortResolve()
        }
        // Attempted on every moving sample, not just the first. If the frame was not ready
        // at the instant the fold began, the movement would otherwise be missed outright;
        // this way the plate engages as soon as one arrives.
        if sample.isMoving, !plateIsVisible, !isResolving {
            showPlate()
            if plateIsVisible, !sample.didStartMoving {
                // Engaged late, on a frame captured mid-movement. Anchoring to where the lid
                // started would drop the plate in already tilted and blurred.
                tracker.rebaseAnchor(to: angle)
                renderedTravel = 0
                reconstructor.reset(to: 0, now: CACurrentMediaTimeShim())
                overlay?.plateView.apply(strength: 0, travelDegrees: 0)
                lastStrength = 0
            }
        }
        // Deliberately skipped on the settling sample. The tracker re-anchors the moment it
        // declares the lid at rest, so that sample already reads as zero travel and zero
        // strength — applying it here, unanimated, would snap the content from the angle it
        // was holding straight to the new one and leave the resolve nothing to animate.
        if plateIsVisible, !isResolving, !sample.didSettle {
            if sample.speed > 0.5 { lastPlateMotion = CACurrentMediaTimeShim() }
            lastStrength = sample.strength
            overlay?.plateView.apply(
                strength: sample.strength,
                travelDegrees: smoothedTravel(toward: sample.effectiveTravel)
            )
        }
        if sample.didSettle {
            resolvePlate()
        }
        if isResolving {
            driveResolve()
        }
        // The resolve is an animation driven from this same tick, so it needs the fast rate
        // just as much as the fold does. Keyed off `isMoving` alone, the settling sample
        // would drop the loop back to the idle rate and play the return at that rate.
        let animating = sample.isMoving || isResolving
        setPollRate(animating ? Config.activePollHz : Config.idlePollHz)
    }

    private func smoothedTravel(toward measured: Double) -> Double {
        renderedTravel = reconstructor.update(
            measured: measured,
            now: CACurrentMediaTimeShim(),
            prediction: Config.anglePrediction
        )
        return renderedTravel
    }

    // MARK: - Demo

    /// Plays a synthetic fold so the effect can be previewed without moving the lid.
    func runDemo(travel: Double = 26, duration: TimeInterval = 1.1) {
        guard isEnabled, demoTimer == nil, let start = sensor.readAngle() else { return }
        let began = CACurrentMediaTimeShim()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / Config.activePollHz)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let elapsed = CACurrentMediaTimeShim() - began
                if elapsed >= duration {
                    // Hold the end angle long enough for the settle dwell to fire, then
                    // hand control back to the real sensor.
                    self.demoAngle = start + travel
                    if elapsed >= duration + Config.settleDwell + 0.5 {
                        self.demoAngle = nil
                        self.demoTimer?.cancel()
                        self.demoTimer = nil
                        // Hand back to the sensor without treating the jump as a new fold.
                        if let live = self.sensor.readAngle() { self.tracker?.reanchor(to: live) }
                    }
                    return
                }
                let t = elapsed / duration
                let eased = 1 - pow(1 - t, 3)
                self.demoAngle = start + travel * eased
            }
        }
        timer.resume()
        demoTimer = timer
        setPollRate(Config.activePollHz)
    }

    /// Freezes the effect at a fixed strength. Used by `--hold` to inspect a single
    /// point of the transition without moving the lid.
    func holdPreview(strength: Double, travel: Double, seconds: TimeInterval = 20) {
        showPlate()
        guard plateIsVisible else {
            NSLog("MacbookDuo: nothing to freeze — no captured frame available")
            return
        }
        setPollRate(nil)
        overlay?.plateView.apply(strength: strength, travelDegrees: travel)
        if let spin = ProcessInfo.processInfo.environment["DUO_SPIN"].flatMap(Double.init) {
            runSpin(seconds: spin, amplitude: travel, strength: strength)
        }
        // Always time-limited: an opaque overlay held open by a debug flag would otherwise
        // have no way out.
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hidePlate()
                self.setPollRate(Config.idlePollHz)
                Task { await self.startCapture() }
            }
        }
    }

    /// Debug: sweeps the plate back and forth continuously and reports how steadily the
    /// updates were delivered, so rendering cost can be measured over a sustained run.
    private var spinTimer: DispatchSourceTimer?
    private func runSpin(seconds: Double, amplitude: Double, strength: Double) {
        let began = CACurrentMediaTimeShim()
        var last = 0.0
        var intervals: [Double] = []
        var costs: [Double] = []
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: 1.0 / Config.activePollHz, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CACurrentMediaTimeShim()
                if last > 0 { intervals.append(now - last) }
                last = now
                let t = now - began
                let travel = amplitude * (0.5 - 0.5 * cos(2 * .pi * t / 1.2))
                self.overlay?.plateView.apply(strength: strength, travelDegrees: travel)
                CATransaction.flush()
                costs.append(CACurrentMediaTimeShim() - now)
                if t >= seconds {
                    self.spinTimer?.cancel()
                    self.spinTimer = nil
                    func stats(_ v: [Double]) -> String {
                        let s = v.sorted()
                        return String(format: "med %.1f p90 %.1f max %.1f", s[s.count / 2] * 1000, s[Int(Double(s.count) * 0.9)] * 1000, s.last! * 1000)
                    }
                    NSLog("MacbookDuo: spin frames=\(costs.count) late=\(intervals.filter { $0 > 0.0208 }.count) interval ms [\(stats(intervals))] apply ms [\(stats(costs))]")
                }
            }
        }
        timer.resume()
        spinTimer = timer
    }

    // MARK: - Plate lifecycle

    private func showPlate() {
        guard !plateIsVisible, let overlay else { return }
        // Without a captured frame there is nothing to freeze; stay out of the way.
        if let debugFrame {
            overlay.plateView.setFrozenImage(debugFrame)
        } else if let frame = freezer.frozenFrame {
            overlay.plateView.setFrozenImage(frame)
        } else {
            return
        }
        overlay.plateView.apply(strength: 0, travelDegrees: 0)
        overlay.alphaValue = 1
        overlay.orderFrontRegardless()
        plateIsVisible = true
        renderedTravel = 0
        reconstructor.reset(to: 0, now: CACurrentMediaTimeShim())
        lastPlateMotion = CACurrentMediaTimeShim()
        Task { await self.freezer.stop() }
    }

    /// The lid is holding still: swing the content back into alignment, then dissolve
    /// the blur away to reveal the live screen.
    /// The lid has come to rest. Swing the content from the angle it was holding to the
    /// angle the lid is at now, driven frame by frame off the same clock as the fold itself
    /// — so the blur keeps following the displacement all the way down and reaches zero
    /// exactly when the content lands back on the live screen.
    private func resolvePlate() {
        guard plateIsVisible, !isResolving, overlay != nil else {
            if !plateIsVisible { Task { await self.startCapture() } }
            return
        }
        isResolving = true
        resolveFrom = renderedTravel
        resolveStrength = lastStrength
        resolveStartedAt = CACurrentMediaTimeShim()
        setPollRate(Config.activePollHz)
    }

    private func driveResolve() {
        guard let overlay else {
            hidePlate()
            return
        }
        let elapsed = CACurrentMediaTimeShim() - resolveStartedAt
        let t = Config.resolveDuration > 0 ? min(1, elapsed / Config.resolveDuration) : 1
        let eased = 1 - pow(1 - t, 3)
        let remaining = 1 - eased

        renderedTravel = resolveFrom * remaining
        overlay.plateView.apply(
            strength: resolveStrength * remaining,
            travelDegrees: renderedTravel
        )
        // Nothing fades until the content is nearly home, where it is all but identical to
        // what is underneath it.
        let fade = Config.resolveFadeStart
        overlay.alphaValue = t <= fade ? 1 : CGFloat(max(0, 1 - (t - fade) / (1 - fade)))

        if t >= 1 {
            overlay.orderOut(nil)
            overlay.alphaValue = 0
            plateIsVisible = false
            isResolving = false
            Task { await self.startCapture() }
        }
    }

    /// The lid started moving again before the resolve finished. Drop the resolve and keep
    /// driving the plate that is already up, rather than uncovering the screen mid-move.
    private func abortResolve() {
        isResolving = false
        // Continue from wherever the return had got to, rather than snapping to the new
        // measurement.
        reconstructor.reset(to: renderedTravel, now: CACurrentMediaTimeShim())
        overlay?.plateView.cancelAnimations()
        overlay?.alphaValue = 1
    }

    /// Takes the plate down and returns to a known-good state. Every reset here happens
    /// unconditionally: if these flags survived a missing overlay, nothing could ever show
    /// the plate again, and a half-finished resolve would strand it on screen.
    private func hidePlate() {
        plateIsVisible = false
        isResolving = false
        overlay?.plateView.cancelAnimations()
        overlay?.orderOut(nil)
        overlay?.alphaValue = 0
    }

    private func cancelDemo() {
        demoTimer?.cancel()
        demoTimer = nil
        demoAngle = nil
    }
}
