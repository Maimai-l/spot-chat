import Foundation

/// Keeps the text the user has typed but not sent. It survives hiding, focus loss and relaunch,
/// and is cleared only when the message is sent.
public protocol DraftStorage: AnyObject {
    func loadDraft() -> String
    func saveDraft(_ text: String)
}

public final class UserDefaultsDraftStorage: DraftStorage {
    public static let defaultKey = "SpotChat.miniDraft"

    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = UserDefaultsDraftStorage.defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    public func loadDraft() -> String {
        defaults.string(forKey: key) ?? ""
    }

    public func saveDraft(_ text: String) {
        if text.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(text, forKey: key)
        }
    }
}
