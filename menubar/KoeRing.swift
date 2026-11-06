// Koe — the water ring: the shape of the menu bar icon and its animation while recording.
//
// Line-by-line port of koe-logo/reference/koe-ring.js, which is the source of truth:
// don't change the constants; if they differ, fix the JS. Compare with koe-logo/reference/preview.html.
//
// Same coordinate system as the original: 24×24 square, center (12, 12), angle 0 points right,
// angles grow clockwise, the Y axis points down. In NSImage (Y axis up)
// points are flipped when drawing: y → size − y.
import AppKit

enum KoeRing {
    static let TAU = Double.pi * 2

    struct Key {
        let name: String
        let h: [[Double]]
        let pools: [[Double]]
        let n: [Double]
    }

    // Six key shapes.
    // h      — circle distortions: [harmonic, strength, orientation angle]
    // pools  — three pools of water: [center angle, width, thickness]
    // n      — phases of the fine edge roughness (gives the "ink" edge)
    // Shape 0 is the resting state — that is the logo.
    static let KEYS: [Key] = [
        Key(name: "rest",     h: [[2, 0.05, 0.7], [3, 0.035, 1.9]],                    pools: [[2.5, 0.9, 3.2], [5.7, 0.45, 0.5], [0.9, 0.4, 0]],   n: [0.3, 1.1, 2.0, 0.6]),
        Key(name: "triangle", h: [[3, 0.08, -0.5], [2, 0.035, 0.9], [5, 0.015, 0.3]],  pools: [[3.6, 0.55, 2.0], [0.6, 0.6, 2.2], [5.2, 0.4, 0.8]], n: [1.4, 2.7, 0.2, 1.9]),
        Key(name: "drop",     h: [[1, 0.11, -0.14], [2, 0.08, -0.14], [3, 0.025, -0.14]], pools: [[3.0, 1.1, 3.0], [6.1, 0.4, 0.3], [1.3, 0.4, 0.6]], n: [2.2, 0.5, 1.3, 2.8]),
        Key(name: "quad",     h: [[4, 0.055, 0.35], [2, 0.05, 1.9], [3, 0.02, 0.8]],  pools: [[4.4, 0.6, 1.5], [1.2, 0.6, 1.6], [2.9, 0.45, 1.0]], n: [0.9, 1.8, 2.9, 0.1]),
        Key(name: "pebble",   h: [[5, 0.03, 0.2], [3, 0.045, 1.4], [2, 0.06, 0.4]],   pools: [[5.5, 0.5, 2.2], [3.9, 0.5, 1.4], [1.0, 0.6, 2.0]], n: [2.6, 0.4, 1.7, 1.2]),
        Key(name: "spread",   h: [[2, 0.04, 1.0], [3, 0.05, 2.6], [4, 0.025, 0.9]],   pools: [[1.9, 0.5, 0.9], [4.0, 0.5, 0.8], [0.0, 0.4, 0.7]], n: [1.1, 2.3, 0.6, 2.4]),
    ]

    // Ready-made thickness settings for different sizes.
    // extra   — added to the thin part (small sizes need it thicker)
    // poolMul — how much thicker the pools are than usual (stronger contrast in the menu bar)
    struct Preset {
        var extra: Double = 0
        var poolMul: Double? = nil
    }

    static let PRESETS: [String: Preset] = [
        "icon":     Preset(extra: 0),                    // app icon, 128 px and up
        "small":    Preset(extra: 0.3),                  // 48–96 px
        "tiny":     Preset(extra: 0.55),                 // 16–32 px
        "menubar":  Preset(extra: 0.3, poolMul: 1.35),   // menu bar, ~18 pt (both at rest and while recording)
        "wordmark": Preset(extra: 0),                    // the "o" in the wordmark
    ]

    static let BASE_THIN = 0.9   // thickness of the thinnest part of the ring
    static let RADIUS = 7.0      // mean ring radius
    static let WATER = 3.2       // total amount of water — constant, it only flows around
    static let OUT_FRAC = 0.4    // share of a pool that spreads outward (the rest goes inward)
    static let SAMPLES = 120     // points around the circle

    static func wrap(_ x: Double) -> Double { atan2(sin(x), cos(x)) }

    struct Params {
        var hc: [Double]
        var pools: [[Double]]
        var n: [Double]
    }

    // Key shape → parameters. Harmonics are stored as (cos, sin) pairs
    // so they can be blended smoothly between shapes.
    static func toParams(_ k: Key) -> Params {
        var hc = [Double](repeating: 0, count: 8)
        for h in k.h {
            let j = (Int(h[0]) - 1) * 2
            // As in the JS: the 5th harmonic (triangle, pebble) writes past the end of the array, which grows
            // to 10, and the new cells become NaN (undefined + number). This doesn't change the shape
            // (radii only uses 4 harmonics), but it shifts the vec() layout — that's what makes
            // the animation exactly as in the preview.
            while hc.count <= j + 1 { hc.append(.nan) }
            hc[j] += h[1] * cos(h[0] * h[2])
            hc[j + 1] += h[1] * sin(h[0] * h[2])
        }
        return Params(hc: hc, pools: k.pools, n: k.n)
    }

    struct Options {
        var extra = 0.0
        var poolMul: Double? = nil
        var vel: [Double]? = nil
        var L = 0.0
        var tau = 0.0
    }

    struct Radii {
        var outer: [Double]
        var inner: [Double]
    }

    // Parameters → outer and inner radius at SAMPLES points around the circle.
    // opt: extra, poolMul, vel (pool speeds, draw the "tail"), L (loudness 0..1), tau (time, s)
    static func radii(_ P: Params, _ opt: Options = Options()) -> Radii {
        let extra = opt.extra, mul = opt.poolMul ?? 1
        let L = opt.L, tau = opt.tau, vel = opt.vel
        var V = 0.0
        for q in 0..<P.pools.count { V += P.pools[q][1] * max(0, P.pools[q][2]) }
        let scale = (WATER / max(0.5, V)) * mul
        var outer = [Double](repeating: 0, count: SAMPLES), inner = [Double](repeating: 0, count: SAMPLES)
        for j in 0..<SAMPLES {
            let a = (Double(j) / Double(SAMPLES)) * TAU
            var t = BASE_THIN + extra
            for q in 0..<P.pools.count {
                let p = P.pools[q]
                let d = wrap(a - p[0])
                var w = max(0.2, p[1])
                // A moving pool stretches backwards, like a drop with a tail.
                if let vel, d * vel[q] < 0 { w *= 1 + min(0.9, abs(vel[q]) * 0.7) }
                t += max(0, p[2]) * scale * exp(-(d / w) * (d / w))
            }
            var f = 1.0
            for k in 1...4 { f += P.hc[(k - 1) * 2] * cos(Double(k) * a) + P.hc[(k - 1) * 2 + 1] * sin(Double(k) * a) }
            // A light ripple along the edge from the voice.
            let rc = RADIUS * f + 0.025 * L * sin(10 * a - tau * 4) + 0.02 * L * sin(5 * a + tau * 2.1)
            let ro = rc + t * OUT_FRAC + 0.05 * sin(9 * a + P.n[0]) + 0.035 * sin(14 * a + P.n[1])
            var ri = rc - t * (1 - OUT_FRAC) + 0.045 * sin(8 * a + P.n[2]) + 0.035 * sin(12 * a + P.n[3])
            let minW = 0.6 + extra * 0.5
            if ro - ri < minW { ri = ro - minW }
            outer[j] = ro
            inner[j] = ri
        }
        return Radii(outer: outer, inner: inner)
    }

    struct Contours {
        var outer: [CGPoint]
        var inner: [CGPoint]
    }

    // Radii → two closed point contours in a size×size square.
    static func contours(_ r: Radii, _ size: Double = 24) -> Contours {
        let s = size / 24, N = r.outer.count
        var out: [CGPoint] = [], inn: [CGPoint] = []
        for j in 0..<N {
            let a = (Double(j) / Double(N)) * TAU, c = cos(a), sn = sin(a)
            out.append(CGPoint(x: (12 + c * r.outer[j]) * s, y: (12 + sn * r.outer[j]) * s))
            inn.append(CGPoint(x: (12 + c * r.inner[j]) * s, y: (12 + sn * r.inner[j]) * s))
        }
        return Contours(outer: out, inner: inn.reversed())
    }

    struct Segment {
        var c1: CGPoint
        var c2: CGPoint
        var to: CGPoint
    }

    // Closed smoothed contour (Catmull–Rom spline → cubic Béziers).
    static func smoothSegments(_ pts: [CGPoint]) -> (start: CGPoint, segs: [Segment]) {
        let n = pts.count
        var segs: [Segment] = []
        for i in 0..<n {
            let p0 = pts[(i - 1 + n) % n], p1 = pts[i], p2 = pts[(i + 1) % n], p3 = pts[(i + 2) % n]
            segs.append(Segment(
                c1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                c2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                to: CGPoint(x: p2.x, y: p2.y)
            ))
        }
        return (pts[0], segs)
    }

    static func options(_ preset: String) -> Options {
        let base = PRESETS[preset] ?? PRESETS["icon"]!
        return Options(extra: base.extra, poolMul: base.poolMul)
    }

    // ---------- drawing (not in the JS: it uses toSVGPath there) ----------

    /// Middle of the resting shape's bounding box in the 24×24 square. In the asset pack the ring sits slightly left of and below
    /// center; placing the image by this point puts it exactly in the middle at rest.
    static func restCenter(_ preset: String = "menubar") -> CGPoint {
        let o = contours(radii(toParams(KEYS[0]), options(preset))).outer
        let xs = o.map(\.x), ys = o.map(\.y)
        return CGPoint(x: (xs.min()! + xs.max()!) / 2, y: (ys.min()! + ys.max()!) / 2)
    }

    /// Contours in the 24×24 square → a path in a size×size image for even-odd fill:
    /// the center point lands in the middle of the image, the Y axis is flipped for AppKit.
    static func cgPath(_ c: Contours, size: CGFloat, center: CGPoint) -> CGPath {
        let path = CGMutablePath()
        let s = size / 24
        let place = { (p: CGPoint) in CGPoint(x: size / 2 + (p.x - center.x) * s, y: size / 2 - (p.y - center.y) * s) }
        for pts in [c.outer, c.inner] {
            let sm = smoothSegments(pts)
            path.move(to: place(sm.start))
            for seg in sm.segs { path.addCurve(to: place(seg.to), control1: place(seg.c1), control2: place(seg.c2)) }
            path.closeSubpath()
        }
        return path
    }

    /// Template image size×size pt with the ring (macOS tints it to match the theme).
    /// center defaults to the middle of the 24×24 square, as in the asset pack.
    static func image(_ r: Radii, size: CGFloat = 18, center: CGPoint = CGPoint(x: 12, y: 12)) -> NSImage {
        let path = cgPath(contours(r), size: size, center: center)
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        return img
    }

    /// Resting logo with the given preset (like KoeRing.restPath('menubar', 18) in the JS).
    static func restImage(preset: String = "menubar", size: CGFloat = 18, center: CGPoint = CGPoint(x: 12, y: 12)) -> NSImage {
        image(radii(toParams(KEYS[0]), options(preset)), size: size, center: center)
    }

    // ---------------------------------------------------------------------------
    // Animation while recording.
    //
    // How it works: the ring outline slowly and continuously passes through the six
    // key shapes (a spline over the parameters), while the three pools of water live separately —
    // they slowly crawl around the ring, water flows between them, sometimes gathering
    // into one big pool, sometimes spreading out almost evenly. The amount of water is constant.
    // The flow speed does NOT depend on loudness (otherwise the motion stutters); the voice
    // only adds a slight ripple along the edge. After stopping, the water returns to the resting shape.
    //
    // Usage:
    //   let anim = KoeRing.Animator()
    //   anim.setRecording(true)
    //   every frame (30–60 fps): anim.setLevel(mic level 0..1); anim.tick(dt)
    //                            let img = anim.image(preset: "menubar", size: 18)
    //   anim.isActive() == false → ring is at rest, the timer can be stopped.
    // ---------------------------------------------------------------------------

    // Pool state at rest — taken straight from the resting shape.
    static let REST: (a: [Double], w: [Double], share: [Double]) = {
        let p = KEYS[0].pools
        var V = 0.0
        for x in p { V += x[1] * x[2] }
        return (p.map { $0[0] }, p.map { $0[1] }, p.map { ($0[1] * $0[2]) / V })
    }()

    // Shape vectors are 21 or 23 long (see toParams); missing values are NaN, like undefined in JS.
    static func item(_ v: [Double], _ j: Int) -> Double { j < v.count ? v[j] : .nan }

    static func vec(_ P: Params) -> [Double] { P.hc + P.pools[0] + P.pools[1] + P.pools[2] + P.n }
    static func unvec(_ v: [Double]) -> Params {
        Params(hc: Array(v[0..<8]), pools: [Array(v[8..<11]), Array(v[11..<14]), Array(v[14..<17])], n: Array(v[17..<21]))
    }

    final class Animator {
        struct State {
            var rec = false, level = 0.0, tau = 0.0, fc = 0.0, L = 0.0, p = 0.0, back = 1.0, idle = 99.0
            var a = REST.a, v = [0.0, 0.0, 0.0], share = REST.share, w = REST.w
        }

        var speed: Double
        let keyVecs: [[Double]]
        var s = State()

        init(speed: Double = 1) {
            self.speed = speed
            keyVecs = KEYS.map { vec(toParams($0)) }
        }

        func setRecording(_ on: Bool) {
            s.rec = on
            if s.rec { s.idle = 0; if s.back >= 1 { s.p = 0 } }
        }

        // Mic loudness 0..1 (e.g. RMS, smoothed and normalized).
        func setLevel(_ level: Double) {
            s.level = max(0, min(1, level.isNaN ? 0 : level))
        }

        func isActive() -> Bool {
            s.rec || s.idle <= 3
        }

        // dt — seconds since the previous frame.
        @discardableResult
        func tick(_ dt: Double) -> Bool {
            let dt = min(0.033, max(0, dt))
            if !s.rec && s.idle > 3 { return false }
            s.tau += dt
            if s.rec {
                s.idle = 0
                let flow = 2.3 * speed
                s.fc += dt * flow
                s.p += dt * 0.3 * flow
                s.back = max(0, s.back - dt * 1.5)
            } else {
                s.back = min(1, s.back + dt * 1.2)
                if s.back >= 1 { s.idle += dt; s.p = 0 }
                if s.idle > 3 {
                    // The water has settled — set exactly the resting shape so the frame matches the logo.
                    s.a = REST.a; s.v = [0, 0, 0]; s.share = REST.share; s.w = REST.w; s.L = 0
                    return true
                }
            }
            let target = s.rec ? s.level : 0
            s.L += (target - s.L) * min(1, dt * 8)

            // Where each pool's water is pulled and how the water is shared between them.
            let fc = s.fc
            let g: [Double], shareT: [Double], wT: [Double]
            if s.rec {
                let g0 = 2.5 + 0.45 * fc + 0.5 * sin(0.4 * fc)
                g = [g0, g0 + 2.1 + 0.4 * sin(0.45 * fc + 2.0), g0 + 4.2 + 0.4 * sin(0.38 * fc + 4.0)]
                let beta = 0.95 + 0.7 * sin(0.17 * fc + 0.7)
                let om = [0.31, 0.37, 0.43], ph = [0, 2.1, 4.2]
                let raw = (0..<3).map { i in exp(1.7 * beta * sin(om[i] * fc + ph[i])) }
                let sum = raw[0] + raw[1] + raw[2]
                shareT = raw.map { $0 / sum }
                wT = shareT.enumerated().map { i, sh in 0.42 + 0.55 * sh + 0.1 * sin(0.9 * fc + Double(i) * 1.7) }
            } else {
                g = REST.a; shareT = REST.share; wT = REST.w
            }
            // Pools gently catch up with their target (a spring with almost no overshoot).
            let K = 14.0, C = 7.0, e = min(1, dt * 2.2)
            for i in 0..<3 {
                s.v[i] += (K * (1 - 0.12 * Double(i)) * wrap(g[i] - s.a[i]) - C * s.v[i]) * dt
                s.a[i] += s.v[i] * dt
                s.share[i] += (shareT[i] - s.share[i]) * e
                s.w[i] += (wT[i] - s.w[i]) * e
            }
            return true
        }

        // Smooth pass of the outline through the key shapes.
        func at(_ p: Double) -> [Double] {
            let K = keyVecs, n = K.count
            let fl = floor(p), i1 = ((Int(fl) % n) + n) % n, f = p - fl, f2 = f * f, f3 = f2 * f
            let A = K[(i1 - 1 + n) % n], B = K[i1], C = K[(i1 + 1) % n], D = K[(i1 + 2) % n]
            return B.indices.map { j in
                let a = item(A, j), b = B[j], c = item(C, j), d = item(D, j)
                return 0.5 * (2 * b + (-a + c) * f + (2 * a - 5 * b + 4 * c - d) * f2 + (-a + 3 * b - 3 * c + d) * f3)
            }
        }

        // Current shape parameters.
        func params() -> Params {
            let v = at(s.p), rest = keyVecs[0]
            let w = s.back * s.back * (3 - 2 * s.back), br = 1 - w
            var out = v.indices.map { j in v[j] * br + item(rest, j) * w }
            // While recording the outline bends more than in the key shapes.
            for j in 0..<8 { out[j] *= 1 + 0.6 * br }
            for i in 0..<3 {
                out[8 + i * 3] = s.a[i]
                out[9 + i * 3] = s.w[i]
                out[10 + i * 3] = (s.share[i] * WATER) / s.w[i]
            }
            return unvec(out)
        }

        func radii(_ preset: String = "icon") -> Radii {
            var opt = options(preset)
            opt.vel = s.v
            opt.L = s.L
            opt.tau = s.tau
            return KoeRing.radii(params(), opt)
        }

        func contours(_ preset: String = "icon", _ size: Double = 24) -> Contours {
            KoeRing.contours(radii(preset), size)
        }

        /// Current frame as a template image size×size pt.
        func image(preset: String = "menubar", size: CGFloat = 18, center: CGPoint = CGPoint(x: 12, y: 12)) -> NSImage {
            KoeRing.image(radii(preset), size: size, center: center)
        }
    }
}
