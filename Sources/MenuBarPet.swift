import AppKit

/// The menu-bar pup. A template image (one colour, so it follows the menu bar's light/dark look), drawn in code:
/// it runs faster as the CPU gets busier, sits and blinks when the machine is idle, and raises a "!" when a model
/// check needs attention. Free memory is shown next to it only when it gets tight.
enum MenuBarPet {
    enum Pose: Equatable { case run(Int), sit, blink }

    static let height: CGFloat = 22
    static let petWidth: CGFloat = 26

    /// Seconds per animation frame for a CPU load (0–100). Idle → nil (sitting).
    static func frameInterval(cpu: Double) -> TimeInterval? {
        guard cpu.isFinite, cpu >= 12 else { return nil }
        // 12% → 0.32 s per frame, 100% → 0.12 s: a lazy trot up to a sprint. Faster than ~8 fps costs the
        // menu bar (every frame is re-snapshotted for each display) more than it adds.
        let t = min(1, (cpu - 12) / 88)
        return 0.32 - 0.20 * t
    }

    private static var cache: [String: NSImage] = [:]

    /// Rasterised once per pose/alert/label and reused: the status item then only swaps bitmaps instead of
    /// running the vector drawing for every frame and display.
    static func cachedImage(pose: Pose, alert: Bool, label: String?) -> NSImage {
        let key = "\(pose)|\(alert)|\(label ?? "")"
        if let hit = cache[key] { return hit }
        let vector = image(pose: pose, alert: alert, label: label)
        let raster = NSImage(size: vector.size)
        for scale in [1, 2] as [CGFloat] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(vector.size.width * scale), pixelsHigh: Int(vector.size.height * scale),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return vector }
            rep.size = vector.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            vector.draw(in: NSRect(origin: .zero, size: vector.size))
            NSGraphicsContext.restoreGraphicsState()
            raster.addRepresentation(rep)
        }
        raster.isTemplate = true
        raster.accessibilityDescription = vector.accessibilityDescription
        if cache.count > 64 { cache.removeAll() }  // labels change rarely; keep the table small
        cache[key] = raster
        return raster
    }

    static func image(pose: Pose, alert: Bool, label: String?) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let labelWidth = label.map { ceil(($0 as NSString).size(withAttributes: attrs).width) + 2 } ?? 0
        let size = NSSize(width: petWidth + labelWidth, height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.black.setFill(); NSColor.black.setStroke()
            switch pose {
            case .run(let frame): drawRunning(frame: frame % 4)
            case .sit: drawSitting(blink: false)
            case .blink: drawSitting(blink: true)
            }
            if alert { drawAlert() }
            if let label {
                let textSize = (label as NSString).size(withAttributes: attrs)
                (label as NSString).draw(at: NSPoint(x: petWidth + 1, y: (height - textSize.height) / 2), withAttributes: attrs)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VibeDeck"
        return image
    }

    // MARK: Drawing (22 pt tall box, pup faces right)

    private static func cutOut(_ path: NSBezierPath) {
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        path.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
    }

    private static func leg(from top: NSPoint, to foot: NSPoint) {
        // Short, stubby legs: chibi proportions read as "cute" at 22 pt.
        let p = NSBezierPath()
        p.move(to: top); p.line(to: foot)
        p.lineWidth = 2.7; p.lineCapStyle = .round
        p.stroke()
    }

    private static func head(at c: NSPoint, blink: Bool) {
        // Drawn at unit size around the origin and scaled up: the big head is most of the charm.
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: c.x, yBy: c.y); t.scale(by: 1.32); t.concat()
        defer { NSGraphicsContext.restoreGraphicsState() }
        // Skull, muzzle, floppy ear.
        NSBezierPath(ovalIn: NSRect(x: -3.9, y: -3.6, width: 7.8, height: 7.2)).fill()
        NSBezierPath(ovalIn: NSRect(x: 1.4, y: -3.4, width: 4.2, height: 3.8)).fill()
        let ear = NSBezierPath()
        ear.move(to: NSPoint(x: -2.4, y: 2.9))
        ear.curve(to: NSPoint(x: -4.4, y: -2.6), controlPoint1: NSPoint(x: -5.8, y: 3.6), controlPoint2: NSPoint(x: -6.2, y: -0.8))
        ear.curve(to: NSPoint(x: -0.4, y: 3.2), controlPoint1: NSPoint(x: -2.6, y: -1.6), controlPoint2: NSPoint(x: -1.4, y: 1.4))
        ear.close(); ear.fill()
        // Ear edge knocked out so it stays separate from the skull.
        let earLine = NSBezierPath()
        earLine.move(to: NSPoint(x: -1.6, y: 2.6))
        earLine.curve(to: NSPoint(x: -3.4, y: -2.0), controlPoint1: NSPoint(x: -2.4, y: 1.0), controlPoint2: NSPoint(x: -2.8, y: -0.8))
        earLine.lineWidth = 0.45
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        earLine.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        // Big round eye (with a highlight dot left in) or a happy closed arc.
        if blink {
            let lid = NSBezierPath()
            lid.move(to: NSPoint(x: 0.2, y: 0.9))
            lid.curve(to: NSPoint(x: 2.4, y: 0.9), controlPoint1: NSPoint(x: 0.7, y: 1.9), controlPoint2: NSPoint(x: 1.9, y: 1.9))
            lid.lineWidth = 0.6; lid.lineCapStyle = .round
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            lid.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            cutOut(NSBezierPath(ovalIn: NSRect(x: 0.1, y: -0.1, width: 2.3, height: 2.5)))
            NSBezierPath(ovalIn: NSRect(x: 0.8, y: 0.3, width: 1.0, height: 1.1)).fill()
        }
        let mouth = NSBezierPath()
        mouth.move(to: NSPoint(x: 2.6, y: -2.0))
        mouth.curve(to: NSPoint(x: 5.0, y: -1.9), controlPoint1: NSPoint(x: 3.3, y: -2.9), controlPoint2: NSPoint(x: 4.4, y: -2.8))
        mouth.lineWidth = 0.55
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        mouth.stroke()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        // Button nose.
        NSBezierPath(ovalIn: NSRect(x: 4.5, y: -0.8, width: 1.8, height: 1.6)).fill()
    }

    private static func drawRunning(frame: Int) {
        // Gallop cycle: extended → gathered → airborne → landing. A round loaf body on stubby legs.
        let bob: CGFloat = [0.0, 0.8, 1.3, 0.4][frame]
        let bodyY: CGFloat = 4.6 + bob
        NSBezierPath(roundedRect: NSRect(x: 4.4, y: bodyY, width: 11.4, height: 7.4), xRadius: 3.7, yRadius: 3.7).fill()
        head(at: NSPoint(x: 16.8, y: bodyY + 8.2), blink: false)
        // Tail wags between two angles.
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 5.4, y: bodyY + 5.6))
        let tip = frame % 2 == 0 ? NSPoint(x: 1.6, y: bodyY + 9.4) : NSPoint(x: 1.2, y: bodyY + 7.0)
        tail.curve(to: tip, controlPoint1: NSPoint(x: 3.6, y: bodyY + 6.6), controlPoint2: NSPoint(x: 2.4, y: bodyY + 8.6))
        tail.lineWidth = 2.2; tail.lineCapStyle = .round; tail.stroke()
        let hip = NSPoint(x: 6.8, y: bodyY + 1.6), shoulder = NSPoint(x: 13.6, y: bodyY + 1.6)
        let ground: CGFloat = 1.4
        switch frame {
        case 0: // stretched: front reach forward, hind push back
            leg(from: shoulder, to: NSPoint(x: 16.4, y: ground + 0.8)); leg(from: NSPoint(x: shoulder.x - 1.8, y: shoulder.y), to: NSPoint(x: 14.2, y: ground))
            leg(from: hip, to: NSPoint(x: 4.0, y: ground + 0.8)); leg(from: NSPoint(x: hip.x + 1.8, y: hip.y), to: NSPoint(x: 6.4, y: ground))
        case 1: // gathered under the body
            leg(from: shoulder, to: NSPoint(x: 12.0, y: ground + 0.6)); leg(from: NSPoint(x: shoulder.x - 1.8, y: shoulder.y), to: NSPoint(x: 13.2, y: ground + 0.2))
            leg(from: hip, to: NSPoint(x: 9.0, y: ground + 0.6)); leg(from: NSPoint(x: hip.x + 1.8, y: hip.y), to: NSPoint(x: 7.6, y: ground + 0.2))
        case 2: // airborne, legs tucked
            leg(from: shoulder, to: NSPoint(x: 15.6, y: ground + 2.6)); leg(from: NSPoint(x: shoulder.x - 1.8, y: shoulder.y), to: NSPoint(x: 13.8, y: ground + 2.2))
            leg(from: hip, to: NSPoint(x: 4.8, y: ground + 2.6)); leg(from: NSPoint(x: hip.x + 1.8, y: hip.y), to: NSPoint(x: 6.8, y: ground + 2.2))
        default: // landing
            leg(from: shoulder, to: NSPoint(x: 14.8, y: ground)); leg(from: NSPoint(x: shoulder.x - 1.8, y: shoulder.y), to: NSPoint(x: 11.4, y: ground + 0.6))
            leg(from: hip, to: NSPoint(x: 5.6, y: ground)); leg(from: NSPoint(x: hip.x + 1.8, y: hip.y), to: NSPoint(x: 9.4, y: ground + 0.6))
        }
    }

    private static func drawSitting(blink: Bool) {
        // Round haunch, upright chest, two stubby front paws, tail curled on the ground.
        NSBezierPath(ovalIn: NSRect(x: 3.8, y: 1.2, width: 11.0, height: 9.2)).fill()
        let chest = NSBezierPath()
        chest.move(to: NSPoint(x: 8.6, y: 2.6))
        chest.curve(to: NSPoint(x: 12.6, y: 12.6), controlPoint1: NSPoint(x: 9.0, y: 7.8), controlPoint2: NSPoint(x: 10.2, y: 11.4))
        chest.line(to: NSPoint(x: 17.2, y: 11.6))
        chest.curve(to: NSPoint(x: 16.4, y: 2.6), controlPoint1: NSPoint(x: 17.4, y: 7.8), controlPoint2: NSPoint(x: 17.0, y: 4.8))
        chest.close(); chest.fill()
        leg(from: NSPoint(x: 15.4, y: 5.0), to: NSPoint(x: 15.8, y: 1.4))
        leg(from: NSPoint(x: 12.8, y: 5.0), to: NSPoint(x: 13.0, y: 1.4))
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: 4.6, y: 3.0))
        tail.curve(to: NSPoint(x: 1.2, y: 6.2), controlPoint1: NSPoint(x: 2.0, y: 2.0), controlPoint2: NSPoint(x: 0.6, y: 3.6))
        tail.lineWidth = 2.2; tail.lineCapStyle = .round; tail.stroke()
        head(at: NSPoint(x: 16.0, y: 15.4), blink: blink)
    }

    private static func drawAlert() {
        // A small "!" bubble floating over the pup's back, clear of the big head.
        let bubble = NSBezierPath(ovalIn: NSRect(x: 2.4, y: 14.6, width: 6.8, height: 6.8))
        bubble.fill()
        cutOut(NSBezierPath(roundedRect: NSRect(x: 5.25, y: 17.3, width: 1.1, height: 3.0), xRadius: 0.5, yRadius: 0.5))
        cutOut(NSBezierPath(ovalIn: NSRect(x: 5.2, y: 15.5, width: 1.2, height: 1.2)))
    }
}

/// Drives the status-item image: frame timer while running, an occasional blink while sitting.
final class MenuBarPetAnimator {
    private weak var button: NSStatusBarButton?
    private var timer: Timer?
    private var frame = 0
    private var cpu: Double = 0
    private var alert = false
    private var label: String?
    private var interval: TimeInterval?
    private var sitTicks = 0
    private var lastKey = ""
    /// While the panel is open the pup sits still, so the menu bar never competes with the panel for the main thread.
    private var paused = false

    init(button: NSStatusBarButton) {
        self.button = button
        button.imagePosition = .imageOnly
        button.title = ""
        render(.sit)
    }

    /// Called on the main queue after each scan / system sample.
    func setPaused(_ value: Bool) {
        guard paused != value else { return }
        paused = value
        if value { timer?.invalidate(); timer = nil; render(.sit) } else { interval = nil; update(cpu: cpu, alert: alert, label: label) }
    }

    func update(cpu: Double, alert: Bool, label: String?) {
        self.cpu = cpu; self.alert = alert; self.label = label
        guard !paused else { render(.sit); return }
        let next = MenuBarPet.frameInterval(cpu: cpu)
        // Only restart the timer when the pace changes noticeably, so the gait stays smooth.
        if next.map({ n in interval.map { abs($0 - n) > 0.03 } ?? true }) ?? (interval != nil) || timer == nil {
            interval = next
            schedule()
        }
        if next == nil { render(.sit) }
    }

    private func schedule() {
        timer?.invalidate()
        let step = interval ?? 0.5
        let t = Timer(timeInterval: step, repeats: true) { [weak self] _ in self?.tick() }
        t.tolerance = step * 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        if interval != nil {
            frame = (frame + 1) % 4
            render(.run(frame))
        } else {
            // Sitting: blink for one tick roughly every 4–6 seconds.
            sitTicks += 1
            if sitTicks % 10 == 0 { render(.blink) } else if sitTicks % 10 == 1 { render(.sit) }
        }
    }

    private func render(_ pose: MenuBarPet.Pose) {
        let key = "\(pose)|\(alert)|\(label ?? "")"
        guard key != lastKey, let button else { return }
        lastKey = key
        button.image = MenuBarPet.cachedImage(pose: pose, alert: alert, label: label)
    }

    func stop() { timer?.invalidate(); timer = nil }
}
