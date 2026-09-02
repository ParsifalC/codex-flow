import SwiftUI
import AppKit

public struct BubbleView: View {
    @ObservedObject var state: OverlayState
    @State private var isHovered: Bool = false
    @State private var breathePhase: CGFloat = 0.0
    @State private var shimmerAngle: Double = 0.0
    
    public init(state: OverlayState) {
        self.state = state
    }
    
    public var body: some View {
        ZStack {
            // Pure circular dark frosted glass (diameter 58 inside 76 frame, leaving 9pt safe margin all around)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 0.14, green: 0.16, blue: 0.22).opacity(0.92),
                            Color(red: 0.06, green: 0.07, blue: 0.10).opacity(0.97)
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 29
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(isHovered ? 0.25 : 0.12), lineWidth: 0.8)
                )
                .frame(width: 58, height: 58)
            
            // Outer dynamic animated glow border (rotates & pulses on hover)
            Circle()
                .strokeBorder(
                    borderGradient,
                    lineWidth: isHovered ? 2.0 : 1.6
                )
                .rotationEffect(.degrees(isHovered ? shimmerAngle : 0))
                .shadow(
                    color: statusGlowColor.opacity(isHovered ? 0.85 : (state.isTaskRunning ? 0.7 : 0.3)),
                    radius: isHovered ? 4 : 2
                )
                .frame(width: 58, height: 58)
            
            // Central Content
            VStack(spacing: 2) {
                // Top status orb & icon
                ZStack {
                    // Pulsing ring if task is active or hovered
                    if state.isTaskRunning || isHovered {
                        Circle()
                            .stroke(statusColor.opacity(isHovered ? 0.6 : 0.4), lineWidth: 1.2)
                            .frame(width: 28, height: 28)
                            .scaleEffect(1.0 + breathePhase * (isHovered ? 0.25 : 0.35))
                            .opacity(1.0 - breathePhase)
                    }
                    
                    // App glyph / Logo
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: isHovered ? [.white, .cyan, .purple] : [.cyan, .indigo, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: .cyan.opacity(isHovered ? 0.7 : 0.3), radius: isHovered ? 3 : 1.5)
                }
                .frame(height: 22)
                
                // Micro token badge
                HStack(spacing: 2) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundColor(statusColor)
                    
                    Text(state.latestRun?.formattedTotalTokens ?? "Ready")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.95))
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.65))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(isHovered ? 0.3 : 0.15), lineWidth: 0.5)
                        )
                )
            }
            
            // Live Status Beacon dot (positioned neatly on top-right rim with zero clipping)
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .overlay(
                    Circle()
                        .stroke(Color.black.opacity(0.7), lineWidth: 1.2)
                )
                .shadow(color: statusColor.opacity(isHovered ? 0.9 : 0.7), radius: isHovered ? 3 : 1.5)
                .offset(x: 20, y: -20)
        }
        .frame(width: 76, height: 76)
        .contentShape(Circle())
        .onHover { hovered in
            withAnimation(.easeInOut(duration: 0.25)) {
                isHovered = hovered
            }
            if hovered {
                withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                    shimmerAngle = 360.0
                }
            } else {
                shimmerAngle = 0.0
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                breathePhase = 1.0
            }
        }
    }
    
    private var borderGradient: AnyShapeStyle {
        if state.isTaskRunning {
            return AnyShapeStyle(
                AngularGradient(
                    colors: [.cyan, .blue, .teal, .cyan],
                    center: .center
                )
            )
        } else if let run = state.latestRun, run.isError {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.orange, .red],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                AngularGradient(
                    colors: [
                        Color.cyan.opacity(0.8),
                        Color.purple.opacity(0.8),
                        Color.pink.opacity(0.8),
                        Color.cyan.opacity(0.8)
                    ],
                    center: .center
                )
            )
        }
    }
    
    private var statusColor: Color {
        if state.isTaskRunning {
            return .cyan
        } else if let run = state.latestRun {
            if run.isError {
                return .orange
            } else {
                return Color(red: 0.2, green: 0.85, blue: 0.45)
            }
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
    
    private var statusGlowColor: Color {
        if state.isTaskRunning {
            return .cyan
        } else if let run = state.latestRun, run.isError {
            return .red
        }
        return Color(red: 0.2, green: 0.85, blue: 0.45)
    }
}
