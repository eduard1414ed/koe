// The intro of the setup window: the water ring flows alone in the middle for a couple of seconds, then settles,
// and the letters k and e come in around it at its size, making the wordmark "koe". Then the window
// fades over to the first step. A click skips it.
//
// The letters and where the ring sits between them are taken from koe-logo/assets/wordmark/koe-wordmark.svg
// (units of its viewBox, Y down): the ring is the 24×24 square placed at (374, −650) with scale 33.333.
import SwiftUI

struct IntroView: View {
    /// Draw this moment (seconds from the start) instead of running: for --intro-png.
    var at: Double? = nil
    var finished: () -> Void = {}
    @State private var state = IntroState()

    static let length = 4.2

    final class IntroState {
        let animator = KoeRing.Animator()
        let restCenter = KoeRing.restCenter("wordmark")
        var start: Double?
        var last = 0.0
    }

    var body: some View {
        TimelineView(.animation(paused: at != nil)) { ctx in
            Canvas { gc, size in
                draw(&gc, size, time(ctx.date.timeIntervalSinceReferenceDate))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finished() }
        .task {
            guard at == nil else { return }
            try? await Task.sleep(for: .seconds(Self.length))
            finished()
        }
    }

    /// Seconds since the intro started; moves the water up to that moment.
    func time(_ now: Double) -> Double {
        let s = state
        let t: Double
        if let at {
            t = at
        } else {
            if s.start == nil { s.start = now }
            t = now - s.start!
        }
        // the water flows until 1.6 s, then settles into the resting shape (about a second)
        var step = s.last
        while step < t {
            let dt = min(1.0 / 60, t - step)
            s.animator.setRecording(step < 1.6)
            s.animator.setLevel(0.35 + 0.15 * sin(step * 0.9))
            _ = s.animator.tick(dt)
            step += dt
        }
        s.last = max(s.last, t)
        return t
    }

    func draw(_ gc: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let ease = { (x: Double) -> Double in let v = min(1, max(0, x)); return v * v * (3 - 2 * v) }
        // the ring stays where it is, the size it is: its middle is the middle of the window, and the letters are
        // put around it at the same size (in the wordmark the ring's 24×24 square is 33.333 units per point of it)
        let scale = 9.0                              // points per unit of the ring's 24×24 square
        let k = scale / 33.333                       // points per wordmark unit
        let origin = CGPoint(x: size.width / 2 - state.restCenter.x * scale, y: size.height / 2 - state.restCenter.y * scale)

        let appear = ease(t / 0.5)
        var ring = gc
        ring.opacity = appear
        let grow = 0.92 + 0.08 * appear
        let about = CGPoint(x: size.width / 2, y: size.height / 2)
        let ringT = CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: about.x, y: about.y).scaledBy(x: grow, y: grow).translatedBy(x: -about.x, y: -about.y))
        ring.fill(Self.ring(state.animator.contours("wordmark", 24)).applying(ringT),
                  with: .color(.ink), style: FillStyle(eoFill: true))

        // the letters come in from the sides
        for (path, from, delay) in [(Self.k, -1.0, 1.7), (Self.e, 1.0, 1.85)] {
            let v = ease((t - delay) / 0.9)
            guard v > 0 else { continue }
            var l = gc
            l.opacity = v
            let shift = from * 24 * (1 - v)
            let tr = CGAffineTransform(translationX: origin.x - 374 * k + shift, y: origin.y + 650 * k).scaledBy(x: k, y: k)
            l.fill(path.applying(tr), with: .color(.ink))
        }
    }

    /// The ring's two contours in the 24×24 square, Y down (as in the SVG), for an even-odd fill.
    static func ring(_ c: KoeRing.Contours) -> Path {
        var p = Path()
        for pts in [c.outer, c.inner] {
            let sm = KoeRing.smoothSegments(pts)
            p.move(to: sm.start)
            for seg in sm.segs { p.addCurve(to: seg.to, control1: seg.c1, control2: seg.c2) }
            p.closeSubpath()
        }
        return p
    }

    static let k = svgPath("M374.0 0.0 134.0 -241.0 370.0 -470.0H457.0L200.0 -223.0L203.0 -263.0L467.0 0.0ZM71.0 0.0V-708.0H141.0V0.0Z")
    static let e = svgPath("M1342.0 10.0Q1271.0 10.0 1215.0 -22.0Q1159.0 -54.0 1126.5 -110.0Q1094.0 -166.0 1094.0 -236.0Q1094.0 -305.0 1126.0 -360.5Q1158.0 -416.0 1213.0 -448.0Q1268.0 -480.0 1336.0 -480.0Q1400.0 -480.0 1449.5 -451.0Q1499.0 -422.0 1527.5 -370.5Q1556.0 -319.0 1556.0 -252.0Q1556.0 -244.0 1555.0 -233.5Q1554.0 -223.0 1551.0 -209.0H1144.0V-269.0H1513.0L1488.0 -247.0Q1489.0 -299.0 1470.5 -336.5Q1452.0 -374.0 1417.5 -394.5Q1383.0 -415.0 1334.0 -415.0Q1283.0 -415.0 1245.0 -393.0Q1207.0 -371.0 1185.5 -331.5Q1164.0 -292.0 1164.0 -238.0Q1164.0 -184.0 1186.5 -143.0Q1209.0 -102.0 1249.5 -79.0Q1290.0 -56.0 1343.0 -56.0Q1386.0 -56.0 1422.0 -71.5Q1458.0 -87.0 1483.0 -118.0L1528.0 -72.0Q1495.0 -33.0 1446.5 -11.5Q1398.0 10.0 1342.0 10.0Z")

    /// The SVG path commands the wordmark uses (absolute M L H V Q C Z) → a Path.
    static func svgPath(_ d: String) -> Path {
        var tokens: [String] = [], cur = ""
        func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }
        for ch in d {
            if ch.isLetter { flush(); tokens.append(String(ch)) }
            else if ch == " " || ch == "," { flush() }
            else if ch == "-" { flush(); cur = "-" }
            else { cur.append(ch) }
        }
        flush()
        var p = Path(), i = 0, cmd = "", at = CGPoint.zero
        func num() -> CGFloat { defer { i += 1 }; return CGFloat(Double(tokens[i]) ?? 0) }
        func pt() -> CGPoint { let x = num(); return CGPoint(x: x, y: num()) }
        while i < tokens.count {
            if tokens[i].first!.isLetter {
                cmd = tokens[i]
                i += 1
                if cmd == "Z" { p.closeSubpath() }
                continue
            }
            switch cmd {
            case "M": at = pt(); p.move(to: at); cmd = "L"
            case "L": at = pt(); p.addLine(to: at)
            case "H": at.x = num(); p.addLine(to: at)
            case "V": at.y = num(); p.addLine(to: at)
            case "Q": let c = pt(); at = pt(); p.addQuadCurve(to: at, control: c)
            case "C": let c1 = pt(), c2 = pt(); at = pt(); p.addCurve(to: at, control1: c1, control2: c2)
            default: i += 1
            }
        }
        return p
    }
}
