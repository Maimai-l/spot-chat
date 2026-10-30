import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleMiniWindow = Self("toggleMiniWindow", default: .init(.space, modifiers: [.option]))
    static let openFullWindow = Self("openFullWindow", default: .init(.space, modifiers: [.option, .shift]))
    /// Puts the text selected in the app in front into the mini window as a quote.
    static let askAboutSelection = Self("askAboutSelection", default: .init(.space, modifiers: [.control, .option]))
}
