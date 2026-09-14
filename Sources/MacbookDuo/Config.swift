import Foundation

/// Tunables for the fold transition.
///
/// The numbers follow the iPhone Duo transition as described publicly: content stays
/// locked in space while the hardware reorients around it, blur ramps progressively
/// with fold progress (peaking around 72 source pixels), and a darkening pass runs at
/// roughly twice the transition strength.
enum Config {
    /// How far ahead of the lid sensor's reports the angle is drawn, from 0 to 1. The sensor
    /// only reports ten times a second, so the content either trails the lid by up to one
    /// report interval (0: never overshoots) or runs ahead along the latest motion (1: keeps
    /// up, but coasts past the lid by up to one interval on an abrupt stop). At 90 deg/s,
    /// 0.5 trails by about 5 degrees and overshoots a sudden stop by about 4.
    static let anglePrediction: Double = 0.5

    /// Sensor poll rate while the lid is moving / at rest.
    static let activePollHz: Double = 60
    static let idlePollHz: Double = 20
    /// Poll rate while Screen Recording has not been granted and the effect cannot run.
    static let noAccessPollHz: Double = 1

    /// A single sample may not jump further than this. The lid cannot physically swing
    /// this fast, so a larger step is a glitched report and is discarded.
    static let maxPlausibleStep: Double = 25

    /// Travel away from the anchor, in degrees, that is treated as hand wobble and ignored.
    /// The effect only engages once the lid has clearly moved past this.
    static let deadzoneTravel: Double = 2.5
    /// The lid counts as at rest once its smoothed speed stays under this many degrees
    /// per second for `settleDwell`. This is measured on the smoothed speed rather than
    /// the per-sample delta: the sensor reports whole degrees, so a slow fold produces
    /// runs of identical readings that a per-sample test would misread as "stopped".
    static let settleSpeed: Double = 3.0
    static let settleDwell: TimeInterval = 0.28

    /// Fold travel (degrees away from the anchor angle) that maps to full transition strength.
    static let fullStrengthTravel: Double = 22
    /// Extra strength contributed by angular speed (deg/sec at which speed alone saturates).
    static let fullStrengthSpeed: Double = 90
    /// Weight of the speed term relative to the travel term.
    static let speedWeight: Double = 0.45

    /// Ceiling on the blur radius, in points. The radius itself comes from how far a pixel
    /// has actually been displaced from where it sits on the real screen, so this is only a
    /// safety limit for very wide folds.
    static let maxBlurRadius: Double =
        ProcessInfo.processInfo.environment["DUO_MAXBLUR"].flatMap(Double.init) ?? 110

    /// Blur radius per point of displacement. A pixel that has not moved is not blurred at
    /// all, which is what makes a lid held near its original angle stay crisp everywhere.
    static let blurPerPointOfDisplacement: Double = 0.45

    /// Angle at which the shape of the displacement field is sampled. To first order the
    /// field scales linearly with the angle and its shape does not change, so the mask is
    /// built once and only its overall radius is driven per frame.
    static let displacementReferenceAngle: Double = 12

    /// How far past the edge of the display the frozen frame is carried, in points. The
    /// border pixels are extended outward — the picture genuinely grows to fit rather than
    /// a larger copy being laid over it — and that margin then fades out, so the plate never
    /// ends on a cut line and nothing is ever painted over the content itself.
    static let edgeExtension: Double = 170

    /// How much of that margin fades. It is the whole of it: the margin exists to join the
    /// picture to the black around it, so it has to start fading the moment it leaves the
    /// display. Any part left opaque shows up as a flat slab of the edge colour — a grey
    /// band down the sides, nothing at all along a dark top edge — and then cuts to black,
    /// which is the very seam this is meant to remove.
    static let edgeFadeWidth: Double = 170
    /// How fast the black backing reaches full opacity relative to transition strength.
    static let backdropRampFactor: Double = 4.0
    /// Distance from the viewer to the screen, in multiples of the screen's own height.
    /// This is what sets how strongly the tilt keystones the image. A real MacBook is
    /// viewed from roughly two and a half screen heights away; a smaller number than that
    /// is a wide-angle lens and bends the content far more than the lid actually moved.
    static let eyeDistanceInScreenHeights: Double = 2.6

    /// How much of the lid's rotation the frozen content counters, to stay locked in space.
    /// 1.0 = fully world-locked.
    static let worldLockFactor: Double = 1.0
    /// How far below the bottom edge of the display the hinge axis actually sits, in
    /// points. The panel does not pivot on its own bottom edge: there is the chin below
    /// the active area and then the hinge barrel behind it, so the axis is lower than the
    /// image. Rotating about the real axis is what makes the content read as one rigid
    /// panel moving, rather than as a picture hinged on its own edge.
    static let hingeOffsetBelowScreen: Double = 26

    /// Up to this much travel the content holds its world angle exactly, one degree of
    /// counter-rotation per degree of lid movement.
    static let worldLockKnee: Double = 26

    /// Past the knee the counter-rotation eases toward this ceiling instead of stopping at
    /// it, so a wide fold keeps responding all the way. A hard clamp here is what made the
    /// content appear to freeze once the lid had moved far enough. The same limit applies
    /// opening and closing: the axis and its travel have to match, or the two directions
    /// feel like different mechanisms.
    static let maxCounterRotation: Double = 72

    /// Tilting the content away from the viewer shrinks it, uncovering the black backing
    /// at the top of the display. That is what tilting a panel away actually looks like,
    /// so it is left alone by default. Enabling this scales the content up to keep the
    /// display covered, at the cost of the two directions no longer matching.
    static let compensateCoverageWhenClosing = false
    static let maxCoverageScale: Double = 1.6

    /// The plate simply swings from the angle it was holding to the lid's new angle. There
    /// is no separate step to take the blur away: the blur is a function of how far each
    /// pixel is displaced, so arriving at the new angle *is* arriving at zero blur.
    static let resolveDuration: TimeInterval = 0.55

    /// Fraction of the resolve after which the plate begins to fade out. By then it is
    /// almost back on the live screen; the fade only covers whatever changed underneath
    /// while the lid was moving, so the handover is not a visible cut.
    static let resolveFadeStart: Double = 0.75
    /// Hard limit on how long the frozen plate may stay on screen. The settle detector
    /// normally ends the transition long before this; the cap exists so that no failure
    /// can leave a blurred still covering the display indefinitely.
    static let maxPlateLifetime: TimeInterval = 15

    /// A frozen frame older than this is refused: showing a stale screenshot would both
    /// look wrong and put previously visible content back on screen.
    static let maxFrameAge: TimeInterval = 3.0

    /// Capture stream frame rate while idle. One clean frame is all that is ever needed,
    /// so this stays low to keep the idle cost down.
    static let idleCaptureFPS: Int32 = 4
    /// Scale of captured frames relative to the display's native pixel size. Full native
    /// resolution: now that the blur is driven by displacement, a pixel that has not moved
    /// is not blurred at all, so any shortfall here would read as a permanently soft screen
    /// rather than being hidden under the blur.
    static let captureScale: Double = 1.0
}
