import SwiftUI
import Textual

/// Markdown styles for replies in a conversation rather than a document, after Claude's:
/// every block keeps no margin of its own and blocks are separated by one gap set here;
/// 16 pt text at about 1.375 line height; medium-weight bold; headings close to the text size;
/// code blocks as cards; full-width tables with row rules only.
enum ChatMarkdown {
    static let fontSize: CGFloat = 16
    /// The one gap between blocks, 20 pt at 16 pt text.
    static let blockGap: CGFloat = 1.25
    /// Extra space between lines for a line height of about 1.375; SF's own line height is about 1.19.
    static let lineSpacing: CGFloat = 0.18
    /// Monospaced text at 14 pt.
    static let codeScale: CGFloat = 0.875

    static var blockSpacing: FontScaled<StructuredText.BlockSpacing> {
        .fontScaled(top: blockGap, bottom: 0)
    }

    static let inlineStyle = InlineStyle()
        .code(.monospaced, .fontScale(codeScale), .backgroundColor(DynamicColor(light: .black.opacity(0.05), dark: .white.opacity(0.08))))
        .strong(.fontWeight(.medium))
        .link(.foregroundColor(Color.accentColor))
}

extension View {
    func chatMarkdownStyle() -> some View {
        font(.system(size: ChatMarkdown.fontSize))
            .textual.inlineStyle(ChatMarkdown.inlineStyle)
            .textual.headingStyle(ChatHeadingStyle())
            .textual.paragraphStyle(ChatParagraphStyle())
            .textual.listItemSpacing(.fontScaled(top: 0))
            .textual.blockQuoteStyle(ChatBlockQuoteStyle())
            .textual.tableStyle(ChatTableStyle())
            .textual.tableCellStyle(ChatTableCellStyle())
            .textual.codeBlockStyle(SpotCodeBlockStyle())
    }
}

struct ChatHeadingStyle: StructuredText.HeadingStyle {
    private static let fontScales: [CGFloat] = [1.25, 1.125, 1.0, 1.0, 1.0, 1.0]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(max(configuration.headingLevel, 1), 6)
        configuration.label
            .textual.fontScale(Self.fontScales[level - 1])
            .textual.lineSpacing(.fontScaled(ChatMarkdown.lineSpacing))
            .textual.blockSpacing(ChatMarkdown.blockSpacing)
            .fontWeight(.semibold)
    }
}

struct ChatParagraphStyle: StructuredText.ParagraphStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textual.lineSpacing(.fontScaled(ChatMarkdown.lineSpacing))
            .textual.blockSpacing(ChatMarkdown.blockSpacing)
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
            .textual.blockSpacing(ChatMarkdown.blockSpacing)
    }
}

/// Full width, with a rule under the header and between rows, and no vertical lines.
struct ChatTableStyle: StructuredText.TableStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .textual.tableCellSpacing(horizontal: 0, vertical: 1)
            .textual.blockSpacing(ChatMarkdown.blockSpacing)
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
            .textual.lineSpacing(.fontScaled(ChatMarkdown.lineSpacing))
            .textual.padding(.vertical, .fontScaled(0.5))
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
    static let padding: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(configuration.languageHint ?? "")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(height: 16)
            .anchorPreference(key: CodeCopyTargetsKey.self, value: .bounds) { anchor in
                [CodeCopyTarget(anchor: anchor, copy: configuration.codeBlock.copyToPasteboard)]
            }
            .padding(.horizontal, Self.padding)
            .padding(.top, Self.padding)
            Overflow {
                configuration.label
                    .monospaced()
                    .textual.fontScale(ChatMarkdown.codeScale)
                    .textual.lineSpacing(.fontScaled(0.3))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.padding)
                    .padding(.bottom, Self.padding)
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
        .textual.blockSpacing(ChatMarkdown.blockSpacing)
    }
}

/// Draws a Copy button over each code block header reported by `CodeCopyTargetsKey`.
struct CodeCopyButtons: View {
    let targets: [CodeCopyTarget]

    var body: some View {
        GeometryReader { proxy in
            ForEach(targets.indices, id: \.self) { index in
                let rect = proxy[targets[index].anchor]
                // The header row reported is the label's line; the button is centered on it, inset like the label.
                CopyCodeButton(copy: targets[index].copy)
                    .frame(width: rect.width + 8, height: rect.height, alignment: .trailing)
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
