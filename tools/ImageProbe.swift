import AppKit
import Foundation

func load(_ path: String) -> NSBitmapImageRep {
    guard let data = FileManager.default.contents(atPath: path), let rep = NSBitmapImageRep(data: data) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        exit(1)
    }
    return rep
}

func linear(_ c: Double) -> Double {
    c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
    0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
}

func ratio(_ a: Double, _ b: Double) -> Double {
    (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

func sheet(output: String, columns: Int, cellWidth: Int, files: [String]) {
    let labelHeight = 28
    let images = files.map { load($0) }
    let cellHeights = images.map { Int(Double(cellWidth) * Double($0.pixelsHigh) / Double($0.pixelsWide)) }
    let rows = (files.count + columns - 1) / columns
    var rowHeights: [Int] = []
    for row in 0..<rows {
        let slice = cellHeights[(row * columns)..<min(files.count, (row + 1) * columns)]
        rowHeights.append((slice.max() ?? 0) + labelHeight + 8)
    }
    let width = columns * (cellWidth + 8) + 8
    let height = rowHeights.reduce(8, +)
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { exit(1) }
    context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    var y = height - 8
    for row in 0..<rows {
        let rowHeight = rowHeights[row]
        for column in 0..<columns {
            let index = row * columns + column
            guard index < files.count, let cg = images[index].cgImage else { continue }
            let x = 8 + column * (cellWidth + 8)
            let h = cellHeights[index]
            context.draw(cg, in: CGRect(x: x, y: y - labelHeight - h, width: cellWidth, height: h))
            let name = (files[index] as NSString).lastPathComponent
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            (name as NSString).draw(
                at: NSPoint(x: x, y: y - 20),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium), .foregroundColor: NSColor.white]
            )
            NSGraphicsContext.restoreGraphicsState()
        }
        y -= rowHeight
    }
    guard let image = context.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? png.write(to: URL(fileURLWithPath: output))
}

func contrast(file: String, x: Int, y: Int, w: Int, h: Int) {
    let rep = load(file)
    var samples: [(Double, Double, Double, Double)] = []
    for py in y..<min(y + h, rep.pixelsHigh) {
        for px in x..<min(x + w, rep.pixelsWide) {
            guard let c = rep.colorAt(x: px, y: py)?.usingColorSpace(.sRGB) else { continue }
            let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
            samples.append((luminance(r, g, b), r, g, b))
        }
    }
    guard !samples.isEmpty else { print("empty region"); return }
    let sorted = samples.sorted { $0.0 < $1.0 }
    let background = sorted[sorted.count / 2]
    let edgeLow = sorted[Int(Double(sorted.count) * 0.01)]
    let edgeHigh = sorted[Int(Double(sorted.count) * 0.99)]
    let text = abs(edgeLow.0 - background.0) > abs(edgeHigh.0 - background.0) ? edgeLow : edgeHigh
    func hex(_ s: (Double, Double, Double, Double)) -> String {
        String(format: "#%02X%02X%02X", Int(s.1 * 255 + 0.5), Int(s.2 * 255 + 0.5), Int(s.3 * 255 + 0.5))
    }
    print(String(format: "%@ bg=%@ text=%@ ratio=%.2f", (file as NSString).lastPathComponent, hex(background), hex(text), ratio(text.0, background.0)))
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "sheet" where args.count >= 5:
    sheet(output: args[1], columns: Int(args[2]) ?? 3, cellWidth: Int(args[3]) ?? 900, files: Array(args.dropFirst(4)))
case "contrast" where args.count == 6:
    contrast(file: args[1], x: Int(args[2]) ?? 0, y: Int(args[3]) ?? 0, w: Int(args[4]) ?? 1, h: Int(args[5]) ?? 1)
default:
    FileHandle.standardError.write(Data("usage: ImageProbe sheet <out.png> <columns> <cell-width> <files...> | contrast <file> <x> <y> <w> <h>\n".utf8))
    exit(64)
}
