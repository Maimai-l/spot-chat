import AppKit

/// Remembers where the user last dragged the mini window, per display.
@MainActor
final class PlacementStore {
    private let defaults: UserDefaults
    private let key = "SpotChat.miniTopLeftByScreen"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func savedTopLeft(for screen: NSScreen?) -> CGPoint? {
        guard let screen,
              let all = defaults.dictionary(forKey: key) as? [String: [Double]],
              let point = all[Self.identifier(of: screen)], point.count == 2
        else { return nil }
        return CGPoint(x: point[0], y: point[1])
    }

    func save(topLeft: CGPoint, screen: NSScreen?) {
        guard let screen else { return }
        var all = defaults.dictionary(forKey: key) as? [String: [Double]] ?? [:]
        all[Self.identifier(of: screen)] = [Double(topLeft.x), Double(topLeft.y)]
        defaults.set(all, forKey: key)
    }

    func reset() {
        defaults.removeObject(forKey: key)
    }

    private static func identifier(of screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return screen.localizedName
    }
}
