import AppKit

/// The menu bar icon: the app icon's iceberg as a small line drawing. It fills from the bottom as the
/// disk fills up, and turns red when the disk is almost full. Otherwise it is a template image, so
/// macOS tints it for light and dark menu bars.
enum IcebergIcon {
    static let size = NSSize(width: 18, height: 18)
    private static let bottom: CGFloat = 1
    private static let top: CGFloat = 17
    private static let waterline: CGFloat = 11

    static func image(usedShare: Double, isLow: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            let color = isLow ? NSColor.systemRed : NSColor.black
            let outline = silhouette()
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            color.setFill()
            let level = (top - bottom) * CGFloat(min(max(usedShare, 0), 1))
            NSRect(x: 0, y: 0, width: size.width, height: bottom + level).fill()
            NSGraphicsContext.restoreGraphicsState()
            color.setStroke()
            outline.lineWidth = 1
            outline.lineJoinStyle = .round
            outline.stroke()
            let water = NSBezierPath()
            water.move(to: NSPoint(x: 0.5, y: waterline))
            water.line(to: NSPoint(x: 17.5, y: waterline))
            water.lineWidth = 1
            water.lineCapStyle = .round
            water.stroke()
            return true
        }
        image.isTemplate = !isLow
        return image
    }

    /// A small peak above the waterline and a wider, jagged body below it, as on the app icon.
    private static func silhouette() -> NSBezierPath {
        let path = NSBezierPath()
        add([
            NSPoint(x: 5.6, y: waterline), NSPoint(x: 7.4, y: 13.6), NSPoint(x: 9.2, y: top),
            NSPoint(x: 10.6, y: 14.4), NSPoint(x: 12.6, y: waterline),
        ], to: path)
        add([
            NSPoint(x: 2.4, y: waterline), NSPoint(x: 15.6, y: waterline), NSPoint(x: 14.2, y: 7.4), NSPoint(x: 12.2, y: 6.2),
            NSPoint(x: 10.8, y: 2.8), NSPoint(x: 9, y: bottom), NSPoint(x: 7.2, y: 3.6), NSPoint(x: 5.2, y: 5), NSPoint(x: 3.8, y: 7.8),
        ], to: path)
        return path
    }

    private static func add(_ points: [NSPoint], to path: NSBezierPath) {
        path.move(to: points[0])
        points.dropFirst().forEach(path.line(to:))
        path.close()
    }
}
