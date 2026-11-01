import AppKit
import SwiftUI

/// The app's mark, Pinhole: a disc with a hole. The hole's center lies R/φ from the disc's along 45°, up and to
/// the right, and the hole is a fifth of the radius across. Small sizes widen the hole so it stays open.
/// Fill it with `FillStyle(eoFill: true)` so the hole is cut out. See docs/design/pinhole.md.
struct Pinhole: Shape {
    /// The hole's radius as a share of the disc's.
    var holeRatio: CGFloat = 1 / 5

    /// The ratio for marks under 32 points across, where a fifth closes up.
    static let smallHoleRatio: CGFloat = 1 / 4.3

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let step = radius / 1.618 / CGFloat(2).squareRoot()
        let hole = CGPoint(x: center.x + step, y: center.y - step)
        let holeRadius = radius * holeRatio
        var path = Path()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        path.addEllipse(in: CGRect(
            x: hole.x - holeRadius, y: hole.y - holeRadius, width: holeRadius * 2, height: holeRadius * 2
        ))
        return path
    }
}

extension Color {
    /// The mark's ultramarine, as in the app icon, lighter in dark mode so it holds against dark surfaces.
    static let pinhole = Color(nsColor: NSColor(name: "Pinhole") { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x6B / 255, green: 0x7A / 255, blue: 0xE6 / 255, alpha: 1)
            : NSColor(srgbRed: 0x2A / 255, green: 0x3A / 255, blue: 0xA0 / 255, alpha: 1)
    })
}

/// Whether the menu bar shows the mark as active, which it does while the mini window is open.
final class MenuBarState: ObservableObject {
    @Published var isActive = false
}

/// The menu bar item's image: an 18-point template the system tints for light and dark menu bars. At rest it is
/// a ring with the hole as a dot; while the mini window is open it is the filled disc with the hole cut out.
enum MenuBarIcon {
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.set()
            if active {
                let disc = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15))
                disc.append(NSBezierPath(ovalIn: NSRect(x: 12.28 - 1.75, y: 5.72 - 1.75, width: 3.5, height: 3.5)))
                disc.windingRule = .evenOdd
                disc.fill()
            } else {
                let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
                ring.lineWidth = 1.5
                ring.stroke()
                NSBezierPath(ovalIn: NSRect(x: 11.76 - 1.6, y: 6.24 - 1.6, width: 3.2, height: 3.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Spot Chat"
        return image
    }
}

struct MenuBarLabel: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        Image(nsImage: MenuBarIcon.image(active: state.isActive))
    }
}
