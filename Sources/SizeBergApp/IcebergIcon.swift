import AppKit

/// The menu bar icon: an iceberg with twin peaks, split by the water. It is an outline while the disk has
/// room, solid when space gets tight, and solid red when the disk is almost full. Outline and solid are
/// template images, so macOS tints them for light and dark menu bars.
enum IcebergIcon {
    enum State {
        case roomy, tight, almostFull
    }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let color = state == .almostFull ? NSColor.systemRed : NSColor.black
            color.set()
            for shape in [polygon(peaks), polygon(body)] {
                shape.lineWidth = 1
                shape.lineJoinStyle = .round
                shape.stroke()
                if state != .roomy {
                    shape.fill()
                }
            }
            return true
        }
        image.isTemplate = state != .almostFull
        return image
    }

    private static let peaks = [
        NSPoint(x: 1.8, y: 8), NSPoint(x: 4.8, y: 13), NSPoint(x: 6.6, y: 11), NSPoint(x: 10.2, y: 17),
        NSPoint(x: 13.4, y: 11.4), NSPoint(x: 16.2, y: 8),
    ]
    private static let body = [
        NSPoint(x: 4.2, y: 6), NSPoint(x: 13.8, y: 6), NSPoint(x: 11.6, y: 3), NSPoint(x: 9, y: 1), NSPoint(x: 6.4, y: 2.8),
    ]

    private static func polygon(_ points: [NSPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        points.dropFirst().forEach(path.line(to:))
        path.close()
        return path
    }
}
