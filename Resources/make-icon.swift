// Build AppIcon.icns from logo.png.
// 1. Find the bounding box of the dark rounded square on the white background.
// 2. Draw it onto a transparent 1024x1024 canvas at the macOS icon size (824 pt) with a rounded-rect mask.
// 3. Write the iconset and call iconutil.
import AppKit

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-icon <logo-source.png> <AppIcon.icns> <logo.png>\n".utf8))
    exit(2)
}
let inputPath = args[1]
let outputPath = args[2]
let logoPath = args[3]

guard let source = NSImage(contentsOfFile: inputPath),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write(Data("cannot read \(inputPath)\n".utf8))
    exit(1)
}

// Read pixels to find the non-white bounding box.
let width = cg.width
let height = cg.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
let space = CGColorSpaceCreateDeviceRGB()
let info = CGImageAlphaInfo.premultipliedLast.rawValue
guard let ctx = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                          bytesPerRow: width * 4, space: space, bitmapInfo: info) else { exit(1) }
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))

var minX = width, minY = height, maxX = 0, maxY = 0
for y in 0..<height {
    for x in 0..<width {
        let i = (y * width + x) * 4
        let dark = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2]) < 3 * 200
        if dark {
            if x < minX { minX = x }
            if x > maxX { maxX = x }
            if y < minY { minY = y }
            if y > maxY { maxY = y }
        }
    }
}
// The pixel buffer has its origin at the bottom left. CGImage.cropping() counts from the top left.
// The source has a soft shadow under the square, so take a square by width, anchored at the top.
let side = maxX - minX + 1
let topY = height - 1 - maxY
let box = CGRect(x: minX, y: topY, width: side, height: side)
guard let cropped = cg.cropping(to: box) else { exit(1) }

// Render one size of the icon.
func render(_ size: Int) -> CGImage? {
    guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: size * 4, space: space, bitmapInfo: info) else { return nil }
    c.clear(CGRect(x: 0, y: 0, width: size, height: size))
    let inset = CGFloat(size) * (100.0 / 1024.0)
    let rect = CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset)
    let radius = rect.width * 0.2237
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    c.addPath(path)
    c.clip()
    c.interpolationQuality = .high
    c.draw(cropped, in: rect)
    return c.makeImage()
}

func writePNG(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try? data.write(to: URL(fileURLWithPath: path))
}

// Transparent logo for the README: the rounded square alone, no white margin.
func renderLogo() -> CGImage? {
    let w = Int(box.width), h = Int(box.height)
    guard let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: space, bitmapInfo: info) else { return nil }
    c.clear(CGRect(x: 0, y: 0, width: w, height: h))
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    let radius = rect.width * 0.2237
    c.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    c.clip()
    c.draw(cropped, in: rect)
    return c.makeImage()
}
guard let logo = renderLogo() else { exit(1) }
writePNG(logo, to: logoPath)

let tmp = NSTemporaryDirectory() + "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: tmp)
try! FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    guard let one = render(base), let two = render(base * 2) else { exit(1) }
    writePNG(one, to: "\(tmp)/icon_\(base)x\(base).png")
    writePNG(two, to: "\(tmp)/icon_\(base)x\(base)@2x.png")
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", tmp, "-o", outputPath]
try! task.run()
task.waitUntilExit()
try? FileManager.default.removeItem(atPath: tmp)
exit(task.terminationStatus)
