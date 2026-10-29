import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// An open window the user can share with the model.
public struct SharableWindow: Identifiable, Equatable, Hashable, Sendable {
    /// The window server's window number.
    public let id: UInt32
    public var appName: String
    public var bundleID: String?
    public var processID: Int32
    public var title: String
    public var frame: CGRect
    public var layer: Int
    public var isOnScreen: Bool

    public init(
        id: UInt32, appName: String, bundleID: String?, processID: Int32,
        title: String, frame: CGRect, layer: Int = 0, isOnScreen: Bool = true
    ) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.processID = processID
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
    }

    /// "App › Window title", as shown in the menu and the sharing tag.
    public var label: String {
        title.isEmpty ? appName : "\(appName) › \(title)"
    }

    public static func == (lhs: SharableWindow, rhs: SharableWindow) -> Bool {
        lhs.id == rhs.id && lhs.appName == rhs.appName && lhs.title == rhs.title
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

public enum SharableWindowFilter {
    public static let minimumSize = CGSize(width: 120, height: 80)

    /// Keeps ordinary app windows that are on screen and big enough to read,
    /// leaving out Spot Chat's own windows, menus, the Dock and the like.
    public static func filter(_ windows: [SharableWindow], excludingBundleID ownBundleID: String?) -> [SharableWindow] {
        windows.filter { window in
            window.isOnScreen
                && window.layer == 0
                && window.frame.width >= minimumSize.width
                && window.frame.height >= minimumSize.height
                && !window.appName.isEmpty
                && (ownBundleID == nil || window.bundleID != ownBundleID)
        }
    }
}
