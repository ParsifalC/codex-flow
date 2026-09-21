import SwiftUI

/// Shared colors from the optimized popup design.
enum OverlayTheme {
    static let primary = Color(red: 244 / 255, green: 247 / 255, blue: 251 / 255)
    static let secondary = Color(red: 179 / 255, green: 188 / 255, blue: 201 / 255)
    static let muted = Color(red: 107 / 255, green: 118 / 255, blue: 134 / 255)
    static let accent = Color(red: 126 / 255, green: 162 / 255, blue: 1)
    static let good = Color(red: 85 / 255, green: 217 / 255, blue: 138 / 255)
    static let warning = Color(red: 244 / 255, green: 192 / 255, blue: 78 / 255)
}

/// Full-label hit testing and consistent feedback for native popup controls.
struct OverlayButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = 8
    func makeBody(configuration: Configuration) -> some View {
        Feedback(configuration: configuration, cornerRadius: cornerRadius)
    }
    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        let cornerRadius: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.white.opacity(isEnabled && (hovered || configuration.isPressed) ? (configuration.isPressed ? 0.10 : 0.055) : 0)))
                .contentShape(Rectangle())
                .onHover { hovered = $0 }
        }
    }
}

/// Hairline separators dissolve into the panel at both ends.
struct OverlayDivider: View {
    var vertical = false
    var body: some View {
        LinearGradient(
            stops: [.init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.10), location: 0.25),
                    .init(color: .white.opacity(0.10), location: 0.75),
                    .init(color: .clear, location: 1)],
            startPoint: vertical ? .top : .leading,
            endPoint: vertical ? .bottom : .trailing
        )
        .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        .accessibilityHidden(true)
    }
}

/// The heading, trailing caption and blank space all toggle the disclosure.
struct OverlayDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(OverlayTheme.muted)
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                    configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(OverlayButtonStyle())
            .accessibilityValue(configuration.isExpanded ? L("Expanded", "已展开") : L("Collapsed", "已收起"))
            if configuration.isExpanded { configuration.content }
        }
    }
}
