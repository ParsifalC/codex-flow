import SwiftUI
import Foundation

/// A compact text label that keeps the normal layout truncated, but reveals the
/// complete value in a small native popover after a short hover dwell.
///
/// Use this anywhere a user-facing string is intentionally line-limited. The
/// component does not reveal content while privacy mode is active.
public struct HoverRevealText: View {
    public let text: String
    public let font: Font
    public let foregroundColor: Color
    public let lineLimit: Int?
    public let truncationMode: Text.TruncationMode
    public let privacyBlur: Bool
    public let alignment: TextAlignment
    public let popoverWidth: CGFloat

    @State private var isPresented = false
    @State private var hoverGeneration = 0

    public init(
        _ text: String,
        font: Font = .system(size: 10),
        foregroundColor: Color = .white,
        lineLimit: Int? = 1,
        truncationMode: Text.TruncationMode = .tail,
        privacyBlur: Bool = false,
        alignment: TextAlignment = .leading,
        popoverWidth: CGFloat = 340
    ) {
        self.text = text
        self.font = font
        self.foregroundColor = foregroundColor
        self.lineLimit = lineLimit
        self.truncationMode = truncationMode
        self.privacyBlur = privacyBlur
        self.alignment = alignment
        self.popoverWidth = popoverWidth
    }

    public var body: some View {
        Text(text)
            .font(font)
            .foregroundColor(foregroundColor)
            .lineLimit(lineLimit)
            .truncationMode(truncationMode)
            .multilineTextAlignment(alignment)
            .blur(radius: privacyBlur ? 4.5 : 0)
            .contentShape(Rectangle())
            .onHover(perform: handleSourceHover)
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ZStack {
                    Color(red: 0.055, green: 0.062, blue: 0.085)
                        .ignoresSafeArea()

                    ScrollView(.vertical, showsIndicators: true) {
                        expandedText
                            .font(font)
                            .foregroundColor(.white.opacity(0.92))
                            .multilineTextAlignment(.leading)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                    }
                }
                .frame(width: min(max(popoverWidth, 220), 520))
                .frame(maxHeight: 260)
                .background(Color(red: 0.055, green: 0.062, blue: 0.085))
                .preferredColorScheme(.dark)
                .onHover(perform: handlePopoverHover)
            }
    }

    /// Native Foundation Markdown parsing keeps headings, lists, fenced code,
    /// inline code, and links selectable without introducing a WebView or HTML.
    /// A malformed value falls back to the exact source text. Link attributes
    /// are retained only for http/https URLs so local files and script schemes
    /// can never become clickable from telemetry.
    @ViewBuilder
    private var expandedText: some View {
        if let markdown = Self.parseMarkdown(text) {
            Text(markdown)
        } else {
            Text(text)
        }
    }

    private static func parseMarkdown(_ source: String) -> AttributedString? {
        do {
            var value = try AttributedString(
                markdown: source,
                options: .init(interpretedSyntax: .full)
            )

            for run in value.runs {
                guard let link = run.link else { continue }
                let scheme = link.scheme?.lowercased()
                guard scheme == "http" || scheme == "https" else {
                    value[run.range].link = nil
                    continue
                }
            }
            return value
        } catch {
            return nil
        }
    }

    private func handleSourceHover(_ inside: Bool) {
        hoverGeneration += 1
        let generation = hoverGeneration

        guard !privacyBlur, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            isPresented = false
            return
        }

        let delay = inside ? 0.22 : 0.25
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == hoverGeneration else { return }
            withAnimation(.easeInOut(duration: 0.12)) {
                isPresented = inside
            }
        }
    }

    private func handlePopoverHover(_ inside: Bool) {
        hoverGeneration += 1
        let generation = hoverGeneration

        if inside {
            isPresented = true
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            guard generation == hoverGeneration else { return }
            withAnimation(.easeInOut(duration: 0.12)) {
                isPresented = false
            }
        }
    }
}
