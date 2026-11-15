import AppKit
import Combine
import Logging
import SpotCore
import SwiftUI

/// What the input shows above the question, as a strip inside it at the top: the text selected in another
/// app, or that bringing it needs Accessibility access. The input grows by the strip, so the mini window stays
/// one surface (docs/design/composer-strips.html).
struct ComposerStrip<Content: View>: View {
    var opened = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: opened ? .top : .center, spacing: 8) {
            content
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, opened ? StripMetrics.verticalPadding : 0)
        .frame(minHeight: ComposerLayout.stripHeight)
        .background(RoundedRectangle(cornerRadius: 16, style: .circular).fill(Color.primary.opacity(0.05)))
        // Inset 8 from the input's edges: the input pads its rows by 12 and 11.
        .padding(.leading, -4)
        .padding(.trailing, -3)
    }
}

/// The selection: one line, or all of it once clicked, up to five lines before it scrolls.
struct SelectionStrip: View {
    let text: String
    @Binding var opened: Bool
    let remove: () -> Void

    @State private var textWidth: CGFloat = StripMetrics.textWidth

    var body: some View {
        ComposerStrip(opened: opened) {
            Image(systemName: "arrowshape.turn.up.left")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: opened ? StripMetrics.lineHeight : 16)
            Group {
                if opened {
                    ScrollView(.vertical) {
                        Text(StripMetrics.quoted(text))
                            .lineSpacing(StripMetrics.lineSpacing)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: min(StripMetrics.textHeight(of: text, width: textWidth), StripMetrics.lineHeight * StripMetrics.maxLines))
                } else {
                    Text(StripMetrics.quoted(text.replacingOccurrences(of: "\n", with: " ")))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .foregroundStyle(.secondary)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { textWidth = $0 }
            StripCloseButton(label: "Remove", identifier: "removeSelection", action: remove)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            opened.toggle()
            SpotLog.window.info("Selection strip", metadata: ["opened": "\(opened)", "characters": "\(text.count)"])
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("selectionStrip")
    }
}

/// Bringing selected text needs Accessibility access: says so, opens System Settings, and goes away by
/// itself once access is given.
struct AccessibilityStrip: View {
    @ObservedObject var composer: ComposerModel
    @ObservedObject var app: AppModel

    private let check = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    /// Off in tests, where the notice is shown on purpose and the test runner may have access.
    static var goesAwayWithAccess = true

    var body: some View {
        ComposerStrip {
            Image(systemName: "hand.raised")
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
            Text("Needs Accessibility access")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                app.noteAskedForSelectionAccess()
                SelectionReader.openAccessibilitySettings()
            } label: {
                Text("Open Settings")
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(Capsule().fill(Color.primary.opacity(0.07)))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("openAccessibilitySettings")
            StripCloseButton(label: "Close", identifier: "dismissAccessibilityNotice") {
                composer.asksForAccessibility = false
                app.accessibilityNoticeDismissed = true
                SpotLog.window.info("Closed the Accessibility notice for this launch")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("accessibilityStrip")
        .onReceive(check) { _ in
            guard Self.goesAwayWithAccess, SelectionReader.hasAccess(prompt: false) else { return }
            SpotLog.window.info("Accessibility access given; the notice goes away")
            composer.asksForAccessibility = false
        }
    }
}

/// The strip's x, round and 24 points.
private struct StripCloseButton: View {
    let label: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(HoverCircle())
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier(identifier)
    }
}
