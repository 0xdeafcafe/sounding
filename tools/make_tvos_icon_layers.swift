import Foundation
import Vision
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Plane {
  let w: Int
  let h: Int
  var v: [Float]
  init(_ w: Int, _ h: Int, _ fill: Float = 0) { self.w = w; self.h = h; v = [Float](repeating: fill, count: w * h) }
  subscript(x: Int, y: Int) -> Float {
    get { v[y * w + x] }
    set { v[y * w + x] = newValue }
  }
  func sample(_ x: Float, _ y: Float) -> Float {
    let xf = min(max(x, 0), Float(w - 1)), yf = min(max(y, 0), Float(h - 1))
    let x0 = Int(xf), y0 = Int(yf), x1 = min(x0 + 1, w - 1), y1 = min(y0 + 1, h - 1)
    let fx = xf - Float(x0), fy = yf - Float(y0)
    let a = self[x0, y0] * (1 - fx) + self[x1, y0] * fx
    let b = self[x0, y1] * (1 - fx) + self[x1, y1] * fx
    return a * (1 - fy) + b * fy
  }
}

typealias RGB = [Plane]

func loadRGB(_ path: String) -> RGB {
  let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)!
  let w = cg.width, h = cg.height
  var buf = [UInt8](repeating: 0, count: w * h * 4)
  let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  var out = [Plane(w, h), Plane(w, h), Plane(w, h)]
  for i in 0..<(w * h) {
    for c in 0..<3 { out[c].v[i] = Float(buf[i * 4 + c]) / 255 }
  }
  return out
}

func cgImage(_ rgb: RGB, alpha: Plane?) -> CGImage {
  let w = rgb[0].w, h = rgb[0].h
  var buf = [UInt8](repeating: 255, count: w * h * 4)
  for i in 0..<(w * h) {
    let a = alpha?.v[i] ?? 1
    for c in 0..<3 { buf[i * 4 + c] = UInt8(max(0, min(255, (rgb[c].v[i] * a * 255).rounded()))) }
    buf[i * 4 + 3] = UInt8(max(0, min(255, (a * 255).rounded())))
  }
  let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
  return ctx.makeImage()!
}

func resized(_ image: CGImage, _ w: Int, _ h: Int, opaque: Bool) -> CGImage {
  let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
  ctx.interpolationQuality = .high
  ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
  return ctx.makeImage()!
}

func writePNG(_ image: CGImage, _ path: String) {
  try? FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
  CGImageDestinationAddImage(dest, image, nil)
  CGImageDestinationFinalize(dest)
}

func gaussian(_ p: Plane, _ sigma: Float) -> Plane {
  if sigma <= 0 { return p }
  let r = Int((sigma * 3).rounded(.up))
  var k = (-r...r).map { exp(-Float($0 * $0) / (2 * sigma * sigma)) }
  let s = k.reduce(0, +)
  k = k.map { $0 / s }
  var tmp = Plane(p.w, p.h), out = Plane(p.w, p.h)
  for y in 0..<p.h {
    for x in 0..<p.w {
      var acc: Float = 0
      for i in -r...r { acc += p[min(max(x + i, 0), p.w - 1), y] * k[i + r] }
      tmp[x, y] = acc
    }
  }
  for y in 0..<p.h {
    for x in 0..<p.w {
      var acc: Float = 0
      for i in -r...r { acc += tmp[x, min(max(y + i, 0), p.h - 1)] * k[i + r] }
      out[x, y] = acc
    }
  }
  return out
}

func normalizedBlur(_ p: Plane, weight: Plane, _ sigma: Float) -> Plane {
  var num = Plane(p.w, p.h)
  for i in 0..<p.v.count { num.v[i] = p.v[i] * weight.v[i] }
  let n = gaussian(num, sigma), d = gaussian(weight, sigma)
  var out = Plane(p.w, p.h)
  for i in 0..<p.v.count { out.v[i] = d.v[i] > 1e-4 ? n.v[i] / d.v[i] : 0 }
  return out
}

func distanceTransform(_ site: [Bool], _ w: Int, _ h: Int) -> (d2: [Float], nearest: [Int]) {
  let inf: Float = 1e12
  var colD = [Float](repeating: inf, count: w * h)
  var colRow = [Int](repeating: -1, count: w * h)
  for x in 0..<w {
    var last = -1
    for y in 0..<h {
      if site[y * w + x] { last = y }
      if last >= 0 { colD[y * w + x] = Float(y - last); colRow[y * w + x] = last }
    }
    last = -1
    for y in stride(from: h - 1, through: 0, by: -1) {
      if site[y * w + x] { last = y }
      if last >= 0, Float(last - y) < colD[y * w + x] { colD[y * w + x] = Float(last - y); colRow[y * w + x] = last }
    }
  }
  var d2 = [Float](repeating: inf, count: w * h)
  var nearest = [Int](repeating: -1, count: w * h)
  var v = [Int](repeating: 0, count: w)
  var z = [Float](repeating: 0, count: w + 1)
  var f = [Float](repeating: 0, count: w)
  for y in 0..<h {
    for x in 0..<w { let c = colD[y * w + x]; f[x] = c >= inf ? inf : c * c }
    var k = 0
    v[0] = 0; z[0] = -inf; z[1] = inf
    if w > 1 {
      for q in 1..<w {
        var s: Float
        repeat {
          let p = v[k]
          s = ((f[q] + Float(q * q)) - (f[p] + Float(p * p))) / Float(2 * q - 2 * p)
          if s <= z[k] { k -= 1 } else { break }
        } while k >= 0
        k += 1
        v[k] = q; z[k] = s; z[k + 1] = inf
      }
    }
    k = 0
    for q in 0..<w {
      while z[k + 1] < Float(q) { k += 1 }
      let p = v[k]
      let dd = Float((q - p) * (q - p)) + f[p]
      d2[y * w + q] = dd
      let row = colRow[y * w + p]
      nearest[y * w + q] = row >= 0 ? row * w + p : -1
    }
  }
  return (d2, nearest)
}

func dilate(_ m: [Bool], _ w: Int, _ h: Int, _ r: Float) -> [Bool] {
  let d = distanceTransform(m, w, h).d2
  return d.map { $0 <= r * r }
}

func erode(_ m: [Bool], _ w: Int, _ h: Int, _ r: Float) -> [Bool] {
  dilate(m.map { !$0 }, w, h, r).map { !$0 }
}

func pushPull(_ p: Plane, known: [Bool]) -> Plane {
  var levels: [(Plane, Plane)] = []
  var c = p, wt = Plane(p.w, p.h)
  for i in 0..<p.v.count { wt.v[i] = known[i] ? 1 : 0; c.v[i] *= wt.v[i] }
  levels.append((c, wt))
  while c.w > 1 || c.h > 1 {
    let nw = max(1, (c.w + 1) / 2), nh = max(1, (c.h + 1) / 2)
    var nc = Plane(nw, nh), nwt = Plane(nw, nh)
    for y in 0..<nh {
      for x in 0..<nw {
        var sc: Float = 0, sw: Float = 0
        for dy in 0..<2 { for dx in 0..<2 {
          let sx = 2 * x + dx, sy = 2 * y + dy
          if sx < c.w, sy < c.h { sc += c[sx, sy]; sw += wt[sx, sy] }
        } }
        nc[x, y] = sc; nwt[x, y] = sw
      }
    }
    for i in 0..<nc.v.count where nwt.v[i] > 1 { nc.v[i] /= nwt.v[i]; nwt.v[i] = 1 }
    levels.append((nc, nwt))
    c = nc; wt = nwt
  }
  var filled = levels.last!.0
  for i in 0..<filled.v.count where levels.last!.1.v[i] > 0 { filled.v[i] /= levels.last!.1.v[i] }
  for li in stride(from: levels.count - 2, through: 0, by: -1) {
    let (lc, lw) = levels[li]
    var out = Plane(lc.w, lc.h)
    for y in 0..<lc.h {
      for x in 0..<lc.w {
        let up = filled.sample((Float(x) + 0.5) / 2 - 0.5, (Float(y) + 0.5) / 2 - 0.5)
        let wv = min(lw[x, y], 1)
        let own = lw[x, y] > 0 ? lc[x, y] / lw[x, y] : 0
        out[x, y] = own * wv + up * (1 - wv)
      }
    }
    filled = out
  }
  return filled
}

func luminance(_ r: Float, _ g: Float, _ b: Float) -> Float { 0.2126 * r + 0.7152 * g + 0.0722 * b }

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
  let t = min(max((x - a) / (b - a), 0), 1)
  return t * t * (3 - 2 * t)
}

let args = CommandLine.arguments
let repo = args.count > 1 ? args[1] : FileManager.default.currentDirectoryPath
let preview = args.count > 2 ? args[2] : NSTemporaryDirectory() + "tvicon-photo"
let masterPath = repo + "/Branding/Sounding-tvOS-AppTile-Master.png"
let stack = repo + "/SoundingTV-tvOS/Assets.xcassets/App Icon & Top Shelf Image.brandassets"

let img = loadRGB(masterPath)
let W = img[0].w, H = img[0].h
var lum = Plane(W, H)
for i in 0..<(W * H) { lum.v[i] = luminance(img[0].v[i], img[1].v[i], img[2].v[i]) }

let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: masterPath) as CFURL, nil)!
let master = CGImageSourceCreateImageAtIndex(source, 0, nil)!
let request = VNGenerateForegroundInstanceMaskRequest()
let handler = VNImageRequestHandler(cgImage: master)
try handler.perform([request])
guard let observation = request.results?.first else { fatalError("Vision found no subject") }
let maskBuffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
CVPixelBufferLockBaseAddress(maskBuffer, .readOnly)
var vision = Plane(W, H)
do {
  let base = CVPixelBufferGetBaseAddress(maskBuffer)!
  let stride = CVPixelBufferGetBytesPerRow(maskBuffer)
  let mw = CVPixelBufferGetWidth(maskBuffer), mh = CVPixelBufferGetHeight(maskBuffer)
  precondition(mw == W && mh == H)
  for y in 0..<H {
    let row = base.advanced(by: y * stride).assumingMemoryBound(to: Float32.self)
    for x in 0..<W { vision[x, y] = row[x] }
  }
}
CVPixelBufferUnlockBaseAddress(maskBuffer, .readOnly)

let socketCX: Float = 1487, socketCY: Float = 470, socketA: Float = 119, socketB: Float = 126
let socketZone: Float = 1.14
let tipFromX = 1330

func socketRho(_ x: Float, _ y: Float) -> Float {
  let dx = (x - socketCX) / socketA, dy = (y - socketCY) / socketB
  return (dx * dx + dy * dy).squareRoot()
}

func rasterise(_ build: (CGMutablePath) -> Void) -> Plane {
  let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
  ctx.translateBy(x: 0, y: CGFloat(H))
  ctx.scaleBy(x: 1, y: -1)
  ctx.setShouldAntialias(true)
  let path = CGMutablePath()
  build(path)
  ctx.setFillColor(gray: 1, alpha: 1)
  ctx.addPath(path)
  ctx.fillPath()
  let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
  var out = Plane(W, H)
  for y in 0..<H { for x in 0..<W { out[x, y] = Float(data[y * W + x]) / 255 } }
  return out
}

let tipPath = rasterise { p in
  p.move(to: CGPoint(x: 1300, y: 507))
  p.addLine(to: CGPoint(x: 1330, y: 494))
  p.addLine(to: CGPoint(x: 1356, y: 486))
  p.addLine(to: CGPoint(x: 1368, y: 482.5))
  p.addLine(to: CGPoint(x: 1470, y: 439.5))
  p.addCurve(to: CGPoint(x: 1527, y: 483), control1: CGPoint(x: 1495, y: 429), control2: CGPoint(x: 1527, y: 452))
  p.addCurve(to: CGPoint(x: 1490, y: 529), control1: CGPoint(x: 1527, y: 505), control2: CGPoint(x: 1506, y: 523))
  p.addLine(to: CGPoint(x: 1450, y: 550))
  p.addLine(to: CGPoint(x: 1420, y: 562))
  p.addLine(to: CGPoint(x: 1380, y: 590))
  p.addLine(to: CGPoint(x: 1340, y: 612))
  p.addLine(to: CGPoint(x: 1300, y: 619))
  p.closeSubpath()
}

let smoothLum = gaussian(lum, 1)
var plugTop = [Int](repeating: -1, count: W)
var plugBottom = [Int](repeating: -1, count: W)
for x in 0..<tipFromX {
  guard let top = (0..<H).first(where: { vision[x, $0] > 0.5 && lum[x, $0] > 0.16 }) else { continue }
  plugTop[x] = top
  var y = top, dark = 0
  while y < H - 1 {
    y += 1
    dark = smoothLum[x, y] < 0.04 ? dark + 1 : 0
    if dark == 3 { y -= 3; break }
  }
  plugBottom[x] = y
}
let shaftFromX = 560
var bottomPts = (shaftFromX..<tipFromX).filter { plugBottom[$0] >= 0 }.map { (Float($0), Float(plugBottom[$0])) }
var bottomLine = (m: Float(0), c: Float(0))
for iteration in 0..<8 {
  let n = Float(bottomPts.count)
  let sx = bottomPts.reduce(0) { $0 + $1.0 }, sy = bottomPts.reduce(0) { $0 + $1.1 }
  let sxx = bottomPts.reduce(0) { $0 + $1.0 * $1.0 }, sxy = bottomPts.reduce(0) { $0 + $1.0 * $1.1 }
  let m = (n * sxy - sx * sy) / (n * sxx - sx * sx)
  bottomLine = (m, (sy - m * sx) / n)
  bottomPts = bottomPts.filter { abs($0.1 - (bottomLine.m * $0.0 + bottomLine.c)) <= max(4, 30 - Float(iteration) * 6) }
}
print("shaft underside y = \(bottomLine.m)x + \(bottomLine.c), \(bottomPts.count) columns")
var smoothBottom = plugBottom
let collarFromX = 1303
for x in shaftFromX..<collarFromX where plugBottom[x] >= 0 {
  smoothBottom[x] = min(H - 1, Int((bottomLine.m * Float(x) + bottomLine.c).rounded()))
}
for x in collarFromX..<tipFromX {
  let window = (max(collarFromX, x - 4)...min(tipFromX - 1, x + 4)).map { plugBottom[$0] }.sorted()
  smoothBottom[x] = window[window.count / 2]
}

var frontHard = [Bool](repeating: false, count: W * H)
var frontPrior = Plane(W, H)
for y in 0..<H {
  for x in 0..<W {
    let i = y * W + x
    if x >= tipFromX {
      frontPrior.v[i] = tipPath[x, y]
    } else {
      if smoothBottom[x] < 0 {
        frontPrior.v[i] = vision[x, y]
      } else if y > smoothBottom[x] {
        frontPrior.v[i] = 0
      } else if y >= plugTop[x] {
        frontPrior.v[i] = 1
      } else {
        frontPrior.v[i] = vision[x, y]
      }
    }
    frontHard[i] = frontPrior.v[i] > 0.5
  }
}

let wordBox = (x0: 180, y0: 185, x1: 730, y1: 295)
var wordBg = Plane(W, H)
do {
  var outside = [Bool](repeating: true, count: W * H)
  for y in wordBox.y0..<wordBox.y1 { for x in wordBox.x0..<wordBox.x1 { outside[y * W + x] = false } }
  wordBg = pushPull(lum, known: outside)
}
var wordHard = [Bool](repeating: false, count: W * H)
for y in wordBox.y0..<wordBox.y1 {
  for x in wordBox.x0..<wordBox.x1 where lum[x, y] - wordBg[x, y] > 0.16 { wordHard[y * W + x] = true }
}
do {
  var seen = [Bool](repeating: false, count: W * H)
  for start in 0..<(W * H) where wordHard[start] && !seen[start] {
    var stack = [start], component: [Int] = []
    seen[start] = true
    while let i = stack.popLast() {
      component.append(i)
      let x = i % W, y = i / W
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, ny >= 0, nx < W, ny < H else { continue }
        let j = ny * W + nx
        if wordHard[j] && !seen[j] { seen[j] = true; stack.append(j) }
      }
    }
    if component.count < 60 { for i in component { wordHard[i] = false } }
  }
}

let frontHole = dilate(frontHard, W, H, 7)
let wordZone = dilate(wordHard, W, H, 15)
var hole = [Bool](repeating: false, count: W * H)
for i in 0..<(W * H) { hole[i] = frontHole[i] || wordZone[i] }
let known = hole.map { !$0 }

var weight = Plane(W, H)
for i in 0..<(W * H) { weight.v[i] = known[i] ? 1 : 0 }
var back: RGB = img
let textureSigma: Float = 5
let perpX: Float = 0.42, perpY: Float = 0.91
let offsets: [Float] = [-230, -300, -380, 230, 300, 380, -460, 460]
let holeDist = distanceTransform(known, W, H).d2

for c in 0..<3 {
  let low = normalizedBlur(img[c], weight: weight, textureSigma)
  var detail = Plane(W, H)
  for i in 0..<(W * H) { detail.v[i] = img[c].v[i] - low.v[i] }
  let filledLow = gaussian(pushPull(low, known: known), 3)
  for y in 0..<H {
    for x in 0..<W where hole[y * W + x] {
      var t: Float = 0
      for o in offsets {
        let sx = Int((Float(x) + perpX * o).rounded()), sy = Int((Float(y) + perpY * o).rounded())
        if sx >= 0, sy >= 0, sx < W, sy < H, known[sy * W + sx], socketRho(Float(sx), Float(sy)) > 1.3 {
          t = detail[sx, sy]; break
        }
      }
      let edge = min(holeDist[y * W + x].squareRoot() / 3, 1)
      let lowValue = low[x, y] * (1 - edge) + filledLow[x, y] * edge
      back[c][x, y] = lowValue + t
    }
  }
}

do {
  var holeMean: [Float] = [0, 0, 0]
  var holeCount: Float = 0
  for y in 0..<H {
    for x in 0..<W where known[y * W + x] && socketRho(Float(x), Float(y)) < 0.5 {
      for c in 0..<3 { holeMean[c] += img[c][x, y] }
      holeCount += 1
    }
  }
  holeMean = holeMean.map { $0 / max(holeCount, 1) }
  let steps = 720
  for y in 0..<H {
    for x in 0..<W where hole[y * W + x] {
      let fx = Float(x), fy = Float(y)
      let rho = socketRho(fx, fy)
      if rho > socketZone + 0.12 { continue }
      let theta = atan2((fy - socketCY) / socketB, (fx - socketCX) / socketA)
      func probe(_ dir: Float) -> (Int, [Float])? {
        for s in 1...steps / 2 {
          let t = theta + dir * Float(s) * 2 * .pi / Float(steps)
          let sx = socketCX + rho * socketA * cos(t), sy = socketCY + rho * socketB * sin(t)
          let ix = Int(sx.rounded()), iy = Int(sy.rounded())
          if ix < 0 || iy < 0 || ix >= W || iy >= H { return nil }
          if known[iy * W + ix] {
            let t2 = t + dir * 3 * 2 * .pi / Float(steps)
            let qx = socketCX + rho * socketA * cos(t2), qy = socketCY + rho * socketB * sin(t2)
            return (s, (0..<3).map { img[$0].sample(qx, qy) })
          }
        }
        return nil
      }
      let a = probe(-1), b = probe(1)
      var col: [Float]
      switch (a, b) {
      case let (.some(pa), .some(pb)):
        let wa = Float(pb.0) / Float(pa.0 + pb.0)
        col = (0..<3).map { pa.1[$0] * wa + pb.1[$0] * (1 - wa) }
      case let (.some(pa), nil): col = pa.1
      case let (nil, .some(pb)): col = pb.1
      default: col = holeMean
      }
      let blend = 1 - smoothstep(socketZone, socketZone + 0.12, rho)
      for c in 0..<3 { back[c][x, y] = col[c] * blend + back[c][x, y] * (1 - blend) }
    }
  }
}

func matte(hard: [Bool], fallback: Plane?, grow: Float, shrink: Float, feather: Float) -> (alpha: Plane, colour: RGB) {
  let inner = erode(hard, W, H, shrink)
  let outer = dilate(hard, W, H, grow)
  let near = distanceTransform(inner, W, H).nearest
  var alpha = Plane(W, H)
  var fg: RGB = [Plane(W, H), Plane(W, H), Plane(W, H)]
  for i in 0..<(W * H) {
    if inner[i] {
      alpha.v[i] = 1
      for c in 0..<3 { fg[c].v[i] = img[c].v[i] }
      continue
    }
    guard outer[i], near[i] >= 0 else { continue }
    let j = near[i]
    var num: Float = 0, den: Float = 0
    for c in 0..<3 {
      let f = img[c].v[j], b = back[c].v[i], o = img[c].v[i]
      num += (o - b) * (f - b); den += (f - b) * (f - b)
      fg[c].v[i] = f
    }
    var a = den > 0.002 ? num / den : (fallback?.v[i] ?? (hard[i] ? 1 : 0))
    if let fallback { a = min(a, fallback.v[i] * 1.25 + 0.05) }
    alpha.v[i] = min(max(a, 0), 1)
  }
  let soft = gaussian(alpha, feather)
  for i in 0..<(W * H) {
    let a = inner[i] ? 1 : soft.v[i]
    alpha.v[i] = a < 0.01 ? 0 : a
    if !inner[i], a > 0.04 {
      for c in 0..<3 {
        let dec = (img[c].v[i] - (1 - a) * back[c].v[i]) / a
        let ref = fg[c].v[i]
        let mix = smoothstep(0.04, 0.5, a)
        fg[c].v[i] = min(max(dec * mix + ref * (1 - mix), 0), 1)
      }
    }
  }
  return (alpha, fg)
}

let front = matte(hard: frontHard, fallback: frontPrior, grow: 4, shrink: 3, feather: 0.9)

let distanceToZoneEdge: [Float] = {
  let d = distanceTransform(wordHard, W, H).d2
  return d.map { min($0.squareRoot() / 15, 1) }
}()

func wordMatte() -> (alpha: Plane, colour: RGB) {
  let core = erode(wordHard, W, H, 1)
  let edge = dilate(wordHard, W, H, 3)
  let near = distanceTransform(core, W, H).nearest
  var letters = Plane(W, H), shade = Plane(W, H)
  var backLum = Plane(W, H), open = Plane(W, H)
  for i in 0..<(W * H) {
    backLum.v[i] = luminance(back[0].v[i], back[1].v[i], back[2].v[i])
    open.v[i] = edge[i] ? 0 : 1
  }
  let blurredLum = normalizedBlur(lum, weight: open, 2.5), blurredBack = gaussian(backLum, 2.5)
  for i in 0..<(W * H) where wordZone[i] {
    if core[i] { letters.v[i] = 1; continue }
    let darkening = 1 - blurredLum.v[i] / max(blurredBack.v[i], 0.001)
    shade.v[i] = min(max((darkening - 0.12) / 0.88, 0), 0.95)
    if edge[i], near[i] >= 0, lum.v[i] >= backLum.v[i] {
      let j = near[i]
      var num: Float = 0, den: Float = 0
      for c in 0..<3 {
        let f = img[c].v[j], b = back[c].v[i], o = img[c].v[i]
        num += (o - b) * (f - b); den += (f - b) * (f - b)
      }
      letters.v[i] = den > 0.002 ? min(max(num / den, 0), 1) : 0
    }
  }
  let softShade = gaussian(shade, 1)
  let softLetters = gaussian(letters, 0.6)
  var alpha = Plane(W, H)
  var fg: RGB = [Plane(W, H), Plane(W, H), Plane(W, H)]
  for i in 0..<(W * H) where wordZone[i] {
    let l = core[i] ? 1 : softLetters.v[i]
    let a = min(l + (1 - l) * softShade.v[i] * (1 - smoothstep(0.85, 1, Float(distanceToZoneEdge[i]))), 1)
    guard a > 0.01 else { continue }
    alpha.v[i] = a
    let j = near[i] >= 0 ? near[i] : i
    for c in 0..<3 {
      let dec = (img[c].v[i] - (1 - a) * back[c].v[i]) / a
      let ref = img[c].v[j] * l / max(a, 0.001)
      let mix = smoothstep(0.04, 0.4, a)
      fg[c].v[i] = min(max(dec * mix + ref * (1 - mix), 0), 1)
    }
  }
  return (alpha, fg)
}
let word = wordMatte()

let backCG = cgImage(back, alpha: nil)
let middleCG = cgImage(word.colour, alpha: word.alpha)
let frontCG = cgImage(front.colour, alpha: front.alpha)

let targets: [(String, Int, Int)] = [
  ("App Icon.imagestack", 400, 240),
  ("App Icon.imagestack", 800, 480),
  ("App Icon - App Store.imagestack", 1280, 768),
]
for (name, w, h) in targets {
  let file = name.hasPrefix("App Icon - App Store") ? "image.png" : (w == 800 ? "image@2x.png" : "image.png")
  writePNG(resized(backCG, w, h, opaque: true), "\(stack)/\(name)/Back.imagestacklayer/Content.imageset/\(file)")
  writePNG(resized(middleCG, w, h, opaque: false), "\(stack)/\(name)/Middle.imagestacklayer/Content.imageset/\(file)")
  writePNG(resized(frontCG, w, h, opaque: false), "\(stack)/\(name)/Front.imagestacklayer/Content.imageset/\(file)")
}

func composite(_ layers: [(CGImage, CGFloat)], _ w: Int, _ h: Int) -> CGImage {
  let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
  ctx.interpolationQuality = .high
  for (layer, dx) in layers { ctx.draw(layer, in: CGRect(x: dx, y: 0, width: CGFloat(w), height: CGFloat(h))) }
  return ctx.makeImage()!
}

let b1280 = resized(backCG, 1280, 768, opaque: true)
let m1280 = resized(middleCG, 1280, 768, opaque: false)
let f1280 = resized(frontCG, 1280, 768, opaque: false)
writePNG(b1280, "\(preview)/back.png")
writePNG(m1280, "\(preview)/middle.png")
writePNG(f1280, "\(preview)/front.png")
writePNG(composite([(b1280, 0), (m1280, 0), (f1280, 0)], 1280, 768), "\(preview)/composite.png")
writePNG(composite([(b1280, 0), (m1280, -6), (f1280, -12)], 1280, 768), "\(preview)/parallax-left.png")
writePNG(composite([(b1280, 0), (m1280, 6), (f1280, 12)], 1280, 768), "\(preview)/parallax-right.png")
writePNG(backCG, "\(preview)/full-back.png")
writePNG(frontCG, "\(preview)/full-front.png")
writePNG(middleCG, "\(preview)/full-middle.png")
print("wrote layers to \(stack) and previews to \(preview)")
if ProcessInfo.processInfo.environment["TVICON_DEBUG"] != nil {
  var overlay = img
  for i in 0..<(W * H) {
    let a = front.alpha.v[i] * 0.45
    overlay[0].v[i] = overlay[0].v[i] * (1 - a)
    overlay[1].v[i] = overlay[1].v[i] * (1 - a) + a
    overlay[2].v[i] = overlay[2].v[i] * (1 - a) + a
  }
  writePNG(cgImage(overlay, alpha: nil), "\(preview)/debug-front-overlay.png")
}
