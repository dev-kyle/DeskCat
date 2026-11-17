// DeskCat — a little pixel cat that lives at the bottom of your screen.
// Mostly white with big black spots, a black tail, black ears and a black cap
// that comes down to the outer edges of her yellow eyes, with a white triangle
// between the eyes.
//
// Each pose is built from simple shapes (ellipses, tapered curves, triangles),
// rasterized onto a small pixel grid, then shaded per pixel with a limited
// palette and ordered dithering, and outlined — so it reads as pixel art.
//
// Click the cat to pet it. Drag it to pick it up (it lands on its feet).
// Use the menu bar item (or right-click the cat) for options.

import Cocoa
import simd

func P(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }

typealias V2 = SIMD2<Float>
func V(_ x: Float, _ y: Float) -> V2 { V2(x, y) }

// MARK: - Grid & palette

/// Size of one cat pixel, in points.
let S: CGFloat = 4
/// Sprite grid size, in cat pixels. Row 0 is the top.
let GW = 28, GH = 30
/// Row whose bottom edge is the ground line (rows below are room for paws reaching down a step).
let FEET_ROW = 24
/// Poses are laid out in "design units"; each cat pixel covers K × K of them.
let K: Float = 2
/// Design coordinates are shifted down this much, leaving headroom for ears when she tilts up.
let YOFF: Float = 4

typealias RGB = (UInt8, UInt8, UInt8)
// Flat, chunky palette: a couple of shades per material.
let whiteTones: [RGB] = [(249, 249, 244), (205, 200, 208), (134, 132, 136)]
let blackTones: [RGB] = [(47, 41, 54), (26, 25, 24), (14, 13, 12)]
let pinkTones: [RGB] = [(190, 114, 114), (160, 92, 96)]
let outlineRGB: RGB = (11, 10, 9)

let featureColors: [Character: RGB] = [
    "K": outlineRGB,
    "H": (255, 252, 226),  // eye sparkle
    "E": (250, 208, 52),   // yellow eye
    "A": (214, 150, 30),   // eye, lower amber
    "P": (20, 14, 18),     // pupil
    "N": (190, 114, 114),  // nose
    "n": (196, 100, 112),  // nose shade
    "M": (120, 70, 74),    // mouth
    "R": (150, 50, 60),    // open mouth
    "B": (240, 150, 158),  // blush
]

/// Light comes from the top-left, slightly in front.
let lightDir: SIMD3<Float> = simd_normalize(SIMD3<Float>(-0.45, -0.65, 0.62))

let bayer4: [Float] = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5].map { ($0 + 0.5) / 16 - 0.5 }

// MARK: - Rasterizer

enum Mat: UInt8 { case none, white, black, pink }
enum EyeStyle { case open, closed, happy }

struct Face {
    var ncell: Int  // nose column
    var erow: Int   // eye center row
    var eyes: EyeStyle = .open
    var blush = false
    var mouthOpen = false
}

func cross2(_ o: V2, _ a: V2, _ b: V2) -> Float { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }

func inTriangle(_ p: V2, _ a: V2, _ b: V2, _ c: V2) -> Bool {
    let d1 = cross2(a, b, p), d2 = cross2(b, c, p), d3 = cross2(c, a, p)
    let hasNeg = d1 < 0 || d2 < 0 || d3 < 0
    let hasPos = d1 > 0 || d2 > 0 || d3 > 0
    return !(hasNeg && hasPos)
}

func bezier(_ p0: V2, _ p1: V2, _ p2: V2, _ p3: V2, steps n: Int = 14) -> [V2] {
    (0...n).map { i in
        let t = Float(i) / Float(n), mt = 1 - t
        let a = p0 * (mt * mt * mt)
        let b = p1 * (3 * mt * mt * t)
        let c = p2 * (3 * mt * t * t)
        let d = p3 * (t * t * t)
        return a + b + c + d
    }
}

/// Material function for a body part with big black spots (in the part's -1...1 space).
func spotted(_ spots: [(Float, Float, Float, Float)]) -> (Float, Float) -> Mat {
    return { u, v in
        for (cx, cy, rx, ry) in spots {
            let a = (u - cx) / rx, b = (v - cy) / ry
            let wobble = 0.18 * sin(u * 11 + v * 7) * cos(v * 9 - u * 3)
            if a * a + b * b < 1 + wobble { return .black }
        }
        return .white
    }
}

struct Raster {
    var part = [Int](repeating: -1, count: GW * GH)
    var mat = [Mat](repeating: .none, count: GW * GH)
    var lum = [Float](repeating: 0, count: GW * GH)
    var bias = [Float](repeating: 0, count: GW * GH)
    private var parts = 0
    /// Overall head size (1 = current).
    nonisolated(unsafe) static var headScale: Float = 0.92
    /// Whole-pose rotation around `pivot` (design units). Positive swings the bottom to the right.
    var rot: Float = 0
    var pivot = V(0, 0)

    /// Design-space point for a cell center, undoing the pose rotation.
    func sample(_ c: Int, _ r: Int) -> V2 {
        let p = V((Float(c) + 0.5) * K, (Float(r) + 0.5) * K - YOFF)
        if rot == 0 { return p }
        let d = p - pivot, cs = cos(rot), sn = sin(rot)
        return pivot + V(d.x * cs - d.y * sn, d.x * sn + d.y * cs)
    }

    /// Where a design-space point ends up after the pose rotation.
    func rotated(_ p: V2) -> V2 {
        if rot == 0 { return p }
        let d = p - pivot, cs = cos(rot), sn = sin(rot)
        return pivot + V(d.x * cs + d.y * sn, -d.x * sn + d.y * cs)
    }

    /// Cell ranges to scan; the whole canvas when rotated.
    func box(_ c0: Int, _ c1: Int, _ r0: Int, _ r1: Int) -> (Int, Int, Int, Int) {
        rot == 0 ? (c0, c1, r0, r1) : (0, GW - 1, 0, GH - 1)
    }

    /// Parts are drawn back to front; a higher number is in front.
    mutating func newPart() -> Int { parts += 1; return parts }

    mutating func put(_ c: Int, _ r: Int, _ p: Int, _ m: Mat, _ l: Float, _ b: Float) {
        guard c >= 0, c < GW, r >= 0, r < GH else { return }
        let i = r * GW + c
        part[i] = p; mat[i] = m; lum[i] = l; bias[i] = b
    }

    mutating func ellipse(_ cx: Float, _ cy: Float, _ rx: Float, _ ry: Float, part p: Int, bias b: Float = 0,
                          angle: Float = 0, mat: (Float, Float) -> Mat) {
        let cosA = cos(angle), sinA = sin(angle)
        let ec0 = max(0, Int((cx - max(rx, ry)) / K)), ec1 = min(GW - 1, Int((cx + max(rx, ry)) / K) + 1)
        let rr = max(rx, ry)  // bounding box that also covers a rotated ellipse
        let er0 = max(0, Int((cy - rr + YOFF) / K)), er1 = min(GH - 1, Int((cy + rr + YOFF) / K) + 1)
        let (c0, c1, r0, r1) = box(ec0, ec1, er0, er1)
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 {
            for c in c0...c1 {
                // Rotate into the ellipse's own frame (angle > 0 tips the +x end up).
                let sp = sample(c, r)
                let px = sp.x - cx, py = sp.y - cy
                let u = (px * cosA - py * sinA) / rx
                let v = (px * sinA + py * cosA) / ry
                let d2 = u * u + v * v
                if d2 > 1 { continue }
                let n = SIMD3<Float>(u, v, (1 - d2).squareRoot())
                put(c, r, p, mat(u, v), simd_dot(n, lightDir), b)
            }
        }
    }

    /// A rounded tube along a polyline, tapering from rStart to rEnd.
    /// `spot` marks a stretch along the tube (0 = start, 1 = end) that's black instead of `mat`.
    mutating func tube(_ pts: [V2], _ rStart: Float, _ rEnd: Float, part p: Int, bias b: Float = 0, mat m: Mat,
                       spot: ClosedRange<Float>? = nil) {
        guard pts.count >= 2 else { return }
        var cum: [Float] = [0]
        for i in 1..<pts.count { cum.append(cum[i - 1] + simd_distance(pts[i - 1], pts[i])) }
        let total = max(cum[cum.count - 1], 0.001)
        let rmax = max(rStart, rEnd)
        var lo = pts[0], hi = pts[0]
        for q in pts { lo = simd_min(lo, q); hi = simd_max(hi, q) }
        let (c0, c1, r0, r1) = box(max(0, Int((lo.x - rmax) / K) - 1), min(GW - 1, Int((hi.x + rmax) / K) + 1),
                                   max(0, Int((lo.y - rmax + YOFF) / K) - 1), min(GH - 1, Int((hi.y + rmax + YOFF) / K) + 1))
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 {
            for c in c0...c1 {
                let pos = sample(c, r)
                var bestD = Float.greatestFiniteMagnitude, bestQ = pos, bestT: Float = 0
                for i in 0..<(pts.count - 1) {
                    let a = pts[i], ab = pts[i + 1] - a
                    let len2 = max(simd_length_squared(ab), 1e-6)
                    let tt = min(max(simd_dot(pos - a, ab) / len2, 0), 1)
                    let q = a + ab * tt
                    let d = simd_distance(pos, q)
                    if d < bestD {
                        bestD = d
                        bestQ = q
                        bestT = (cum[i] + tt * (cum[i + 1] - cum[i])) / total
                    }
                }
                let rad = rStart + (rEnd - rStart) * bestT
                if bestD > rad { continue }
                let k = bestD / rad
                let dir = bestD > 1e-4 ? (pos - bestQ) / bestD : V(0, 0)
                let n = SIMD3<Float>(dir.x * k, dir.y * k, max(0, 1 - k * k).squareRoot())
                let inSpot = spot.map { $0.contains(bestT) } ?? false
                put(c, r, p, inSpot ? .black : m, simd_dot(n, lightDir), b)
            }
        }
    }

    mutating func triangle(_ a: V2, _ b: V2, _ c: V2, part p: Int, lum l: Float, mat: (V2) -> Mat) {
        let lo = simd_min(simd_min(a, b), c), hi = simd_max(simd_max(a, b), c)
        let (c0, c1, r0, r1) = box(max(0, Int(lo.x / K)), min(GW - 1, Int(hi.x / K) + 1),
                                   max(0, Int((lo.y + YOFF) / K)), min(GH - 1, Int((hi.y + YOFF) / K) + 1))
        guard c0 <= c1, r0 <= r1 else { return }
        for r in r0...r1 {
            for col in c0...c1 {
                let pos = sample(col, r)
                if inTriangle(pos, a, b, c) { put(col, r, p, mat(pos), l, 0) }
            }
        }
    }

    /// Head with black ears and the black cap / white triangle marking. Returns where the face goes.
    mutating func head(_ hx: Float, _ hy: Float, look lx: Float, sleepy: Bool = false) -> Face {
        let p = newPart()
        let ncell = Int(((hx + lx * Raster.headScale) / K).rounded(.down))
        let erow = Int(((hy + YOFF) / K).rounded(.down))
        let fx = (Float(ncell) + 0.5) * K, fy = (Float(erow) + 0.5) * K - YOFF

        func ear(_ a: V2, _ tip: V2, _ b: V2, lum: Float) {
            let g = (a + tip + b) / 3
            let ia = g + (a - g) * 0.5 + V(0, 0.6)
            let it = g + (tip - g) * 0.5 + V(0, 0.6)
            let ib = g + (b - g) * 0.5 + V(0, 0.6)
            triangle(a, tip, b, part: p, lum: lum) { q in
                !sleepy && inTriangle(q, ia, it, ib) ? .pink : .black
            }
        }
        let hs = Raster.headScale
        func E(_ dx: Float, _ dy: Float) -> V2 { V(hx + dx * hs, hy + dy * hs) }
        if sleepy {
            // Relaxed ears while she sleeps: a bit shorter, tilted out, solid black (no pink showing).
            ear(E(-9.5, -3), E(-8.5, -12.5), E(-2, -6.5), lum: 0.55)
            ear(E(2, -6.5), E(8.5, -12.5), E(9.5, -3), lum: 0.25)
        } else {
            // Top of the head is a bit lower than the bottom is deep, so the black cap isn't too tall.
            ear(E(-9, -3.5), E(-7, -13.5), E(-1.5, -6.5), lum: 0.55)
            ear(E(1.5, -6.5), E(7, -13.5), E(9, -3.5), lum: 0.25)
        }

        let hrx: Float = 10 * hs, hcy = hy + 0.75 * hs, hry: Float = 8.25 * hs
        ellipse(hx, hcy, hrx, hry, part: p) { u, v in
            let dx = hx + u * hrx - fx
            let dy = hcy + v * hry - fy
            if abs(dx) < (dy + 6 * hs) * 0.55 { return .white }  // white triangle between the eyes
            if dy < 1.6 * hs + 0.4 * max(0, abs(dx) - 6.5 * hs) { return .black }  // cap down to the eyes
            return .white
        }
        if rot != 0 {
            let w = rotated(V(fx, fy))
            return Face(ncell: Int((w.x / K).rounded(.down)), erow: Int(((w.y + YOFF) / K).rounded(.down)))
        }
        return Face(ncell: ncell, erow: erow)
    }

    func isFront(_ c: Int, _ r: Int, _ p: Int) -> Bool {
        guard c >= 0, c < GW, r >= 0, r < GH else { return false }
        return part[r * GW + c] > p
    }

    func filled(_ c: Int, _ r: Int) -> Bool {
        guard c >= 0, c < GW, r >= 0, r < GH else { return false }
        return part[r * GW + c] >= 0
    }
}

// MARK: - Shading

struct Pixels {
    var data = [UInt8](repeating: 0, count: GW * GH * 4)

    mutating func set(_ c: Int, _ r: Int, _ rgb: RGB, alpha: UInt8 = 255) {
        guard c >= 0, c < GW, r >= 0, r < GH else { return }
        let i = (r * GW + c) * 4
        // premultiplied
        data[i] = UInt8(Int(rgb.0) * Int(alpha) / 255)
        data[i + 1] = UInt8(Int(rgb.1) * Int(alpha) / 255)
        data[i + 2] = UInt8(Int(rgb.2) * Int(alpha) / 255)
        data[i + 3] = alpha
    }

    func alpha(_ c: Int, _ r: Int) -> UInt8 {
        guard c >= 0, c < GW, r >= 0, r < GH else { return 0 }
        return data[(r * GW + c) * 4 + 3]
    }
}

func shade(_ ras: Raster) -> Pixels {
    var px = Pixels()
    for r in 0..<GH {
        for c in 0..<GW {
            let i = r * GW + c
            let p = ras.part[i]
            guard p >= 0 else { continue }
            let tones: [RGB]
            switch ras.mat[i] {
            case .white: tones = whiteTones
            case .black: tones = blackTones
            case .pink: tones = pinkTones
            case .none: continue
            }
            let n = Float(tones.count)
            let s = 0.5 - ras.lum[i] * 0.5  // 0 = fully lit, 1 = away from the light
            // Flat cel shading: hard bands, no dithering.
            var f = s * n * 1.25 - 0.45 + ras.bias[i]
            if r >= 1 && ras.part[i - GW] > p { f += 1 }  // shadow cast by a part above
            var t = min(max(Int(f.rounded(.down)), 0), tones.count - 1)
            // Dark crease where a part in front overlaps this one.
            if ras.isFront(c - 1, r, p) || ras.isFront(c + 1, r, p) || ras.isFront(c, r - 1, p) || ras.isFront(c, r + 1, p) {
                t = tones.count - 1
            }
            px.set(c, r, tones[t])
        }
    }
    // Outline
    for r in 0..<GH {
        for c in 0..<GW where !ras.filled(c, r) {
            if ras.filled(c - 1, r) || ras.filled(c + 1, r) || ras.filled(c, r - 1) || ras.filled(c, r + 1) {
                px.set(c, r, outlineRGB)
            }
        }
    }
    return px
}

func stamp(_ px: inout Pixels, _ sprite: [String], left: Int, top: Int, color: (Character, Int, Int) -> RGB?) {
    for (dy, row) in sprite.enumerated() {
        for (dx, ch) in row.enumerated() where ch != "." {
            if let rgb = color(ch, left + dx, top + dy) { px.set(left + dx, top + dy, rgb) }
        }
    }
}

func drawFace(_ face: Face, on px: inout Pixels, raster ras: Raster) {
    let base = px
    let lid: (Character, Int, Int) -> RGB? = { ch, c, r in
        if ch == "L" {
            // Light lid line on dark fur, dark line on light fur.
            guard c >= 0, c < GW, r >= 0, r < GH else { return nil }
            let i = (r * GW + c) * 4
            let lum = Int(base.data[i]) + Int(base.data[i + 1]) + Int(base.data[i + 2])
            return lum < 300 ? (190, 186, 194) : (14, 13, 12)
        }
        return featureColors[ch]
    }
    let eye: [String]
    switch face.eyes {
    case .open: eye = ["EP", "AP"]  // yellow with a dark pupil toward the nose
    case .closed: eye = ["LLL"]
    case .happy: eye = [".L.", "L.L"]
    }
    let top = face.eyes == .happy ? face.erow - 1 : face.erow  // happy arches sit up on the black cap
    if face.eyes == .open {
        // Two-pixel eyes either side of the nose, mirrored so both pupils face inward.
        stamp(&px, eye, left: face.ncell - 3, top: top, color: lid)
        stamp(&px, eye.map { String($0.reversed()) }, left: face.ncell + 2, top: top, color: lid)
    } else {
        let w = eye[0].count
        stamp(&px, eye, left: face.ncell - 2 - w / 2, top: top, color: lid)
        stamp(&px, eye, left: face.ncell + 2 - w / 2, top: top, color: lid)
    }

    let nrow = face.erow + 2
    stamp(&px, ["N"], left: face.ncell, top: nrow, color: lid)
    if face.mouthOpen {
        stamp(&px, ["R"], left: face.ncell, top: nrow + 1, color: lid)
    }
    if face.blush {
        stamp(&px, ["B"], left: face.ncell - 3, top: nrow, color: lid)
        stamp(&px, ["B"], left: face.ncell + 3, top: nrow, color: lid)
    }
}

/// Faint light rim so the cat stays visible on dark wallpapers.
func addRim(_ px: inout Pixels) {
    var rim: [(Int, Int)] = []
    for r in 0..<GH {
        for c in 0..<GW where px.alpha(c, r) == 0 {
            if px.alpha(c - 1, r) == 255 || px.alpha(c + 1, r) == 255 || px.alpha(c, r - 1) == 255 || px.alpha(c, r + 1) == 255 {
                rim.append((c, r))
            }
        }
    }
    for (c, r) in rim { px.set(c, r, (255, 255, 255), alpha: 64) }
}

func makeImage(_ px: Pixels, mirrored: Bool) -> CGImage? {
    var buf = px.data
    if mirrored {
        for r in 0..<GH {
            for c in 0..<(GW / 2) {
                for k in 0..<4 {
                    buf.swapAt((r * GW + c) * 4 + k, (r * GW + (GW - 1 - c)) * 4 + k)
                }
            }
        }
    }
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    return buf.withUnsafeMutableBytes { raw -> CGImage? in
        guard let ctx = CGContext(data: raw.baseAddress, width: GW, height: GH, bitsPerComponent: 8,
                                  bytesPerRow: GW * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return ctx.makeImage()
    }
}

// MARK: - Overlay sprites (hearts, z's)

@MainActor let spriteColors: [Character: NSColor] = [
    "K": rgb(0.12, 0.07, 0.09),
    "R": rgb(1.0, 0.38, 0.52),
    "H": rgb(1.0, 0.86, 0.90),
    "Z": rgb(0.55, 0.68, 1.0),
]

let heartSprite = [
    ".KK...KK.",
    "KRRK.KRRK",
    "KRHRKRRRK",
    "KRRRRRRRK",
    ".KRRRRRK.",
    "..KRRRK..",
    "...KRK...",
    "....K....",
]
let zSprite = ["ZZZZ", "..Z.", ".Z..", "ZZZZ"]

// MARK: - Yarn ball

/// A pixel-art yarn ball in its own small window. Its strands turn as it rolls.
final class YarnView: NSView {
    var angle: CGFloat = 0
    weak var cat: CatView?
    static let px: CGFloat = 2, cells = 11

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        NSGraphicsContext.current?.shouldAntialias = false
        let n = YarnView.cells, c0 = CGFloat(n) / 2
        let ca = cos(angle), sa = sin(angle)
        for r in 0..<n {
            for c in 0..<n {
                let dx = CGFloat(c) + 0.5 - c0, dy = CGFloat(r) + 0.5 - c0  // dy up (view isn't flipped)
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist > 5.3 { continue }
                let col: NSColor
                if dist > 4.4 {
                    col = rgb(0.43, 0.14, 0.24)
                } else {
                    let u = dx * ca - dy * sa, v = dx * sa + dy * ca
                    let s1 = (u + v * 0.35 + 20).truncatingRemainder(dividingBy: 2.2) < 0.7
                    let s2 = (v - u * 0.45 + 20).truncatingRemainder(dividingBy: 2.6) < 0.65
                    if dx < -0.8 && dy > 0.8 && dist < 3.2 && !s1 { col = rgb(1.0, 0.70, 0.78) }
                    else if s1 || s2 { col = rgb(0.72, 0.28, 0.42) }
                    else if dx - dy > 2.6 { col = rgb(0.78, 0.31, 0.45) }
                    else { col = rgb(0.91, 0.42, 0.56) }
                }
                col.setFill()
                NSRect(x: CGFloat(c) * YarnView.px, y: CGFloat(r) * YarnView.px,
                       width: YarnView.px, height: YarnView.px).fill()
            }
        }
    }

    override func mouseDown(with event: NSEvent) { cat?.ballMouseDown() }
    override func mouseDragged(with event: NSEvent) { cat?.ballMouseDragged() }
    override func mouseUp(with event: NSEvent) { cat?.ballMouseUp() }
}

// MARK: - The cat

enum CatState {
    case walking, sitting, sleeping, chasing, petted, held, falling, landing, swatting, crouching, jumping, climbing,
         playing,
         airborne  // drawing only: mid-air, ready to land
}

// MARK: - Ledges (screen floors and the tops of other windows)

/// A surface she can stand on: the floor of a screen, or the visible part of a window's top edge.
struct Ledge {
    var x0: CGFloat; var x1: CGFloat; var y: CGFloat; var isFloor: Bool
    /// A platform she conjured herself (stairs / floating plank).
    var isTemp = false
}

// MARK: - Temporary platforms

/// A small pixel-art wooden plank drawn in its own click-through window.
final class PlatformView: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        NSGraphicsContext.current?.shouldAntialias = false
        let cols = Int(bounds.width / S), rows = Int(bounds.height / S)
        // Pale, ghostly slab (the window itself is also translucent).
        let ink = rgb(0.55, 0.62, 0.80)
        let light = rgb(0.93, 0.97, 1.0), mid = rgb(0.78, 0.86, 0.98), seam = rgb(0.68, 0.76, 0.93)
        for c in 0..<cols {
            for r in 0..<rows {
                let edge = c == 0 || c == cols - 1
                let corner = edge && (r == 0 || r == rows - 1)
                if corner { continue }
                let col: NSColor
                if r == 0 || r == rows - 1 || edge { col = ink }
                else if r == 1 { col = (c % 7 == 3) ? mid : light }
                else { col = (c % 7 == 3) ? seam : mid }
                col.setFill()
                NSRect(x: CGFloat(c) * S, y: bounds.height - CGFloat(r + 1) * S, width: S, height: S).fill()
            }
        }
    }
}

final class Prop {
    let ledge: Ledge
    let window: NSPanel
    var alpha: CGFloat = 0
    var delay: CGFloat
    var fading = false
    /// A stair step: drawn, but not something she lands on (she walks up the stairs instead).
    let isStep: Bool
    init(ledge: Ledge, window: NSPanel, delay: CGFloat, isStep: Bool) {
        self.ledge = ledge; self.window = window; self.delay = delay; self.isStep = isStep
    }
}

func subtractSpan(_ segs: [(CGFloat, CGFloat)], _ a: CGFloat, _ b: CGFloat) -> [(CGFloat, CGFloat)] {
    var out: [(CGFloat, CGFloat)] = []
    for (s, e) in segs {
        if b <= s || a >= e { out.append((s, e)); continue }
        if a > s { out.append((s, a)) }
        if b < e { out.append((b, e)) }
    }
    return out
}

/// Reads other apps' window frames (no special permission needed) and returns every place she can stand.
@MainActor func scanLedges() -> [Ledge] {
    var ledges: [Ledge] = NSScreen.screens.map { scr in
        let f = scr.visibleFrame
        return Ledge(x0: f.minX, x1: f.maxX, y: f.minY, isFloor: true)
    }
    guard let primary = NSScreen.screens.first,
          let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]]
    else { return ledges }
    let primaryTop = primary.frame.maxY
    let me = ProcessInfo.processInfo.processIdentifier
    var inFront: [CGRect] = []  // windows in front of the one being looked at (list is front to back)

    for w in info {
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != me,
              ((w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0.05,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd)
        else { continue }
        // Window-server coordinates have y going down from the top of the main screen.
        let rect = CGRect(x: r.minX, y: primaryTop - r.maxY, width: r.width, height: r.height)
        defer { inFront.append(rect) }
        guard rect.width >= 100, rect.height >= 60 else { continue }

        let top = rect.maxY
        guard let scr = NSScreen.screens.first(where: { $0.frame.contains(P(rect.midX, top - 1)) }) else { continue }
        let vf = scr.visibleFrame
        // Needs headroom under the menu bar, and must be above the floor.
        guard top < vf.maxY - 70, top > vf.minY + 40 else { continue }

        var segs = [(max(rect.minX, vf.minX), min(rect.maxX, vf.maxX))]
        for f in inFront where f.minY < top - 1 && f.maxY > top + 1 {
            segs = subtractSpan(segs, f.minX, f.maxX)
        }
        for (a, b) in segs where b - a >= 80 {
            ledges.append(Ledge(x0: a, x1: b, y: top, isFloor: false))
        }
    }
    return ledges
}

struct Heart { var x: CGFloat; var y: CGFloat; var age: CGFloat; var vx: CGFloat }

final class CatView: NSView {
    static let size = NSSize(width: 132, height: 170)
    /// Where the cat's feet sit inside the view.
    let anchor = P(66, 22)

    var menuBuilder: ((NSMenu) -> Void)?

    // Feet position in global screen coordinates.
    var x: CGFloat = 0
    var y: CGFloat = 0
    var vy: CGFloat = 0
    var facingRight = true

    var state: CatState = .sitting
    var stateTime: CGFloat = 2
    var t: CGFloat = 0
    var walkPhase: CGFloat = 0
    var blinkIn: CGFloat = 3
    var blinkLeft: CGFloat = 0
    var hearts: [Heart] = []
    var heartTimer: CGFloat = 0
    var dragging = false
    var swatCooldown: CGFloat = 2
    /// Pendulum swing while held / thrown (radians; positive = bottom swung right on screen).
    var swing: CGFloat = 0, swingVel: CGFloat = 0
    var airTime: CGFloat = 0
    var heldMouseX: CGFloat = 0, heldVX: CGFloat = 0
    var dragLast = NSPoint.zero, dragLastTime: TimeInterval = 0, dragVel = NSPoint.zero
    var vx: CGFloat = 0
    var ledges: [Ledge] = []
    var ledgeScanIn: CGFloat = 0
    /// What she's standing on right now.
    var ledge: Ledge?
    var jumpTarget: Ledge?
    /// The ledge she just jumped off; she won't land back on it mid-leap.
    var departed: Ledge?
    var baseLedges: [Ledge] = []
    var props: [Prop] = []
    /// Platforms still to hop through (stairs), and the stairs themselves for the trip back down.
    var route: [Ledge] = []
    var stepProps: [Prop] = []
    var stair: (sx: CGFloat, sy: CGFloat, dir: CGFloat, n: Int, perch: Ledge)?
    static let stepRun: CGFloat = 28
    static let stepRise: CGFloat = 12
    // Body tilt while walking up the stairs.
    var climbPitch: Float = 0
    static let swatDuration: CGFloat = 0.9

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Screen helpers

    func currentScreen() -> NSScreen {
        let p = P(x, y + 20)
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens[0]
    }
    var floorY: CGFloat { currentScreen().visibleFrame.minY }
    var xRange: ClosedRange<CGFloat> {
        let f = currentScreen().visibleFrame
        return (f.minX + 50)...(f.maxX - 50)
    }

    /// Where she can walk on the current ledge.
    var walkRange: ClosedRange<CGFloat> {
        guard let l = ledge else { return xRange }
        let m: CGFloat = l.isFloor ? 50 : 22
        let lo = l.x0 + m, hi = l.x1 - m
        return lo <= hi ? lo...hi : ((l.x0 + l.x1) / 2)...((l.x0 + l.x1) / 2)
    }

    func onLedge(_ l: Ledge) -> Bool { x >= l.x0 + 6 && x <= l.x1 - 6 }

    /// The ledge under her feet (follows a window that moved up or down a little).
    func support(tolerance: CGFloat) -> Ledge? {
        ledges.filter { onLedge($0) && abs($0.y - y) <= tolerance }.min { abs($0.y - y) < abs($1.y - y) }
    }

    /// The highest ledge she passed through while coming down this frame.
    func landing(from oldY: CGFloat, to newY: CGFloat) -> Ledge? {
        ledges.filter { l in
            if let d = departed, d.x0 == l.x0, d.x1 == l.x1, d.y == l.y { return false }
            return onLedge(l) && l.y < oldY && l.y >= newY
        }.max { $0.y < $1.y }
    }

    /// Ledges within jumping reach (up or down).
    func jumpTargets() -> [Ledge] {
        guard let cur = ledge else { return [] }
        return ledges.filter { l in
            guard !l.isTemp, abs(l.y - cur.y) > 30, l.x1 - l.x0 >= 90 else { return false }
            let tx = min(max(x, l.x0 + 30), l.x1 - 30)
            let dy = l.y - y
            return abs(tx - x) <= 300 && dy <= 340 && dy >= -450
        }
    }

    func startJump(to l: Ledge) {
        var tx = l.isTemp ? (l.x0 + l.x1) / 2 : min(max(x + .random(in: -50...50), l.x0 + 30), l.x1 - 30)
        if let cur = ledge, cur.isTemp, !l.isTemp {
            // Leaving one of her platforms: aim clear of it so she doesn't land back on it.
            let away = facingRight ? cur.x1 + 30 : cur.x0 - 30
            tx = min(max(away, l.x0 + 30), l.x1 - 30)
        }
        let dx = tx - x, dy = l.y - y
        let g: CGFloat = 2200
        departed = ledge
        let hop = !route.isEmpty || (ledge?.isTemp ?? false)  // quick little hops on stairs
        if dy < -20 {
            // Leaping down: a small hop up first, then the drop.
            let up: CGFloat = 260
            let flight = (up + (up * up - 2 * g * dy).squareRoot()) / g
            vx = dx / flight
            vy = up
        } else {
            let flight = max(hop ? 0.3 : 0.4, (2 * max(dy, 0) / g).squareRoot() * 1.2 + abs(dx) / 1500)
            vx = dx / flight
            vy = (dy + 0.5 * g * flight * flight) / flight
        }
        if abs(dx) > 4 { facingRight = dx > 0 }
        enter(.jumping)
    }

    func hopOff(right: Bool) {
        let dir: CGFloat = right ? 1 : -1
        x += dir * 28
        vx = dir * 70
        vy = 160
        enter(.falling)
    }

    // MARK: Behaviour

    func enter(_ s: CatState, _ duration: CGFloat? = nil) {
        state = s
        if s == .falling { airTime = 0 }
        switch s {
        case .walking:
            stateTime = duration ?? .random(in: 3...8)
            facingRight = Bool.random()
        case .sitting: stateTime = duration ?? .random(in: 3...7)
        case .sleeping: stateTime = duration ?? .random(in: 12...25)
        case .chasing: stateTime = duration ?? 6
        case .petted: stateTime = duration ?? 2.5
        case .landing: stateTime = duration ?? 0.6
        case .swatting: stateTime = duration ?? CatView.swatDuration
        case .crouching: stateTime = duration ?? 0.35
        case .held, .falling, .jumping, .climbing, .playing, .airborne: stateTime = .infinity
        }
    }

    // MARK: Conjured platforms

    static let ghostAlpha: CGFloat = 0.55

    @discardableResult
    func addProps(_ ls: [Ledge], stagger: CGFloat, isStep: Bool = false) -> [Prop] {
        let h = (isStep ? 3 : 4) * S
        var made: [Prop] = []
        for (i, l) in ls.enumerated() {
            let r = NSRect(x: l.x0, y: l.y - h, width: l.x1 - l.x0, height: h)
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.level = window?.level ?? .floating
            p.contentView = PlatformView(frame: NSRect(origin: .zero, size: r.size))
            p.alphaValue = 0
            p.orderFrontRegardless()
            let prop = Prop(ledge: l, window: p, delay: CGFloat(i) * stagger, isStep: isStep)
            props.append(prop)
            made.append(prop)
        }
        window?.orderFrontRegardless()  // keep the cat in front of her platforms
        refreshLedges()
        return made
    }

    func releaseProps() {
        for p in props { p.fading = true }
        stepProps = []
        refreshLedges()
    }

    func refreshLedges() {
        ledges = baseLedges + props.filter { !$0.fading && !$0.isStep }.map { $0.ledge }
    }

    func updateProps(_ dt: CGFloat) {
        for p in props {
            if p.delay > 0 && !p.fading { p.delay -= dt; continue }
            p.alpha = p.fading ? max(0, p.alpha - dt * 2) : min(CatView.ghostAlpha, p.alpha + dt * 4)
            p.window.alphaValue = p.alpha
        }
        for p in props where p.fading && p.alpha <= 0 { p.window.orderOut(nil) }
        props.removeAll { $0.fading && $0.alpha <= 0 }
    }

    /// A ghostly staircase appears and she climbs it to a perch at the top.
    /// Step i (1...n) is the tread she stands on after i step-ups; the perch is step n + 1.
    /// Each step fades away once she's past it.
    @discardableResult func climbStairs() -> Bool {
        guard let home = ledge, !home.isTemp, props.isEmpty,
              state != .held, state != .falling, state != .jumping else { return false }
        let vf = currentScreen().visibleFrame
        let n = Int.random(in: 4...6)
        let run = CatView.stepRun, rise = CatView.stepRise
        for dir: CGFloat in (facingRight ? [1, -1] : [-1, 1]) {
            let sx = (x + dir * (CatView.stepRun / 2 - 2)).rounded()
            // Riser i sits just ahead of where she starts her i-th step-up.
            func span(_ i: Int, width: CGFloat) -> (CGFloat, CGFloat) {
                let d0 = run * CGFloat(i) + 2
                return dir > 0 ? (sx + d0, sx + d0 + width) : (sx - d0 - width, sx - d0)
            }
            let topY = (y + rise * CGFloat(n + 1)).rounded()
            let (px0, px1) = span(n + 1, width: 100)
            let lo = min(sx, px0), hi = max(sx, px1)
            guard lo > vf.minX + 10, hi < vf.maxX - 10, topY < vf.maxY - 170 else { continue }
            var steps: [Ledge] = []
            for i in 1...n {
                let (a, b) = span(i, width: run)
                steps.append(Ledge(x0: a, x1: b, y: (y + rise * CGFloat(i)).rounded(), isFloor: false, isTemp: true))
            }
            let perch = Ledge(x0: px0, x1: px1, y: topY, isFloor: false, isTemp: true)
            facingRight = dir > 0
            stepProps = addProps(steps, stagger: 0.06, isStep: true)
            addProps([perch], stagger: 0)
            stair = (sx: sx, sy: y, dir: dir, n: n, perch: perch)
            route = []
            enter(.climbing)
            return true
        }
        return false
    }

    /// Height of the tread at distance d along the stairs (0 = ground, n + 1 = perch).
    func treadHeight(_ d: CGFloat) -> CGFloat {
        guard let st = stair else { return y }
        let k = max(0, min(CGFloat(st.n + 1), ((d - 2) / CatView.stepRun).rounded(.down)))
        return st.sy + CatView.stepRise * k
    }

    /// While walking up: her body sits halfway between the step under her back paws and the step
    /// under her front paws, tilted by the difference. Both ease toward their targets.
    func applyClimb(d: CGFloat, ease: CGFloat = 0.18) {
        guard stair != nil else { return }
        let back = treadHeight(d - 22), front = treadHeight(d + 14)
        let targetY = (back + front) / 2
        let targetPitch = Float(atan((front - back) / 36) * 0.85)  // hips are ~36pt apart
        y += (targetY - y) * ease
        climbPitch += (targetPitch - climbPitch) * Float(ease)
    }

    /// A single plank appears somewhere above her and she leaps onto it.
    @discardableResult func jumpToFloatingLedge() -> Bool {
        guard let home = ledge, !home.isTemp, props.isEmpty else { return false }
        let vf = currentScreen().visibleFrame
        for _ in 0..<8 {
            let dir: CGFloat = Bool.random() ? 1 : -1
            let w: CGFloat = 96
            let x0 = (x + dir * .random(in: 90...230) - w / 2).rounded()
            let ly = (y + .random(in: 130...280)).rounded()
            guard x0 > vf.minX + 10, x0 + w < vf.maxX - 10, ly < vf.maxY - 170 else { continue }
            let l = Ledge(x0: x0, x1: x0 + w, y: ly, isFloor: false, isTemp: true)
            facingRight = dir > 0
            addProps([l], stagger: 0)
            route = []
            jumpTarget = l
            enter(.crouching, 0.45)
            return true
        }
        return false
    }

    /// Leave a conjured platform with a leap down to something below.
    func descend() {
        let below = baseLedges.filter { l in
            let tx = min(max(x, l.x0 + 30), l.x1 - 30)
            return l.y < y - 30 && abs(tx - x) <= 300 && l.y - y >= -450
        }
        guard let target = below.max(by: { $0.y < $1.y }) else { hopOff(right: facingRight); return }
        route = []
        jumpTarget = target
        if let cur = ledge {
            // Leap off whichever side has more of the target ledge beyond it.
            let roomRight = target.x1 - cur.x1, roomLeft = cur.x0 - target.x0
            facingRight = roomRight == roomLeft ? facingRight : roomRight > roomLeft
        }
        enter(.crouching, 0.3)
    }

    // MARK: Yarn ball

    var ballPanel: NSPanel?
    var ballView: YarnView?
    var bx: CGFloat = 0, by: CGFloat = 0, bvx: CGFloat = 0, bvy: CGFloat = 0
    var ballAlpha: CGFloat = 0
    var ballFading = false
    var ballIdle: CGFloat = 0
    var ballHeld = false, ballDragged = false
    var ballGrab = NSPoint.zero
    var ballLastMouse = NSPoint.zero, ballLastTime: TimeInterval = 0, ballFling = NSPoint.zero
    var batsLeft = 0
    var playTime: CGFloat = 0, playWait: CGFloat = 0
    var playMoving = false
    var playSwat = false, swatHit = false

    var ballSize: CGFloat { CGFloat(YarnView.cells) * YarnView.px }

    func spawnBall(x px: CGFloat, y py: CGFloat) {
        if ballPanel == nil {
            let r = NSRect(x: 0, y: 0, width: ballSize, height: ballSize)
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            p.level = window?.level ?? .floating
            let v = YarnView(frame: r)
            v.cat = self
            p.contentView = v
            p.alphaValue = 0
            p.orderFrontRegardless()
            ballPanel = p
            ballView = v
            ballAlpha = 0
        }
        bx = px; by = py; bvx = 0; bvy = 0
        ballFading = false
        ballIdle = 0
    }

    /// Start a play session: a ball drops in near her (if there isn't one) and she goes after it.
    @discardableResult func startPlay() -> Bool {
        guard let l = ledge, !l.isTemp, state != .held, state != .falling, state != .jumping, state != .climbing
        else { return false }
        if ballPanel == nil || ballFading {
            let dir: CGFloat = facingRight ? 1 : -1
            let r = walkRange
            spawnBall(x: min(max(x + dir * 80, r.lowerBound), r.upperBound), y: y + 90)
            bvx = dir * 40
        }
        batsLeft = Int.random(in: 3...6)
        playTime = 0
        playWait = 0
        playSwat = false
        enter(.playing)
        return true
    }

    func endPlay() {
        playSwat = false
        playMoving = false
        ballIdle = 0
        enter(.sitting, .random(in: 3...5))
    }

    func ballSupport() -> Ledge? {
        ledges.filter { bx >= $0.x0 && bx <= $0.x1 && abs($0.y - by) < 1.5 }.first
    }

    func updateBall(_ dt: CGFloat) {
        guard let panel = ballPanel, let view = ballView else { return }
        ballAlpha = ballFading ? max(0, ballAlpha - dt * 2) : min(1, ballAlpha + dt * 4)
        panel.alphaValue = ballAlpha
        if ballFading && ballAlpha <= 0 {
            panel.orderOut(nil)
            ballPanel = nil
            ballView = nil
            return
        }
        if !ballHeld {
            let resting = bvy == 0 && ballSupport() != nil
            if !resting {
                let oldY = by
                bvy -= 2200 * dt
                bx += bvx * dt
                by += bvy * dt
                if bvy <= 0, let l = ledges.filter({ bx >= $0.x0 && bx <= $0.x1 && $0.y <= oldY && $0.y >= by })
                    .max(by: { $0.y < $1.y }) {
                    by = l.y
                    bvy = bvy < -160 ? -bvy * 0.45 : 0  // bounce, then settle
                }
            } else {
                bx += bvx * dt
                bvx *= max(0, 1 - 1.8 * dt)  // rolling friction
                if abs(bvx) < 6 { bvx = 0 }
            }
            // Bounce off the sides of the screen.
            let vf = (NSScreen.screens.first { $0.frame.contains(P(bx, by + 5)) } ?? currentScreen()).visibleFrame
            if bx < vf.minX + 12 { bx = vf.minX + 12; bvx = abs(bvx) * 0.6 }
            if bx > vf.maxX - 12 { bx = vf.maxX - 12; bvx = -abs(bvx) * 0.6 }
            if by < (ledges.filter { $0.isFloor }.map { $0.y }.min() ?? 0) - 100 { ballFading = true }
            view.angle -= bvx * dt / 11
        }
        // Left alone for a while, it fades away.
        if state != .playing && !(state == .swatting && playSwat) && !ballHeld {
            ballIdle += dt
            if ballIdle > 3 { ballFading = true }
        }
        panel.setFrameOrigin(P((bx - ballSize / 2).rounded(), (by - 1).rounded()))
        view.needsDisplay = true
    }

    func ballMouseDown() {
        ballHeld = true
        ballDragged = false
        let m = NSEvent.mouseLocation
        ballGrab = P(m.x - bx, m.y - by)
        ballLastMouse = m
        ballLastTime = ProcessInfo.processInfo.systemUptime
        ballFling = .zero
        ballIdle = 0
    }

    func ballMouseDragged() {
        let m = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let dt = max(0.001, now - ballLastTime)
        ballFling = P((m.x - ballLastMouse.x) / dt, (m.y - ballLastMouse.y) / dt)
        ballLastMouse = m
        ballLastTime = now
        ballDragged = true
        bx = m.x - ballGrab.x
        by = m.y - ballGrab.y
        bvx = 0; bvy = 0
    }

    func ballMouseUp() {
        ballHeld = false
        ballIdle = 0
        if ballDragged {
            bvx = max(-1200, min(1200, ballFling.x))
            bvy = max(-1200, min(1200, ballFling.y))
        } else {
            // A click knocks it away from the cursor.
            let away: CGFloat = NSEvent.mouseLocation.x < bx ? 1 : -1
            bvx = away * .random(in: 220...380)
            bvy = .random(in: 120...260)
        }
        if [.sitting, .walking, .sleeping].contains(state) && CGFloat.random(in: 0..<1) < 0.75 { startPlay() }
    }

    func pickNext() {
        let r = CGFloat.random(in: 0..<1)
        // On one of her own platforms: hang out a bit, then head back down.
        if let l = ledge, l.isTemp {
            if state == .sleeping || r < 0.4 { descend() } else { enter(r < 0.85 ? .sitting : .sleeping) }
            return
        }
        if state != .sleeping {
            let a = CGFloat.random(in: 0..<1)
            if a < 0.12 && climbStairs() { return }
            if a >= 0.12 && a < 0.22 && jumpToFloatingLedge() { return }
            if a >= 0.22 && a < 0.30 && startPlay() { return }
        }
        if state == .sleeping {
            enter(r < 0.6 ? .sitting : .walking)
            return
        }
        // Sometimes leap up onto a window (or down to a lower one).
        let targets = jumpTargets()
        if !targets.isEmpty && CGFloat.random(in: 0..<1) < 0.35 {
            let ups = targets.filter { $0.y > y }
            jumpTarget = (ups.isEmpty || Bool.random() == false && targets.count > ups.count ? targets : ups).randomElement()
            if let tl = jumpTarget {
                let tx = min(max(x, tl.x0 + 30), tl.x1 - 30)
                if abs(tx - x) > 4 { facingRight = tx > x }
            }
            enter(.crouching)
            return
        }
        switch r {
        case ..<0.45: enter(.walking)
        case ..<0.70: enter(.sitting)
        case ..<0.85: enter(.chasing)
        default: enter(.sleeping)
        }
    }

    func pet() {
        enter(.petted)
        spawnHeart(); spawnHeart()
        heartTimer = 0.35
    }

    func spawnHeart() {
        hearts.append(Heart(x: anchor.x - 9 + .random(in: -16...16),
                            y: anchor.y + 80, age: 0, vx: .random(in: -8...8)))
    }

    @objc func tick() {
        let dt: CGFloat = 1.0 / 60
        t += dt
        stateTime -= dt
        blinkIn -= dt
        if blinkIn <= 0 { blinkLeft = 0.15; blinkIn = .random(in: 2...6) }
        blinkLeft = max(0, blinkLeft - dt)

        let mouse = NSEvent.mouseLocation
        ledgeScanIn -= dt
        if ledgeScanIn <= 0 || baseLedges.isEmpty {
            baseLedges = scanLedges()
            ledgeScanIn = 0.25
        }
        updateProps(dt)
        updateBall(dt)
        refreshLedges()
        let range = walkRange

        // Sometimes swat at the cursor when it comes within reach.
        swatCooldown -= dt
        if (state == .sitting || state == .walking) && swatCooldown <= 0 {
            let dx = mouse.x - x, dy = mouse.y - y
            if abs(dx) < 80 && dy > 10 && dy < 110 && CGFloat.random(in: 0..<1) < dt * 2.5 {
                facingRight = dx > 0
                enter(.swatting)
                swatCooldown = .random(in: 3...6)
            }
        }

        switch state {
        case .walking:
            x += (facingRight ? 1 : -1) * 48 * dt
            walkPhase += dt * 8
            let onWindow = !(ledge?.isFloor ?? true)
            if x >= range.upperBound {
                if onWindow && facingRight && Bool.random() { hopOff(right: true) } else { x = range.upperBound; facingRight = false }
            } else if x <= range.lowerBound {
                if onWindow && !facingRight && Bool.random() { hopOff(right: false) } else { x = range.lowerBound; facingRight = true }
            }
            if state == .walking && stateTime <= 0 { pickNext() }
        case .chasing:
            let target = min(max(mouse.x, range.lowerBound), range.upperBound)
            let d = target - x
            if abs(d) < 24 || stateTime <= 0 {
                enter(.sitting, .random(in: 4...7))
            } else {
                facingRight = d > 0
                x += (d > 0 ? 1 : -1) * 140 * dt
                walkPhase += dt * 16
            }
        case .sitting:
            let dx = mouse.x - x
            if abs(dx) > 20 && abs(dx) < 500 && abs(mouse.y - y) < 600 { facingRight = dx > 0 }
            if stateTime <= 0 { pickNext() }
        case .sleeping:
            if stateTime <= 0 { pickNext() }
        case .landing:
            if stateTime <= 0 {
                if !route.isEmpty {
                    // Next step of the staircase.
                    let next = route.removeFirst()
                    jumpTarget = next
                    facingRight = (next.x0 + next.x1) / 2 > x
                    enter(.crouching, 0.12)
                } else {
                    if !(ledge?.isTemp ?? false) && !props.isEmpty { releaseProps() }
                    enter(.sitting, .random(in: 2...4))
                }
            }
        case .swatting:
            if playSwat && !swatHit && stateTime < CatView.swatDuration * 0.75
                && abs(bx - x) < 64 && abs(by - y) < 30 {
                // Paw connects: send the yarn rolling.
                bvx = (facingRight ? 1 : -1) * .random(in: 200...430)
                bvy = .random(in: 60...260)
                swatHit = true
                batsLeft -= 1
            }
            if stateTime <= 0 {
                if playSwat { playSwat = false; enter(.playing) } else { enter(.sitting, .random(in: 2...4)) }
            }
        case .playing:
            playTime += dt
            guard ballPanel != nil, !ballFading else { endPlay(); break }
            if batsLeft <= 0 || playTime > 22 { endPlay(); break }
            let dir: CGFloat = bx >= x ? 1 : -1
            if abs(by - y) > 24 || ballHeld {
                // Out of reach (on another level, in the air, or you're holding it): watch it.
                playMoving = false
                facingRight = dir > 0
                if bvy == 0 && !ballHeld { playWait += dt; if playWait > 3 { endPlay() } }
                break
            }
            playWait = 0
            let r = walkRange
            let target = min(max(bx - dir * 30, r.lowerBound), r.upperBound)
            let d = target - x
            if abs(d) > 6 {
                playMoving = true
                facingRight = d > 0
                x += (d > 0 ? 1 : -1) * min(150 * dt, abs(d))
                walkPhase += dt * 16
                if abs(bx - x) > 80 && (x <= r.lowerBound + 0.5 || x >= r.upperBound - 0.5) { playWait += dt }
                if playWait > 2 { endPlay() }
            } else {
                playMoving = false
                facingRight = dir > 0
                if abs(bvx) < 60 && abs(bx - x) < 64 {
                    swatHit = false
                    playSwat = true
                    enter(.swatting)
                }
            }
        case .petted:
            heartTimer -= dt
            if heartTimer <= 0 { spawnHeart(); heartTimer = 0.35 }
            if stateTime <= 0 { enter(.sitting, .random(in: 2...4)) }
        case .climbing:
            guard let st = stair else { enter(.sitting); break }
            let d = (x - st.sx) * st.dir + 34 * dt
            x = st.sx + st.dir * d
            walkPhase += dt * 8
            if d >= CatView.stepRun * CGFloat(st.n + 1) + 36 {
                // Walked onto the perch.
                y = st.perch.y
                ledge = st.perch
                stair = nil
                climbPitch = 0
                for p in stepProps { p.fading = true }
                stepProps = []
                enter(.sitting, .random(in: 3...6))
                break
            }
            applyClimb(d: d)
            // Steps fade away once her back paws have left them.
            for (i, p) in stepProps.enumerated() where !p.fading && d > CatView.stepRun * CGFloat(i + 2) + 26 {
                p.fading = true
            }
        case .crouching:
            if stateTime <= 0 {
                if let tl = jumpTarget { startJump(to: tl) } else { enter(.sitting) }
            }
        case .airborne:
            break
        case .held:
            // Hanging from the scruff: her body lags behind your cursor and swings back.
            let mx = NSEvent.mouseLocation.x
            let vxNow = (mx - heldMouseX) / dt
            heldMouseX = mx
            let smoothed = heldVX * 0.6 + vxNow * 0.4
            swingVel -= (smoothed - heldVX) / 70
            heldVX = smoothed
            swingVel += (-30 * sin(swing) - 2.4 * swingVel) * dt
            swing = max(-0.7, min(0.7, swing + swingVel * dt))
        case .falling, .jumping:
            if state == .falling {
                airTime += dt
                if abs(vx) > 60 { facingRight = vx > 0 }
                swingVel += (-30 * sin(swing) - 3 * swingVel) * dt
                swing = max(-0.7, min(0.7, swing + swingVel * dt))
                // Thrown: bounce softly off the sides of the screen.
                let vf = currentScreen().visibleFrame
                if x < vf.minX + 40 && vx < 0 { x = vf.minX + 40; vx = -vx * 0.5 }
                if x > vf.maxX - 40 && vx > 0 { x = vf.maxX - 40; vx = -vx * 0.5 }
            }
            let oldY = y
            vy -= 2200 * dt
            x += vx * dt
            y += vy * dt
            if vy <= 0, let l = landing(from: oldY, to: y) {
                let wasJump = state == .jumping
                departed = nil
                swing = 0
                swingVel = 0
                y = l.y
                ledge = l
                vx = 0
                vy = 0
                enter(.landing, !route.isEmpty ? 0.12 : (wasJump ? 0.35 : 0.6))
            } else if y < (ledges.filter { $0.isFloor }.map { $0.y }.min() ?? 0) - 150 {
                // Fell somewhere with no floor (e.g. between screens): put her back on the main screen.
                let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
                x = min(max(x, f.minX + 50), f.maxX - 50)
                y = f.minY
                vx = 0
                vy = 0
                enter(.landing)
            }
        }
        // Stay on whatever is underneath; if it's gone (window moved or closed), fall.
        if state != .held && state != .falling && state != .jumping && state != .climbing {
            if let l = support(tolerance: 40) {
                y = l.y
                ledge = l
            } else {
                vx = 0
                vy = 0
                enter(.falling)
            }
        }

        for i in hearts.indices {
            hearts[i].age += dt
            hearts[i].y += 28 * dt
            hearts[i].x += hearts[i].vx * dt
        }
        hearts.removeAll { $0.age > 1.6 }

        window?.setFrameOrigin(P((x - anchor.x).rounded(), (y - anchor.y).rounded()))
        needsDisplay = true

        if CatView.trace {
            traceIn -= dt
            if traceIn <= 0 || state != lastTraced {
                traceIn = 0.25
                lastTraced = state
                print(String(format: "t=%5.2f %@ x=%.0f y=%.0f on=%@ props=%d ball=%@ bats=%d", t, "\(state)", x, y,
                             ledge.map { $0.isTemp ? "temp" : ($0.isFloor ? "floor" : "window") } ?? "-",
                             props.count, ballPanel == nil ? "-" : String(format: "%.0f,%.0f", bx, by), batsLeft))
                fflush(stdout)
            }
            if let action = CatView.traceAction, t > 2.5, !traceFired, state == .sitting || state == .walking {
                traceFired = true
                switch action {
                case "stairs": print("-> climbStairs \(climbStairs())")
                case "yarn": print("-> startPlay \(startPlay())")
                default: print("-> jumpUp \(jumpToFloatingLedge())")
                }
            }
        }
    }

    static var trace = false
    static var traceAction: String?
    var traceIn: CGFloat = 0
    var lastTraced: CatState = .sitting
    var traceFired = false

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) { dragging = false }

    override func mouseDragged(with event: NSEvent) {
        let m = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        if dragging {
            let ddt = max(0.001, now - dragLastTime)
            let v = P((m.x - dragLast.x) / ddt, (m.y - dragLast.y) / ddt)
            dragVel = P(dragVel.x * 0.5 + v.x * 0.5, dragVel.y * 0.5 + v.y * 0.5)
        }
        dragLast = m
        dragLastTime = now
        if !dragging {
            dragging = true
            dragVel = .zero
            heldMouseX = m.x
            heldVX = 0
            swing = 0
            swingVel = 0
            route = []
            stair = nil
            playSwat = false
            releaseProps()
            hearts.removeAll()
            enter(.held)
        }
        // Hold the cat by the scruff.
        x = m.x
        y = m.y - 61
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            // A light toss: keep some of your release speed (none if you'd stopped moving).
            let fresh = ProcessInfo.processInfo.systemUptime - dragLastTime < 0.08
            vx = fresh ? max(-900, min(900, dragVel.x * 0.6)) : 0
            vy = fresh ? max(-500, min(800, dragVel.y * 0.6)) : 0
            enter(.falling)
        } else {
            pet()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menuBuilder?(menu)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    // MARK: Poses (built facing right; mirrored when facing left)

    func leg(_ ras: inout Raster, _ x: Float, dx: Float, lift: Float, top: Float, part p: Int, bias b: Float,
             spot: ClosedRange<Float>? = nil) {
        ras.tube([V(x + dx * 0.3, top), V(x + dx, 44.8 - lift)], 2.2, 2.1, part: p, bias: b, mat: .white, spot: spot)
    }

    /// A two-segment leg. The paw swings forward in an arc while lifted (sin > 0)
    /// and slides back while planted; the joint bends backward like a cat's hock/wrist.
    func jointedLeg(_ ras: inout Raster, hipX: Float, phase: Float, bob: Float, hind: Bool,
                    part p: Int, bias b: Float, spot: ClosedRange<Float>? = nil,
                    stride: Float = 3.2, liftHeight: Float = 2.6, hipY: Float? = nil, ground: Float = 44.8) {
        let hip = V(hipX, (hipY ?? 30) + bob)
        let lift = max(0, sin(phase)) * liftHeight
        var foot = V(hipX - stride * cos(phase), ground - lift)
        let l1: Float = hind ? 7.7 : 7.5, l2: Float = hind ? 7.7 : 7.5
        let dir = simd_normalize(foot - hip)
        // A paw can only reach as far as the leg is long; it never stretches.
        let reach = l1 + l2 - 0.6
        if simd_distance(hip, foot) > reach { foot = hip + dir * reach }
        let d = simd_distance(hip, foot)
        let a = (l1 * l1 - l2 * l2 + d * d) / (2 * d)
        let h = max(0, l1 * l1 - a * a).squareRoot()
        // Perpendicular pointing backward (-x) so the joint bends toward the tail.
        var perp = V(-dir.y, dir.x)
        if perp.x > 0 { perp = -perp }
        let knee = hip + dir * a + perp * h
        ras.tube([hip, knee, foot], hind ? 2.9 : 2.4, 2.0, part: p, bias: b, mat: .white, spot: spot)
    }

    func buildPose() -> (Raster, Face) {
        let saved = state
        if state == .playing { state = playMoving ? .chasing : .sitting }  // reuse run / sit poses
        if state == .falling && airTime >= 0.12 { state = .airborne }  // righted herself after a moment
        defer { state = saved }
        var ras = Raster()
        let tq = Float((t * 6).rounded(.down) / 6)  // animation time, stepped like sprite frames
        let sway = (sin(tq * 3) * 2).rounded()
        let blink = blinkLeft > 0
        var face: Face

        switch state {
        case .chasing, .jumping, .playing:
            // Bounding run, 8 frames per stride: front legs reach together, back legs push together,
            // the body stretches and leaves the ground, and the tail streams out behind.
            // Mid-leap she holds a stretched frame going up and a reaching frame coming down.
            let frame = state == .jumping ? (vy > 0 ? 2 : 6) : Int(walkPhase * 2) % 8
            let phi = Float(frame) / 8 * 2 * .pi
            let air = max(0, sin(phi))
            let bob: Float = -1.4 * air
            let stretch: Float = 1.4 * cos(phi)
            let tailP = ras.newPart()
            ras.tube(bezier(V(14 - stretch, 26 + bob), V(9, 25 + bob), V(5.5, 21 + bob), V(5, 13 + sway * 0.5 + bob)),
                     1.7, 1.2, part: tailP, mat: .black)
            let bodyP = ras.newPart()
            jointedLeg(&ras, hipX: 20 - stretch, phase: phi + .pi + 1.1, bob: bob, hind: true, part: bodyP, bias: 1.6,
                       stride: 5.5, liftHeight: 3.6)
            jointedLeg(&ras, hipX: 38 + stretch, phase: phi + 1.1, bob: bob, hind: false, part: bodyP, bias: 1.6,
                       stride: 5.5, liftHeight: 3.6)
            ras.ellipse(26, 29 + bob, 13 + stretch * 0.6, 7.2, part: bodyP,
                        mat: spotted([(-0.35, -0.35, 0.32, 0.55), (0.22, -0.55, 0.22, 0.35), (-0.8, 0.25, 0.2, 0.35)]))
            jointedLeg(&ras, hipX: 16 - stretch, phase: phi + .pi, bob: bob, hind: true, part: bodyP, bias: 0,
                       spot: 0.1...0.5, stride: 5.5, liftHeight: 3.6)  // her back left leg
            jointedLeg(&ras, hipX: 34 + stretch, phase: phi, bob: bob, hind: false, part: bodyP, bias: 0,
                       stride: 5.5, liftHeight: 3.6)
            face = ras.head(43 + stretch * 0.5, 18 + bob, look: 1.5)
            face.eyes = blink ? .closed : .open

        case .climbing:
            // A walk tilted to the slope; each paw stands on the step under it.
            let pitch = climbPitch, cp = cos(pitch), sp = sin(pitch)
            let cx: Float = 26, cy: Float = 29
            func rot(_ lx: Float, _ ly: Float) -> V2 { V(cx + lx * cp + ly * sp, cy - lx * sp + ly * cp) }
            let dHere = stair.map { (x - $0.sx) * $0.dir } ?? 0
            let ptPerDesign = Float(S) / K
            // One full stride per stair: each paw lifts off one step and lands on the next.
            let run = Float(CatView.stepRun)
            let phi = (Float(dHere) / run * 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
            let phiStepped = (phi / (2 * .pi) * 8).rounded(.down) / 8 * 2 * .pi  // pixel-art frames
            let climbStride = run / (2 * ptPerDesign)  // paw sweep matches one stair
            func ground(_ hipX: Float, _ phase: Float) -> Float {
                guard stair != nil else { return 44.8 }
                let footX = hipX - climbStride * cos(phase)
                let footD = dHere + CGFloat((footX - 28) * ptPerDesign)
                return 44.8 - Float(treadHeight(footD) - y) / ptPerDesign
            }
            let tailBase = rot(-11, -4)
            let tailP = ras.newPart()
            ras.tube(bezier(tailBase, tailBase + V(-8.5, 0), V(3.5, 13 - sp * 12), V(7 + sway, 3.5 - sp * 10)),
                     1.7, 1.2, part: tailP, mat: .black)
            let bodyP = ras.newPart()
            let fb = rot(-7, 1), ff = rot(11, 1), nb = rot(-10, 1), nf = rot(8, 1)
            let pFB = phiStepped + .pi, pFF = phiStepped, pNB = phiStepped, pNF = phiStepped + .pi
            jointedLeg(&ras, hipX: fb.x, phase: pFB, bob: 0, hind: true, part: bodyP, bias: 0.9,
                       stride: climbStride, liftHeight: 4.5, hipY: fb.y, ground: ground(fb.x, pFB))
            jointedLeg(&ras, hipX: ff.x, phase: pFF, bob: 0, hind: false, part: bodyP, bias: 0.9,
                       stride: climbStride, liftHeight: 4.5, hipY: ff.y, ground: ground(ff.x, pFF))
            ras.ellipse(cx, cy, 13, 7.5, part: bodyP, angle: pitch,
                        mat: spotted([(-0.35, -0.35, 0.32, 0.55), (0.22, -0.55, 0.22, 0.35), (-0.8, 0.25, 0.2, 0.35)]))
            jointedLeg(&ras, hipX: nb.x, phase: pNB, bob: 0, hind: true, part: bodyP, bias: 0,
                       spot: 0.1...0.5, stride: climbStride, liftHeight: 4.5, hipY: nb.y,
                       ground: ground(nb.x, pNB))  // her back left leg
            jointedLeg(&ras, hipX: nf.x, phase: pNF, bob: 0, hind: false, part: bodyP, bias: 0,
                       stride: climbStride, liftHeight: 4.5, hipY: nf.y, ground: ground(nf.x, pNF))
            let hp = rot(17, -12)
            face = ras.head(hp.x, hp.y, look: 1.5)
            face.eyes = blink ? .closed : .open

        case .walking:
            // 8 frames per stride. Diagonal pairs move together.
            let frame = Int(walkPhase * 2) % 8
            let phi = Float(frame) / 8 * 2 * .pi
            let bob: Float = cos(2 * phi) > 0.3 ? -0.6 : 0
            let tailP = ras.newPart()
            ras.tube(bezier(V(15, 25 + bob), V(6.5, 25 + bob), V(3.5, 13 + bob), V(7 + sway, 3.5 + bob)),
                     1.7, 1.2, part: tailP, mat: .black)
            // Legs share the body's part so they blend into it with no crease.
            let bodyP = ras.newPart()
            jointedLeg(&ras, hipX: 19, phase: phi + .pi, bob: bob, hind: true, part: bodyP, bias: 0.9)
            jointedLeg(&ras, hipX: 37, phase: phi, bob: bob, hind: false, part: bodyP, bias: 0.9)
            ras.ellipse(26, 29 + bob, 13, 7.5, part: bodyP,
                        mat: spotted([(-0.35, -0.35, 0.32, 0.55), (0.22, -0.55, 0.22, 0.35), (-0.8, 0.25, 0.2, 0.35)]))
            jointedLeg(&ras, hipX: 16, phase: phi, bob: bob, hind: true, part: bodyP, bias: 0,
                       spot: 0.1...0.5)  // her back left leg
            jointedLeg(&ras, hipX: 34, phase: phi + .pi, bob: bob, hind: false, part: bodyP, bias: 0)
            face = ras.head(43, 17 + bob, look: 1.5)
            face.eyes = blink ? .closed : .open

        case .sitting, .petted, .landing, .swatting, .crouching:
            let tailP = ras.newPart()
            ras.tube(bezier(V(31, 44), V(42, 46.6), V(50.5, 44), V(48.5 + sway, 31)), 1.6, 1.2, part: tailP, mat: .black)
            let bodyP = ras.newPart()
            ras.ellipse(26, 35, 9.5, 11, part: bodyP,
                        mat: spotted([(-0.55, -0.35, 0.4, 0.42), (-0.7, 0.5, 0.25, 0.3)]))
            // Back left leg (the haunch) has her spot; legs blend into the body.
            ras.ellipse(20.5, 39.5, 7, 6.8, part: bodyP, mat: spotted([(0.1, -0.25, 0.55, 0.5)]))
            ras.tube([V(32.5, 33), V(33, 44.8)], 2.2, 2.1, part: bodyP, bias: 0.7, mat: .white)
            if state != .swatting {
                ras.tube([V(28.5, 33), V(28.5, 44.8)], 2.3, 2.2, part: bodyP, mat: .white)
            }
            face = ras.head(29, 18, look: state == .swatting ? 2.5 : 1.5)
            if state == .swatting {
                // Two quick swats: raise, lunge out, swipe down, pull back.
                let p = Float(max(0, min(1, 1 - stateTime / CatView.swatDuration)))
                let f = Int((p * 2).truncatingRemainder(dividingBy: 1) * 4)
                let paws = [V(35, 27), V(44, 24), V(45, 31), V(37, 35)]
                let shoulder = V(29, 31)
                let paw = paws[min(f, 3)]
                let elbow = (shoulder + paw) * 0.5 + V(0, -1.5)
                // Same part as the body so the arm blends into her chest with no crease.
                ras.tube([shoulder, elbow, paw], 2.3, 2.1, part: bodyP, mat: .white)
            }
            if state == .petted {
                face.eyes = .happy
                face.blush = true
            } else {
                face.eyes = blink ? .closed : .open
            }

        case .sleeping:
            let inhale: Float = sin(tq * 1.8) > 0 ? 1 : 0
            let bodyP = ras.newPart()
            ras.ellipse(25, 39.6 - inhale * 0.6, 17, 7 + inhale * 0.6, part: bodyP,
                        mat: spotted([(-0.45, -0.5, 0.2, 0.4), (0.1, -0.6, 0.13, 0.3)]))
            let tailP = ras.newPart()
            ras.tube(bezier(V(10, 40), V(5, 45), V(24, 46), V(35.5, 43.5)), 1.5, 1.2, part: tailP, mat: .black)
            face = ras.head(40, 38, look: 1, sleepy: true)
            face.eyes = .closed

        case .airborne:
            // Mid-air: nose tips with her motion; legs tucked going up, reaching for the ground coming down.
            ras.pivot = V(26, 29)
            ras.rot = Float(max(-0.35, min(0.35, vy / 1800)))
            let rising = vy > 150
            let ground: Float = rising ? 39.5 : 44.8
            let reach: Float = rising ? 2.0 : 4.0
            let tailP = ras.newPart()
            ras.tube(bezier(V(15, 25), V(8, 22), V(5, 13), V(9 + sway, 6)), 1.7, 1.2, part: tailP, mat: .black)
            let bodyP = ras.newPart()
            jointedLeg(&ras, hipX: 20, phase: 0.25, bob: 0, hind: true, part: bodyP, bias: 0.9,
                       stride: reach, liftHeight: 0, hipY: 30, ground: ground)
            jointedLeg(&ras, hipX: 37, phase: .pi - 0.25, bob: 0, hind: false, part: bodyP, bias: 0.9,
                       stride: reach, liftHeight: 0, hipY: 30, ground: ground)
            ras.ellipse(26, 29, 13, 7.5, part: bodyP,
                        mat: spotted([(-0.35, -0.35, 0.32, 0.55), (0.22, -0.55, 0.22, 0.35), (-0.8, 0.25, 0.2, 0.35)]))
            jointedLeg(&ras, hipX: 16, phase: 0, bob: 0, hind: true, part: bodyP, bias: 0,
                       spot: 0.1...0.5, stride: reach, liftHeight: 0, hipY: 30, ground: ground)  // her back left leg
            jointedLeg(&ras, hipX: 34, phase: .pi, bob: 0, hind: false, part: bodyP, bias: 0,
                       stride: reach, liftHeight: 0, hipY: 30, ground: ground)
            face = ras.head(43, 18, look: 1.5)
            face.eyes = .open

        case .held, .falling:
            // Hang from the scruff (just above the head's center); mirrored poses swing the other way.
            ras.pivot = V(28, 14)
            ras.rot = Float(facingRight ? swing : -swing)
            let tailP = ras.newPart()
            ras.tube(bezier(V(28, 38), V(28, 41), V(27 - sway, 43), V(29 + sway * 1.5, 45.5)), 1.4, 1.1,
                     part: tailP, mat: .black)
            let bodyP = ras.newPart()
            ras.tube([V(24.5, 38), V(24, 44.8)], 2.1, 2.1, part: bodyP, mat: .white)
            // Facing you, her left hind leg is on the viewer's right.
            ras.tube([V(31.5, 38), V(32, 44.8)], 2.1, 2.1, part: bodyP, mat: .white, spot: 0...0.5)
            ras.ellipse(28, 33, 6.5, 9.5, part: bodyP, mat: spotted([(0.35, -0.45, 0.4, 0.35), (-0.45, 0.35, 0.35, 0.3)]))
            ras.tube([V(21.8, 26), V(20.8, 34)], 2.0, 2.0, part: bodyP, mat: .white)
            ras.tube([V(34.2, 26), V(35.2, 34)], 2.0, 2.0, part: bodyP, mat: .white)
            face = ras.head(28, 17, look: 0)
            face.eyes = blink ? .closed : .open
            face.mouthOpen = true
        }
        return (ras, face)
    }

    func spriteImage() -> CGImage? {
        let (ras, face) = buildPose()
        var px = shade(ras)
        drawFace(face, on: &px, raster: ras)
        // addRim(&px)  // light rim for dark wallpapers — off
        return makeImage(px, mirrored: !facingRight)
    }

    // MARK: Drawing

    func drawSprite(_ sprite: [String], at origin: NSPoint, scale s: CGFloat, alpha: CGFloat) {
        for (r, row) in sprite.enumerated() {
            for (c, ch) in row.enumerated() {
                guard let col = spriteColors[ch] else { continue }
                col.withAlphaComponent(alpha).setFill()
                NSRect(x: origin.x + CGFloat(c) * s,
                       y: origin.y + CGFloat(sprite.count - 1 - r) * s, width: s, height: s).fill()
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill(using: .copy)
        guard let gc = NSGraphicsContext.current else { return }
        gc.shouldAntialias = false
        gc.imageInterpolation = .none
        gc.cgContext.interpolationQuality = .none

        let purr: CGFloat = state == .petted && Int(t * 12) % 2 == 0 ? 1 : 0
        let ox = anchor.x - CGFloat(GW) / 2 * S
        let oy = anchor.y - CGFloat(GH - 1 - FEET_ROW) * S + purr
        if let img = spriteImage() {
            gc.cgContext.draw(img, in: CGRect(x: ox, y: oy, width: CGFloat(GW) * S, height: CGFloat(GH) * S))
        }

        if state == .sleeping {
            let dir: CGFloat = facingRight ? 1 : -1
            let hx = facingRight ? ox + 20 * S : ox + CGFloat(GW - 20) * S
            for i in 0..<3 {
                let p = (t * 0.45 + CGFloat(i) / 3).truncatingRemainder(dividingBy: 1)
                let s: CGFloat = p < 0.5 ? 2 : 3
                drawSprite(zSprite, at: P((hx - 2 + dir * p * 16).rounded(), (anchor.y + 46 + p * 40).rounded()),
                           scale: s, alpha: sin(p * .pi))
            }
        }
        for h in hearts {
            drawSprite(heartSprite, at: P(h.x.rounded(), h.y.rounded()), scale: 2,
                       alpha: max(0, 1 - h.age / 1.6))
        }
    }
}

// MARK: - App

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: NSPanel!
    var cat: CatView!
    var statusItem: NSStatusItem!
    var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        cat = CatView(frame: NSRect(origin: .zero, size: CatView.size))
        cat.menuBuilder = { [weak self] menu in self?.populate(menu) }

        panel = NSPanel(contentRect: cat.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let onTop = UserDefaults.standard.object(forKey: "onTop") as? Bool ?? true
        panel.level = onTop ? .floating : .normal
        panel.contentView = cat

        // Drop in from above.
        let f = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
        cat.x = f.midX
        cat.y = f.minY + 300
        cat.enter(.falling)
        panel.orderFrontRegardless()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐈"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let timer = Timer(timeInterval: 1.0 / 60, target: cat!, selector: #selector(CatView.tick),
                          userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(item("Pet the Cat", #selector(pet)))
        menu.addItem(item("Come Here!", #selector(comeHere)))
        menu.addItem(item("Nap Time", #selector(nap)))
        menu.addItem(item("Climb Stairs", #selector(climbStairs)))
        menu.addItem(item("Jump Up", #selector(jumpUp)))
        menu.addItem(item("Play with Yarn", #selector(playYarn)))
        menu.addItem(.separator())
        let top = item("Always on Top", #selector(toggleOnTop))
        top.state = panel.level == .floating ? .on : .off
        menu.addItem(top)
        menu.addItem(.separator())
        menu.addItem(item("Quit DeskCat", #selector(quit)))
    }

    @objc func pet() { cat.pet() }
    @objc func comeHere() { cat.enter(.chasing, 10) }
    @objc func nap() { cat.enter(.sleeping) }
    @objc func climbStairs() { cat.climbStairs() }
    @objc func jumpUp() { cat.jumpToFloatingLedge() }
    @objc func playYarn() { cat.startPlay() }
    @objc func toggleOnTop() {
        let onTop = panel.level != .floating
        panel.level = onTop ? .floating : .normal
        UserDefaults.standard.set(onTop, forKey: "onTop")
    }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Snapshot (for checking the sprites without launching)

@MainActor func renderSnapshot(to path: String, zoom: CGFloat = 1, only: [CatState]? = nil) {
    var poses: [(CatState, CGFloat)] = [(.walking, 0), (.walking, 1), (.chasing, 0), (.chasing, 0.5),
                                        (.chasing, 1), (.chasing, 1.5), (.chasing, 2), (.chasing, 2.5),
                                        (.chasing, 3), (.chasing, 3.5), (.sitting, 0),
                                        (.petted, 0), (.sleeping, 0), (.held, 2), (.held, 0), (.held, 1), (.held, 3), (.held, 4),
                                        (.falling, 0), (.falling, 1), (.falling, 2), (.falling, 3),
                                        (.swatting, 0), (.swatting, 1), (.swatting, 2), (.swatting, 3),
                                        (.climbing, 0), (.climbing, 1), (.climbing, 2), (.climbing, 3), (.climbing, 4)]
    if let only { poses = poses.filter { only.contains($0.0) } }
    let base = CatView.size
    let cell = NSSize(width: base.width * zoom, height: base.height * zoom)
    let backgrounds = [NSColor(white: 0.92, alpha: 1), NSColor(srgbRed: 0.12, green: 0.14, blue: 0.22, alpha: 1)]
    let img = NSImage(size: NSSize(width: cell.width * CGFloat(poses.count),
                                   height: cell.height * CGFloat(backgrounds.count)))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .none
    for (r, bg) in backgrounds.enumerated() {
        bg.setFill()
        NSRect(x: 0, y: CGFloat(r) * cell.height, width: img.size.width, height: cell.height).fill()
        for (c, pose) in poses.enumerated() {
            let v = CatView(frame: NSRect(origin: .zero, size: base))
            v.state = pose.0
            v.walkPhase = pose.1
            v.t = 0.2
            v.stateTime = pose.0 == .swatting ? CatView.swatDuration * (1 - (pose.1 + 0.5) / 8) : 0.3
            if pose.0 == .petted {
                for i in 0..<3 {
                    v.hearts.append(Heart(x: 44 + CGFloat(i) * 18, y: 88 + CGFloat(i) * 16,
                                          age: CGFloat(i) * 0.3, vx: 0))
                }
            }
            if pose.0 == .sleeping { v.t = 0.6 }
            if pose.0 == .held { v.swing = [-0.6, -0.3, 0, 0.3, 0.6][min(Int(pose.1), 4)] }
            if pose.0 == .falling { v.airTime = 1; v.vy = [500, 0, -400, -900][min(Int(pose.1), 3)] }
            if pose.0 == .climbing {
                let perch = Ledge(x0: 0, x1: 100, y: 84, isFloor: false, isTemp: true)
                v.stair = (sx: 0, sy: 0, dir: 1, n: 5, perch: perch)
                let d = CGFloat([56, 63, 70, 77, 84][min(Int(pose.1), 4)])
                v.x = d
                v.walkPhase = pose.1 * 0.5
                v.y = 0
                for _ in 0..<40 { v.applyClimb(d: d) }
            }
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            rep.draw(in: NSRect(x: CGFloat(c) * cell.width, y: CGFloat(r) * cell.height,
                                width: cell.width, height: cell.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
    }
    img.unlockFocus()
    if let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

/// Rows of the same poses at different head sizes, for comparing.
@MainActor func renderHeadCompare(to path: String, scales: [Float]) {
    let poses: [(CatState, CGFloat)] = [(.sitting, 0), (.walking, 0), (.petted, 0), (.sleeping, 0)]
    let zoom: CGFloat = 2
    let base = CatView.size
    let cell = NSSize(width: base.width * zoom, height: base.height * zoom)
    let img = NSImage(size: NSSize(width: cell.width * CGFloat(poses.count), height: cell.height * CGFloat(scales.count)))
    img.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .none
    NSColor(white: 0.92, alpha: 1).setFill()
    NSRect(origin: .zero, size: img.size).fill()
    for (row, sc) in scales.enumerated() {
        Raster.headScale = sc
        for (c, pose) in poses.enumerated() {
            let v = CatView(frame: NSRect(origin: .zero, size: base))
            v.state = pose.0
            v.walkPhase = pose.1
            v.t = pose.0 == .sleeping ? 0.6 : 0.2
            v.stateTime = 0.3
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
            v.cacheDisplay(in: v.bounds, to: rep)
            let y = CGFloat(scales.count - 1 - row) * cell.height
            rep.draw(in: NSRect(x: CGFloat(c) * cell.width, y: y, width: cell.width, height: cell.height),
                     from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        }
    }
    Raster.headScale = 0.92
    img.unlockFocus()
    if let tiff = img.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
    }
}

@main
struct DeskCatApp {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--trace") {
            CatView.trace = true
            if i + 1 < args.count { CatView.traceAction = args[i + 1] }
        }
        if let i = args.firstIndex(of: "--compare-head"), i + 1 < args.count {
            renderHeadCompare(to: args[i + 1], scales: [1.0, 0.92, 0.85])
            return
        }
        if args.contains("--ledges") {
            _ = NSApplication.shared
            for l in scanLedges() {
                print(l.isFloor ? "floor " : "window", "y=\(Int(l.y))", "x=\(Int(l.x0))...\(Int(l.x1))")
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            if args.contains("--zoom") {
                renderSnapshot(to: args[i + 1], zoom: 4, only: [.sitting, .petted])
            } else {
                renderSnapshot(to: args[i + 1])
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
