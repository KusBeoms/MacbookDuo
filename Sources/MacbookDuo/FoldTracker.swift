import Foundation

/// One sample of fold state, derived from the lid angle sensor.
struct FoldSample {
    /// Current lid angle in degrees.
    var angle: Double
    /// Angle the content was last resolved at. The frozen plate stays locked to this.
    var anchor: Double
    /// Signed travel away from the anchor, in degrees.
    var travel: Double
    /// Travel with the wobble dead zone removed, so the effect always begins at zero.
    var effectiveTravel: Double
    /// Smoothed angular speed in degrees/second.
    var speed: Double
    /// 0...1 transition strength driving blur, darkening and depth.
    var strength: Double
    var isMoving: Bool
    /// True on the sample where movement began.
    var didStartMoving: Bool
    /// True on the sample where the lid came to rest.
    var didSettle: Bool
}

/// Turns a stream of raw lid angles into a moving/settled state machine with a
/// transition strength. Movement starts once the lid has travelled past the wobble
/// dead zone and ends once the angle holds within `settleDelta` for `settleDwell`.
final class FoldTracker {
    private(set) var anchor: Double
    private var lastAngle: Double
    private var lastTime: TimeInterval
    private var smoothedSpeed: Double = 0
    private var quietSince: TimeInterval?
    private(set) var isMoving = false

    init(initialAngle: Double, now: TimeInterval = CACurrentMediaTimeShim()) {
        anchor = initialAngle
        lastAngle = initialAngle
        lastTime = now
    }

    func update(angle: Double, now: TimeInterval = CACurrentMediaTimeShim()) -> FoldSample {
        let dt = max(now - lastTime, 1.0 / 240.0)
        let step = angle - lastAngle

        // A physically impossible jump is a bad report, not a fold. Re-anchor on it rather
        // than letting it drive the effect to full strength for a frame.
        if abs(step) > Config.maxPlausibleStep {
            reanchor(to: angle, now: now)
            return FoldSample(
                angle: angle, anchor: anchor, travel: 0, effectiveTravel: 0,
                speed: 0, strength: 0, isMoving: false,
                didStartMoving: false, didSettle: false
            )
        }

        let instantSpeed = abs(step) / dt
        // Light low-pass so sensor quantisation (1 degree steps) does not flicker the state.
        smoothedSpeed += (instantSpeed - smoothedSpeed) * min(1, dt * 18)
        lastAngle = angle
        lastTime = now

        var didStartMoving = false
        var didSettle = false

        if !isMoving, abs(angle - anchor) >= Config.deadzoneTravel {
            isMoving = true
            didStartMoving = true
            quietSince = nil
        } else if isMoving {
            if smoothedSpeed <= Config.settleSpeed {
                let since = quietSince ?? now
                quietSince = since
                if now - since >= Config.settleDwell {
                    isMoving = false
                    didSettle = true
                    quietSince = nil
                    anchor = angle
                }
            } else {
                quietSince = nil
            }
        }

        let travel = angle - anchor
        // Measure from the edge of the dead zone, so at the instant the effect engages the
        // plate is still pixel-aligned with the live screen and there is nothing to see.
        let effectiveTravel = (travel < 0 ? -1.0 : 1.0) * max(0, abs(travel) - Config.deadzoneTravel)
        let travelTerm = min(1, abs(effectiveTravel) / Config.fullStrengthTravel)
        let speedTerm = min(1, smoothedSpeed / Config.fullStrengthSpeed)
        let raw = min(1, travelTerm + Config.speedWeight * speedTerm)
        let strength = isMoving ? easeOut(raw) : 0

        return FoldSample(
            angle: angle,
            anchor: anchor,
            travel: travel,
            effectiveTravel: effectiveTravel,
            speed: smoothedSpeed,
            strength: strength,
            isMoving: isMoving,
            didStartMoving: didStartMoving,
            didSettle: didSettle
        )
    }

    /// Moves the reference angle without disturbing the motion state. Used when the plate
    /// engages part way into a movement: the frame it froze was captured just then, so the
    /// angle it should hold is the one the lid is at now, not the one it started from.
    func rebaseAnchor(to angle: Double) {
        anchor = angle
    }

    /// Re-anchors without emitting a transition, e.g. after wake.
    func reanchor(to angle: Double, now: TimeInterval = CACurrentMediaTimeShim()) {
        anchor = angle
        lastAngle = angle
        lastTime = now
        smoothedSpeed = 0
        quietSince = nil
        isMoving = false
    }

    /// Gentle ease so the first degree of travel does not snap to a hard blur.
    private func easeOut(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, 2)
    }
}

func CACurrentMediaTimeShim() -> TimeInterval {
    ProcessInfo.processInfo.systemUptime
}
