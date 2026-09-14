import Foundation

/// Rebuilds a continuous angle from the lid sensor's sparse reports.
///
/// Measured on this hardware, the sensor publishes a new value only every 100 ms, jumping
/// several degrees at a time when the lid moves quickly. Drawing those values directly — or
/// easing toward whichever one arrived last — makes the content hold still for most of each
/// interval and then lurch. Instead the angle is drawn along the straight line between the
/// two most recent reports, sampled at a point in time set by `prediction`:
///
/// - `0` draws one report interval in the past. Motion is perfectly continuous and never
///   runs past the lid, but trails it by one interval.
/// - `1` draws at the present, extrapolating along the latest segment for up to one
///   interval. Almost no trailing, but on an abrupt stop the content carries on for up to
///   one interval's worth of motion before it notices.
///
/// With 10 reports a second the trailing and the overshoot always add up to roughly one
/// interval of lid motion; `prediction` only chooses how that is split.
struct AngleReconstructor {
    private var previousTime = 0.0
    private var previousValue = 0.0
    private var latestTime = 0.0
    private var latestValue = 0.0
    /// Running estimate of the time between reports, learned from the sensor itself.
    private var interval = 0.1
    private var primed = false

    /// Starts over at `value`, as though the lid had been resting there.
    mutating func reset(to value: Double, now: TimeInterval) {
        previousTime = now - interval
        previousValue = value
        latestTime = now
        latestValue = value
        primed = true
    }

    mutating func update(measured: Double, now: TimeInterval, prediction: Double) -> Double {
        if !primed { reset(to: measured, now: now) }

        if measured != latestValue {
            let since = now - latestTime
            interval += (min(max(since, 0.05), 0.25) - interval) * 0.4
            // After a pause the previous report is stale; treat this segment as having taken
            // one normal interval, or motion would restart sluggishly.
            previousTime = max(latestTime, now - interval * 1.5)
            previousValue = latestValue
            latestTime = now
            latestValue = measured
        }

        let p = min(max(prediction, 0), 1)
        let segment = max(latestTime - previousTime, 1e-3)
        let drawAt = now - (1 - p) * interval
        // Past the latest report, extrapolate for at most `p` of an interval, then hold.
        let furthest = 1 + p * interval / segment
        let u = min(max((drawAt - previousTime) / segment, 0), furthest)
        return previousValue + (latestValue - previousValue) * u
    }
}
