import SwiftUI
import Textual

/// Markdown styles for replies in a conversation rather than a document:
/// headings barely larger than the text, roomy lines, full-width tables with row rules only,
/// and code blocks with a quiet language label.
extension View {
    func chatMarkdownStyle() -> some View {
        textual.headingStyle(ChatHeadingStyle())
            .textual.paragraphStyle(ChatParagraphStyle())
            .textual.listItemStyle(.default(markerSpacing: .fontScaled(0.7)))
            .textual.listItemSpacing(.fontScaled(top: 0.3))
            .textual.blockQuoteStyle(ChatBlockQuoteStyle())
            .textual.tableStyle(ChatTableStyle())
            .textual.tableCellStyle(ChatTableCellStyle())
            .textual.codeBlockStyle(SpotCodeBlockStyle())
    }
}

struct ChatHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.3, 1.13, 1.0, 1.0, 1.0, 1.0]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .textual.lineSpacing(.fontScaled(0.2))
            .textual.blockSpacing(.fontScaled(top: 1.2, bottom: 0.35))
            .fontWeight(level == 1 ? .bold : .semibold)
    }
}

struct ChatParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(0.4))
            .textual.blockSpacing(.fontScaled(top: 0.75))
    }
}

struct ChatBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 14)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: 3)
            }
    }
}

/// Full width, with a rule under the header and between rows, and no vertical lines.
struct ChatTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .textual.tableCellSpacing(horizontal: 0, vertical: 1)
            .textual.blockSpacing(.fontScaled(top: 1, bottom: 1))
            .textual.tableOverlay { layout in
                Canvas { context, _ in
                    for divider in layout.horizontalDividers() {
                        context.fill(Path(divider), with: .color(Color.primary.opacity(0.12)))
                    }
                }
            }
    }
}

struct ChatTableCellStyle: StructuredText.TableCellStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(configuration.row == 0 ? .semibold : .regular)
            .textual.lineSpacing(.fontScaled(0.3))
            .textual.padding(.vertical, .fontScaled(0.55))
            .padding(.trailing, 12)
            // Cells fill their column, so the table spreads across the reply.
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where each code block's header sits. The reply draws the Copy buttons there, above Textual's
/// text selection layer, which would otherwise take their clicks.
struct CodeCopyTarget {
    let anchor: Anchor<CGRect>
    let copy: () -> Void
}

struct CodeCopyTargetsKey: PreferenceKey {
    static var defaultValue: [CodeCopyTarget] { [] }

    static func reduce(value: inout [CodeCopyTarget], nextValue: () -> [CodeCopyTarget]) {
        value.append(contentsOf: nextValue())
    }
}

struct SpotCodeBlockStyle: StructuredText.CodeBlockStyle {
    static let headerHeight: CGFloat = 32

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(configuration.languageHint ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Self.headerHeight)
            .anchorPreference(key: CodeCopyTargetsKey.self, value: .bounds) { anchor in
                [CodeCopyTarget(anchor: anchor, copy: configuration.codeBlock.copyToPasteboard)]
            }
            Overflow {
                configuration.label
                    .monospaced()
                    .textual.fontScale(0.88)
                    .textual.lineSpacing(.fontScaled(0.35))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 14)
                    .background(OverlayScrollers())
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background(Color.primary.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08))
        )
        .textual.blockSpacing(.fontScaled(top: 0.9, bottom: 0.9))
    }
}

/// Draws a Copy button over each code block header reported by `CodeCopyTargetsKey`.
struct CodeCopyButtons: View {
    let targets: [CodeCopyTarget]

    var body: some View {
        GeometryReader { proxy in
            ForEach(targets.indices, id: \.self) { index in
                let rect = proxy[targets[index].anchor]
                CopyCodeButton(copy: targets[index].copy)
                    .padding(.trailing, 8)
                    .frame(width: rect.width, height: rect.height, alignment: .trailing)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }
}

/// Copies the code block and shows Copied for a moment.
struct CopyCodeButton: View {
    let copy: () -> Void
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            copy()
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Group {
                if copied {
                    Label("Copied", systemImage: "checkmark")
                } else {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .accessibilityIdentifier("copyCode")
    }
}
