import AppKit
import QuartzCore

/// Click-through, full-screen window that holds the frozen plate.
final class FoldOverlayWindow: NSWindow {
    init(screen: NSScreen) {
        plateView = FoldPlateView(frame: CGRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        // Above everything, including full-screen apps and the menu bar.
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        alphaValue = 0
        contentView = plateView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let plateView: FoldPlateView
}

/// Renders the frozen screen image: a per-pixel blur that follows how far each pixel has
/// been displaced, an edge extension that lets the picture reach past the display, and the
/// 3D counter-rotation that keeps the content locked in space while the lid moves.
final class FoldPlateView: NSView {
    private let backdropLayer = CALayer()
    /// Carries the frozen frame, extended past the edges of the display so the picture can
    /// tilt without ending on a cut line.
    private let plateLayer = CALayer()
    /// Fades that extension out. Full alpha over the display itself, so nothing is ever
    /// dimmed or covered inside the real screen area.
    private let extensionFade = CALayer()
    private let blurFilter = CIFilter(name: "CIMaskedVariableBlur")
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.clear.cgColor

        // Opaque backing: while the plate is tilted, whatever it no longer covers must read
        // as the void behind a lifted screen, not as the live desktop showing through.
        backdropLayer.backgroundColor = NSColor.black.cgColor
        backdropLayer.opacity = 0
        // Tilting the content away from the viewer gives the plate a negative z, and Core
        // Animation depth-sorts siblings: without this the backing would cover the plate
        // and the whole screen would go black as the lid closes.
        backdropLayer.zPosition = -10_000
        layer?.addSublayer(backdropLayer)

        plateLayer.contentsGravity = .resize
        plateLayer.masksToBounds = false
        plateLayer.isGeometryFlipped = false
        plateLayer.mask = extensionFade
        layer?.addSublayer(plateLayer)

        // Blur radius varies per pixel with how far that pixel has been displaced from
        // where it sits on the real screen. Nothing about this is a vertical gradient: the
        // top blurs more because it swings through a wider arc, and the sides blur more
        // because perspective moves them further, both of which fall out of the geometry.
        // The filter is only attached while there is blur to draw (see `setBlurRadius`):
        // even at radius 0 it would push the whole enlarged plate through Core Image on
        // every frame.
        blurFilter?.setValue(0.0, forKey: "inputRadius")
        plateLayer.zPosition = 0

        layoutLayers()
    }

    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func layout() {
        super.layout()
        layoutLayers()
    }

    private func layoutLayers() {
        guard let layer else { return }
        // Sublayers created in code default to a contents scale of 1, which would render a
        // native-resolution frame at half the pixels of the display it is covering.
        let screenScale = window?.backingScaleFactor ?? layer.contentsScale
        layer.contentsScale = screenScale
        for sublayer in [backdropLayer, plateLayer, extensionFade] {
            sublayer.contentsScale = screenScale
        }
        // The plate is the display plus a margin of extended border pixels on every side.
        // The part of it that covers the display stays pixel for pixel on top of the live
        // screen; only the margin is new.
        let margin = CGFloat(Config.edgeExtension)
        let size = CGSize(width: bounds.width + 2 * margin, height: bounds.height + 2 * margin)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Pivot on the real hinge axis, which lies below the bottom edge of the display.
        let offset = CGFloat(Config.hingeOffsetBelowScreen)
        plateLayer.bounds = CGRect(origin: .zero, size: size)
        plateLayer.anchorPoint = CGPoint(
            x: 0.5,
            y: size.height > 0 ? (margin - offset) / size.height : 0
        )
        plateLayer.position = CGPoint(x: bounds.midX, y: bounds.minY - offset)
        extensionFade.bounds = plateLayer.bounds
        extensionFade.position = CGPoint(x: size.width / 2, y: size.height / 2)
        extensionFade.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        backdropLayer.frame = bounds
        rebuildMasks(plateSize: size, margin: margin)
        layer.frame = bounds
        CATransaction.commit()
    }

/// Scale needed so the tilted plate still covers the whole display.
    ///
    /// The plate pivots on the hinge at the bottom edge, so its top edge at height `h`
    /// projects to `h * cos(a) / (1 + h * sin(a) * perspective)`. Tilting away from the
    /// viewer (a < 0) shrinks that below the height of the display and would expose the
    /// black backing, so the geometry is scaled up by exactly enough to compensate.
    /// Tilting toward the viewer already over-covers, and is left alone.
// MARK: - Displacement field

    /// Where a point sits after the tilt. `y` is measured up from the bottom of the
    /// display and `x` from its horizontal centre; the result is in the same frame.
    private func project(x: Double, y: Double, rotation: Double) -> (x: Double, y: Double) {
        let heightAboveAxis = y + Config.hingeOffsetBelowScreen
        let w = 1 - perspective * heightAboveAxis * sin(rotation)
        guard w > 0.05 else { return (x, y) }
        let projected = heightAboveAxis * cos(rotation) / w
        return (x / w, projected - Config.hingeOffsetBelowScreen)
    }

    /// How far the furthest pixel of the plate has moved from where it sits on the real
    /// screen, in points. The corners of the far edge always travel the most.
    private func maxDisplacement(forRotation rotation: Double) -> Double {
        guard rotation != 0 else { return 0 }
        let halfWidth = Double(bounds.width) / 2
        let height = Double(bounds.height)
        let moved = project(x: halfWidth, y: height, rotation: rotation)
        return hypot(moved.x - halfWidth, moved.y - height)
    }

    /// Builds the two masks that depend only on the size of the display: the normalised
    /// displacement field that shapes the blur, and the border fade that blends the plate
    /// into the black behind it.
    private func rebuildMasks(plateSize size: CGSize, margin: CGFloat) {
        guard size.width > 1, size.height > 1 else { return }
        let scale = layer?.contentsScale ?? 2
        extensionFade.contents = makeExtensionFade(size: size, margin: margin)
        if let mask = makeDisplacementMask(size: size, margin: margin, scale: scale) {
            // The mask is sampled in the same coordinate space as the layer's content, so
            // it has to be stretched to cover it. Left at its own small extent, everything
            // outside that corner reads as zero radius and nothing blurs at all.
            let image = CIImage(cgImage: mask)
            let fit = CGAffineTransform(
                scaleX: size.width / image.extent.width,
                y: size.height / image.extent.height
            )
            blurFilter?.setValue(image.transformed(by: fit), forKey: "inputMask")
            // A filter already attached is a snapshot; re-attach so it picks up the new mask.
            if let blurFilter, plateLayer.filters?.isEmpty == false {
                if let radius = plateLayer.value(forKeyPath: "filters.CIMaskedVariableBlur.inputRadius") {
                    blurFilter.setValue(radius, forKey: "inputRadius")
                }
                plateLayer.filters = [blurFilter]
            }
        }
    }

/// Opaque over the display itself, fading to nothing across the extended margin. Used as
    /// the plate's mask, so the fade only ever eats into pixels that were invented by the
    /// edge clamp — never into the real screen content.
    private func makeExtensionFade(size: CGSize, margin: CGFloat) -> CGImage? {
        let cols = 240
        let rows = max(1, Int(Double(cols) * size.height / size.width))
        // Only the outer lip fades; everything inside it, margin included, stays opaque.
        let fade = min(Config.edgeFadeWidth, Double(margin))
        let fadeCols = fade / Double(size.width) * Double(cols)
        let fadeRows = fade / Double(size.height) * Double(rows)
        guard fadeCols > 0.5, fadeRows > 0.5 else { return nil }

        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        for row in 0..<rows {
            for col in 0..<cols {
                let insetX = min(Double(col) + 0.5, Double(cols) - Double(col) - 0.5) / fadeCols
                let insetY = min(Double(row) + 0.5, Double(rows) - Double(row) - 0.5) / fadeRows
                // Chebyshev distance, so the contours of the fade are squares and the
                // corners are carried out just as far as the straight edges.
                let t = min(min(insetX, insetY), 1)
                // Smoothstep, so the extension thins out with no visible start or end.
                let alpha = t * t * (3 - 2 * t)
                let value = UInt8(min(255, max(0, alpha * 255)))
                let i = (row * cols + col) * 4
                pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value; pixels[i + 3] = value
            }
        }
        guard let context = CGContext(
            data: &pixels, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        return context.makeImage()
    }

    /// A greyscale image of the displacement field, normalised so the furthest-travelling
    /// pixel is white. Sampled once at a reference angle: the field scales with the angle
    /// but its shape barely changes, so only the overall radius has to move per frame.
    private func makeDisplacementMask(size: CGSize, margin: CGFloat, scale: CGFloat) -> CGImage? {
        // Coarse on purpose. The field is smooth, and this is only ever read as a blur
        // radius, so a small image upsamples with no visible difference.
        let cols = 96
        let rows = max(1, Int(Double(cols) * size.height / size.width))
        let rotation = Config.displacementReferenceAngle * .pi / 180
        let halfWidth = Double(size.width) / 2
        let height = Double(size.height)

        var field = [Double](repeating: 0, count: cols * rows)
        var peak = 0.0
        for row in 0..<rows {
            // Row 0 of the bitmap is the top of the image. `y` is measured up from the
            // bottom of the display, so the margin below it counts as negative.
            let y = height * (1 - (Double(row) + 0.5) / Double(rows)) - Double(margin)
            for col in 0..<cols {
                let x = halfWidth * (2 * (Double(col) + 0.5) / Double(cols) - 1)
                let moved = project(x: x, y: y, rotation: rotation)
                let distance = hypot(moved.x - x, moved.y - y)
                field[row * cols + col] = distance
                peak = max(peak, distance)
            }
        }
        guard peak > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: cols * rows)
        for i in field.indices {
            pixels[i] = UInt8(min(255, max(0, (field[i] / peak) * 255)))
        }
        guard let context = CGContext(
            data: &pixels, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        return context.makeImage()
    }


    /// 1 / eye distance, in points. Derived from the height of this display so the amount
    /// of keystone is the same on every screen size.
    private var perspective: Double {
        let h = Double(bounds.height)
        guard h > 0 else { return 0 }
        return 1 / (h * Config.eyeDistanceInScreenHeights)
    }

    private func coverageScale(forRotation radians: Double) -> Double {
        guard Config.compensateCoverageWhenClosing, radians < 0 else { return 1 }
        let h = Double(bounds.height)
        guard h > 0 else { return 1 }
        let denominator = cos(radians) + h * sin(radians) * perspective
        guard denominator > 0.2 else { return Config.maxCoverageScale }
        // A little extra covers the corners, which narrow slightly under perspective.
        let needed = (1 / denominator) * 1.02
        return min(max(needed, 1), Config.maxCoverageScale)
    }

/// Holds the world angle exactly up to the knee, then eases asymptotically toward the
    /// ceiling. The content therefore keeps tracking the lid however far it swings — it
    /// only ever moves less per degree, never stops.
    static func softLimited(_ degrees: Double) -> Double {
        let magnitude = abs(degrees)
        let sign: Double = degrees < 0 ? -1 : 1
        guard magnitude > Config.worldLockKnee else { return degrees }
        let headroom = Config.maxCounterRotation - Config.worldLockKnee
        guard headroom > 0 else { return sign * Config.worldLockKnee }
        let eased = Config.worldLockKnee + headroom * tanh((magnitude - Config.worldLockKnee) / headroom)
        return sign * eased
    }

    /// Drops any in-flight transition animations, so a new state takes effect immediately.
    func cancelAnimations() {
        for layer in [plateLayer, backdropLayer] {
            layer.removeAllAnimations()
        }
    }

    /// Installs the frame the screen is frozen at, with its border pixels carried outward
    /// so the picture has something to show beyond the edge of the display once it tilts.
    /// Clamping the edge is what makes this read as the screen extending rather than as a
    /// second, larger copy laid over it.
    func setFrozenImage(_ image: CGImage) {
        setPlateContents(extended(CIImage(cgImage: image)) ?? image)
    }

    /// Captured frames arrive as GPU-backed buffers. Extending straight from the buffer
    /// renders the plate in a single pass, instead of reading the frame back to a CGImage
    /// and then uploading and reading it back a second time to extend it.
    func setFrozenImage(_ pixelBuffer: CVPixelBuffer) {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let contents = extended(image) ?? ciContext.createCGImage(image, from: image.extent)
        else { return }
        setPlateContents(contents)
    }

    private func setPlateContents(_ contents: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        plateLayer.contents = contents
        CATransaction.commit()
    }

    private func extended(_ image: CIImage) -> CGImage? {
        guard bounds.width > 0 else { return nil }
        let extent = image.extent
        let pixelsPerPoint = Double(extent.width) / Double(bounds.width)
        let margin = Config.edgeExtension * pixelsPerPoint
        let region = extent.insetBy(dx: -margin, dy: -margin)
        return ciContext.createCGImage(image.clampedToExtent(), from: region)
    }

    /// Drives the transition. `travelDegrees` is how far the lid has moved from the angle
    /// the content was last resolved at; `strength` is the 0...1 transition strength.
    /// Every frame of both the fold and the return comes through here, unanimated: the
    /// controller drives the angle directly, so there is nothing for Core Animation to
    /// interpolate and no implicit animation to fight.
    func apply(strength: Double, travelDegrees: Double) {
        let s = min(max(strength, 0), 1)
        // The backing reaches full black well before the plate has tilted far enough to
        // expose anything behind it, but still fades rather than snapping on.
        let backdrop = min(1.0, s * Config.backdropRampFactor)
        let requested = travelDegrees * Config.worldLockFactor
        let counter = FoldPlateView.softLimited(requested) * .pi / 180
        // No scale term of its own: the rotation and its perspective are the only things
        // that may change the size of the content. A separate depth scale would shrink the
        // image as the transition strengthens and grow it back as it resolves, which reads
        // as the screen pulsing rather than tilting.
        let coverage = coverageScale(forRotation: counter)

        var transform = CATransform3DIdentity
        transform.m34 = -perspective
        transform = CATransform3DRotate(transform, counter, 1, 0, 0)
        transform = CATransform3DScale(transform, coverage, coverage, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // The blur follows the geometry, not the transition strength: it is how far the
        // furthest pixel has actually moved that decides it. Hold the lid near the angle
        // the content was captured at and nothing is displaced, so nothing is blurred.
        let displaced = maxDisplacement(forRotation: counter)
        let blur = min(displaced * Config.blurPerPointOfDisplacement, Config.maxBlurRadius)

        plateLayer.transform = transform
        setBlurRadius(blur)
        backdropLayer.opacity = Float(backdrop)
        CATransaction.commit()
    }

    /// Below this radius the blur is invisible, so the filter is detached altogether.
    private static let blurCutoff = 0.05

    private func setBlurRadius(_ radius: Double) {
        guard let blurFilter else { return }
        let attached = plateLayer.filters?.isEmpty == false
        if radius < FoldPlateView.blurCutoff {
            if attached { plateLayer.filters = nil }
        } else if attached {
            plateLayer.setValue(radius, forKeyPath: "filters.CIMaskedVariableBlur.inputRadius")
        } else {
            // Attaching snapshots the filter, so the current radius and mask go in first.
            blurFilter.setValue(radius, forKey: "inputRadius")
            plateLayer.filters = [blurFilter]
        }
    }
}
