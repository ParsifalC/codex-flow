import SwiftUI

/// A modern, tactile switch toggle style tailored for dark glassmorphic overlays.
///
/// Features a vibrant luminous track when active, a clean translucent dark glass
/// track when inactive, smooth spring physics, subtle depth drop-shadows, and
/// clear visual contrast in macOS dark mode.
public struct SleekSwitchToggleStyle: ToggleStyle {
    public var tint: Color
    public var width: CGFloat
    public var height: CGFloat

    public init(tint: Color = .cyan, width: CGFloat = 34, height: CGFloat = 19) {
        self.tint = tint
        self.width = width
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        SleekSwitchControl(configuration: configuration, tint: tint, width: width, height: height)
    }
}

private struct SleekSwitchControl: View {
    let configuration: ToggleStyle.Configuration
    let tint: Color
    let width: CGFloat
    let height: CGFloat

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var knobSize: CGFloat { height - 4 }
    private var travelDistance: CGFloat { width - knobSize - 4 }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.24, dampingFraction: 0.72)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: .leading) {
                // Background Track
                Capsule(style: .continuous)
                    .fill(
                        configuration.isOn
                            ? LinearGradient(
                                colors: [tint, tint.opacity(0.82)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            : LinearGradient(
                                colors: [
                                    Color.white.opacity(isHovered ? 0.16 : 0.11),
                                    Color.white.opacity(isHovered ? 0.09 : 0.06)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(
                                configuration.isOn
                                    ? tint.opacity(0.55)
                                    : Color.white.opacity(isHovered ? 0.18 : 0.12),
                                lineWidth: 0.8
                            )
                    )

                // Active subtle ambient glow
                if configuration.isOn {
                    Capsule(style: .continuous)
                        .stroke(tint.opacity(0.4), lineWidth: 1.5)
                        .blur(radius: 2)
                }

                // Knob
                Circle()
                    .fill(
                        configuration.isOn
                            ? LinearGradient(
                                colors: [.white, Color(white: 0.94)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            : LinearGradient(
                                colors: [
                                    Color(white: isHovered ? 0.92 : 0.86),
                                    Color(white: isHovered ? 0.82 : 0.76)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                    )
                    .frame(width: knobSize, height: knobSize)
                    .shadow(
                        color: Color.black.opacity(configuration.isOn ? 0.35 : 0.28),
                        radius: 2,
                        x: configuration.isOn ? -0.5 : 0.5,
                        y: 1
                    )
                    .padding(.leading, 2)
                    .offset(x: configuration.isOn ? travelDistance : 0)
                    .scaleEffect(isHovered ? 1.04 : 1.0)
            }
            .frame(width: width, height: height)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1.0 : 0.42)
        .onHover { isHovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
