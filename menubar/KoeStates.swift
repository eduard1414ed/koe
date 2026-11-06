// Koe — menu bar icon states: "paused", "problem", "transcribing".
//
// Line-by-line port of koe-logo-states/reference/koe-states.js, which is the source of truth:
// don't change the constants; if they differ, fix the JS. Compare with koe-logo-states/reference/states-preview.html.
// The resting ring and the smoothing come from KoeRing.swift.
//
// Same coordinates as KoeRing: 24×24 square, center (12, 12), Y axis pointing down.
//
//  • Paused        — resting ring + a pause sign inside (two rounded bars). Filled. Not in the menu bar: it read as
//                    "recording is paused", so a paused transcription keeps the usual ring.
//  • Problem       — resting ring + an exclamation mark inside. Filled.
//  • Transcribing  — three thin uneven ring lines that bend, shift
//                     and drift through each other. Stroked, not filled.
import AppKit

enum KoeStates {
    static let TAU = Double.pi * 2

    // ---------------------------------------------------------------------------
    // Signs inside the ring. Each size has its own proportions (bolder in the menu bar).
    // rect: [x, y, width, height] — a capsule, corner radius = width / 2.
    // circle: [cx, cy, r].
    // ---------------------------------------------------------------------------
    struct Mark {
        let rects: [[Double]]
        let circles: [[Double]]
    }

    static let MARKS: [String: [String: Mark]] = [
        "pause": [
            "icon":    Mark(rects: [[10.2, 8.9, 1.5, 5.2], [13.4, 8.9, 1.5, 5.2]], circles: []),
            "menubar": Mark(rects: [[9.9, 8.6, 2.0, 5.8], [13.3, 8.6, 2.0, 5.8]], circles: []),
        ],
        "problem": [
            "icon":    Mark(rects: [[11.85, 7.9, 1.6, 4.9]], circles: [[12.65, 14.6, 0.95]]),
            "menubar": Mark(rects: [[11.65, 7.6, 2.1, 5.2]], circles: [[12.7, 14.8, 1.25]]),
        ],
    ]

    // Arcs work as in SVG with the Y axis down: sweep flag 1 — angle increases (clockwise: false), 0 — decreases.
    static func capsule(_ path: CGMutablePath, _ r: [Double]) {
        let x = r[0], y = r[1], w = r[2], h = r[3], k = w / 2
        path.move(to: CGPoint(x: x + k, y: y))
        path.addArc(center: CGPoint(x: x + k, y: y + k), radius: k, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        path.addLine(to: CGPoint(x: x + w, y: y + h - k))
        path.addArc(center: CGPoint(x: x + k, y: y + h - k), radius: k, startAngle: 0, endAngle: .pi, clockwise: false)
        path.addLine(to: CGPoint(x: x, y: y + k))
        path.addArc(center: CGPoint(x: x + k, y: y + k), radius: k, startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: false)
        path.closeSubpath()
    }

    static func dot(_ path: CGMutablePath, _ c: [Double]) {
        let cx = c[0], cy = c[1], r = c[2]
        path.move(to: CGPoint(x: cx - r, y: cy))
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .pi, endAngle: 0, clockwise: true)
        path.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: 0, endAngle: -.pi, clockwise: true)
        path.closeSubpath()
    }

    // Sign in the 24×24 square (Y axis down). set: "icon" (large) or "menubar" (menu bar).
    static func markPath(_ kind: String, _ set: String) -> CGPath {
        let m = MARKS[kind]![set == "icon" ? "icon" : "menubar"]!
        let path = CGMutablePath()
        for r in m.rects { capsule(path, r) }
        for c in m.circles { dot(path, c) }
        return path
    }

    // ---------------------------------------------------------------------------
    // "Transcribing": three lines.
    // Each line is a closed uneven circle: radius R times (1 + Σ strength·cos(k·a − phase)),
    // with an offset center. Phases, radius and center change smoothly over time; each line has
    // its own speed and direction, so they drift apart, cross and come back together.
    // ---------------------------------------------------------------------------
    static let LINE_SAMPLES = 96
    static let STROKE: [String: Double] = ["icon": 0.6, "menubar": 1.15]  // line width in units of the 24×24 square
    static let DIR = [1.0, -1, 1]                                         // direction of motion for each line
    static let SPEED = [1, 1.25, 0.8]                                     // relative speed of each line

    struct LineParams {
        var harm: [[Double]]
        var R: Double
        var cx: Double
        var cy: Double
    }

    // Parameters of line i at time t (seconds).
    static func lineParams(_ i: Int, _ t: Double) -> LineParams {
        let q = Double(i) * TAU / 3, s = DIR[i], sp = SPEED[i]
        return LineParams(
            harm: [
                [2, 0.1, 0.7 + s * 1.6 * sp * t + q],
                [3, 0.06, 1.9 - s * 1.1 * sp * t + q * 1.3],
                [4, 0.02, 0.4 + 1.3 * t + q],
            ],
            R: 7.0 + 0.25 * sin(2.4 * t + q),
            cx: 0.8 * cos(2.2 * t * sp + q),
            cy: 0.8 * sin(2.2 * t * sp + q)
        )
    }

    // Points of line i at time t (before smoothing), in a size×size square.
    static func linePoints(_ i: Int, _ t: Double, _ size: Double = 24) -> [CGPoint] {
        let p = lineParams(i, t), s = size / 24
        var pts: [CGPoint] = []
        for j in 0..<LINE_SAMPLES {
            let a = (Double(j) / Double(LINE_SAMPLES)) * TAU
            var f = 1.0
            for k in 0..<p.harm.count { f += p.harm[k][1] * cos(p.harm[k][0] * a - p.harm[k][2]) }
            pts.append(CGPoint(x: (12 + p.cx + cos(a) * p.R * f) * s, y: (12 + p.cy + sin(a) * p.R * f) * s))
        }
        return pts
    }

    // Three lines → one path of three closed contours in the 24×24 square
    // (draw as a stroke, no fill, round caps and joins, width STROKE[set]).
    static func transcribingPath(_ t: Double) -> CGPath {
        let path = CGMutablePath()
        for i in 0..<3 {
            let sm = KoeRing.smoothSegments(linePoints(i, t))
            path.move(to: sm.start)
            for g in sm.segs { path.addCurve(to: g.to, control1: g.c1, control2: g.c2) }
            path.closeSubpath()
        }
        return path
    }

    // ---------- drawing (not in the JS: it uses SVG there) ----------

    /// 24×24 square (Y axis down) → size×size image in AppKit: the center point lands
    /// in the middle of the image — same placement as KoeRing.cgPath.
    static func placement(size: CGFloat, center: CGPoint) -> CGAffineTransform {
        let s = size / 24
        return CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: size / 2 - center.x * s, ty: size / 2 + center.y * s)
    }

    static func template(size: CGFloat, draw: @escaping (CGContext) -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            draw(ctx)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// "Paused" or "problem" (kind: "pause" / "problem"): resting ring + sign.
    /// Template image size×size pt; the ring is even-odd, the sign is a normal fill.
    static func markImage(_ kind: String, set: String = "menubar", size: CGFloat = 18,
                          center: CGPoint = CGPoint(x: 12, y: 12)) -> NSImage {
        let preset = set == "icon" ? "icon" : "menubar"
        let ring = KoeRing.cgPath(KoeRing.contours(KoeRing.radii(KoeRing.toParams(KoeRing.KEYS[0]), KoeRing.options(preset))),
                                  size: size, center: center)
        var place = placement(size: size, center: center)
        let mark = markPath(kind, set).copy(using: &place)!
        return template(size: size) { ctx in
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(ring)
            ctx.fillPath(using: .evenOdd)
            ctx.addPath(mark)
            ctx.fillPath(using: .winding)
        }
    }

    /// "Transcribing" at time t (seconds since the state began): three stroked lines.
    static func transcribingImage(t: Double, set: String = "menubar", size: CGFloat = 18,
                                  center: CGPoint = CGPoint(x: 12, y: 12)) -> NSImage {
        var place = placement(size: size, center: center)
        let lines = transcribingPath(t).copy(using: &place)!
        let width = STROKE[set == "icon" ? "icon" : "menubar"]! * size / 24
        return template(size: size) { ctx in
            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setLineWidth(width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.addPath(lines)
            ctx.strokePath()
        }
    }
}
