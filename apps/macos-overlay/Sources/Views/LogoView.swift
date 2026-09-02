import SwiftUI
import AppKit

public struct FlowPilotLogoView: View {
    public var size: CGFloat
    public var showGlow: Bool
    public var withBolt: Bool
    public var text: String

    public init(
        size: CGFloat = 256,
        showGlow: Bool = true,
        withBolt: Bool = true,
        text: String = "FlowPilot"
    ) {
        self.size = size
        self.showGlow = showGlow
        self.withBolt = withBolt
        self.text = text
    }

    private var circleDiameter: CGFloat { size * 0.76 }
    private var beaconSize: CGFloat { circleDiameter * 0.138 }
    private var sparklesSize: CGFloat { circleDiameter * 0.31 }
    private var beaconOffset: CGFloat { circleDiameter * 0.35 }

    public var body: some View {
        ZStack {
            // 1. Dark Frosted Glass Inner Body
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.15, green: 0.17, blue: 0.24).opacity(0.96),
                            Color(red: 0.07, green: 0.08, blue: 0.12).opacity(0.98)
                        ],
                        center: .center,
                        startRadius: circleDiameter * 0.08,
                        endRadius: circleDiameter * 0.5
                    )
                )
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.08),
                                    Color.cyan.opacity(0.20)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(1.0, circleDiameter * 0.015)
                        )
                )
                .frame(width: circleDiameter, height: circleDiameter)

            // 2. Dynamic Neon Rainbow Border Glow
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [
                            Color(red: 0.0, green: 0.85, blue: 1.0),   // Cyan
                            Color(red: 0.35, green: 0.45, blue: 1.0),  // Indigo
                            Color(red: 0.75, green: 0.35, blue: 0.95), // Purple
                            Color(red: 1.0, green: 0.35, blue: 0.65),  // Pink
                            Color(red: 0.0, green: 0.9, blue: 0.75),   // Teal
                            Color(red: 0.0, green: 0.85, blue: 1.0)    // Cyan
                        ],
                        center: .center
                    ),
                    lineWidth: max(1.8, circleDiameter * 0.028)
                )
                .shadow(
                    color: Color.cyan.opacity(showGlow ? 0.75 : 0.0),
                    radius: max(3.0, circleDiameter * 0.06)
                )
                .shadow(
                    color: Color(red: 0.7, green: 0.3, blue: 0.9).opacity(showGlow ? 0.45 : 0.0),
                    radius: max(6.0, circleDiameter * 0.1)
                )
                .frame(width: circleDiameter, height: circleDiameter)

            // 3. Central Content Stack
            VStack(spacing: circleDiameter * 0.04) {
                // Sparkles Hero Glyph
                Image(systemName: "sparkles")
                    .font(.system(size: sparklesSize, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color.white,
                                Color(red: 0.2, green: 0.85, blue: 1.0),
                                Color(red: 0.65, green: 0.4, blue: 0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: Color.cyan.opacity(0.8), radius: max(2.5, sparklesSize * 0.25))
                    .shadow(color: Color.purple.opacity(0.5), radius: max(5.0, sparklesSize * 0.4))
                    .offset(y: circleDiameter * 0.015)

                // Bottom Pill Badge with "FlowPilot" (replacing token quantity)
                HStack(spacing: circleDiameter * 0.025) {
                    if withBolt {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: circleDiameter * 0.095, weight: .heavy))
                            .foregroundColor(Color(red: 0.2, green: 0.88, blue: 0.45))
                            .shadow(color: Color(red: 0.2, green: 0.88, blue: 0.45).opacity(0.8), radius: 2)
                    }

                    Text(text)
                        .font(.system(
                            size: withBolt ? circleDiameter * 0.112 : circleDiameter * 0.125,
                            weight: .heavy,
                            design: .rounded
                        ))
                        .foregroundColor(Color.white.opacity(0.98))
                        .shadow(color: Color.black.opacity(0.8), radius: 2, y: 1)
                }
                .padding(.horizontal, circleDiameter * 0.055)
                .padding(.vertical, circleDiameter * 0.022)
                .background(
                    Capsule()
                        .fill(Color(red: 0.04, green: 0.05, blue: 0.08).opacity(0.88))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.35),
                                    Color.cyan.opacity(0.35),
                                    Color.white.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(0.8, circleDiameter * 0.012)
                        )
                )
                .shadow(color: Color.black.opacity(0.6), radius: 4, y: 2)
            }

            // 4. Emerald Active Beacon Dot (Upper Right)
            ZStack {
                // Radiant beacon bloom
                Circle()
                    .fill(Color(red: 0.2, green: 0.88, blue: 0.45).opacity(0.4))
                    .frame(width: beaconSize * 1.6, height: beaconSize * 1.6)
                    .blur(radius: beaconSize * 0.25)

                // Solid beacon dot
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 0.4, green: 1.0, blue: 0.65),
                                Color(red: 0.15, green: 0.82, blue: 0.4)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: beaconSize * 0.5
                        )
                    )
                    .frame(width: beaconSize, height: beaconSize)
                    .overlay(
                        Circle()
                            .stroke(Color(red: 0.05, green: 0.06, blue: 0.09), lineWidth: max(1.2, beaconSize * 0.16))
                    )
                    .shadow(
                        color: Color(red: 0.2, green: 0.88, blue: 0.45).opacity(0.95),
                        radius: max(3.0, beaconSize * 0.35)
                    )
            }
            .offset(x: beaconOffset, y: -beaconOffset)
        }
        .frame(width: size, height: size)
    }
}
