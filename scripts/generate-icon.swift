import AppKit

/// Build-local original artwork. No downloaded asset or image service is used.
@main struct IconGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("Usage: generate-icon OUTPUT.iconset") }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let size = points * scale
                let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
                let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
                let path = CGPath(roundedRect: tile, cornerWidth: 200, cornerHeight: 200, transform: nil)
                context.saveGState()
                context.addPath(path); context.clip()
                let colors = [CGColor(red: 0.04, green: 0.36, blue: 0.29, alpha: 1), CGColor(red: 0.12, green: 0.64, blue: 0.50, alpha: 1)] as CFArray
                let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
                context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 64), end: CGPoint(x: 512, y: 960), options: [])
                context.restoreGState()
                context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
                context.addPath(NebulaGlyph.path(in: CGRect(x: 132, y: 132, width: 760, height: 760)))
                context.setFillColor(CGColor(red: 0.97, green: 1, blue: 0.99, alpha: 1)); context.fillPath()
                guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    fatalError("Cannot render app icon")
                }
                let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                try data.write(to: directory.appendingPathComponent(name))
            }
        }
    }
}
