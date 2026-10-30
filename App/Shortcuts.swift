import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleMiniWindow = Self("toggleMiniWindow", default: .init(.space, modifiers: [.option]))
    static let openFullWindow = Self("openFullWindow", default: .init(.space, modifiers: [.option, .shift]))
}
