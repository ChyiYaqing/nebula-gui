import AppKit
import SwiftUI

/// Original three-terminal mesh, shared by the app, sidebar and template status item.
enum NebulaGlyph {
    static func path(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: origin.x + x * side, y: origin.y + y * side)
        }
        let center = point(0.50, 0.48)
        let terminals = [point(0.20, 0.24), point(0.80, 0.24), point(0.50, 0.82)]
        let result = CGMutablePath()
        // All contours wind clockwise so overlapping arms and nodes form one solid mark.
        for terminal in terminals {
            let angle = atan2(terminal.y - center.y, terminal.x - center.x)
            let normal = CGPoint(x: -sin(angle) * side * 0.0375, y: cos(angle) * side * 0.0375)
            result.move(to: CGPoint(x: center.x + normal.x, y: center.y + normal.y))
            result.addLine(to: CGPoint(x: terminal.x + normal.x, y: terminal.y + normal.y))
            result.addLine(to: CGPoint(x: terminal.x - normal.x, y: terminal.y - normal.y))
            result.addLine(to: CGPoint(x: center.x - normal.x, y: center.y - normal.y))
            result.closeSubpath()
        }
        for node in terminals + [center] {
            let radius = side * (node == center ? 0.105 : 0.09)
            result.move(to: CGPoint(x: node.x + radius, y: node.y))
            result.addArc(center: node, radius: radius, startAngle: 0, endAngle: -.pi * 2, clockwise: true)
            result.closeSubpath()
        }
        return result
    }
    static func image(size: CGFloat, connected: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(path(in: rect.insetBy(dx: 1, dy: 1)))
            context.fillPath()
            if !connected {
                context.setBlendMode(.clear)
                context.fillEllipse(in: CGRect(x: rect.midX - 1.4, y: rect.midY - 1.8, width: 2.8, height: 2.8))
            }
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = connected ? "Nebula 隧道已启动" : "Nebula 未连接"
        return image
    }
}

struct NebulaMark: Shape {
    func path(in rect: CGRect) -> Path { Path(NebulaGlyph.path(in: rect)) }
}
