import SwiftUI

/// Keeps the existing Skills / MCP visibility in the refreshed Inspector while
/// using the same hover-to-reveal behavior as the rest of the app.
public struct InspectorSkillsToolsView: View {
    public let run: TaskRun
    @State private var expanded = false

    public init(run: TaskRun) {
        self.run = run
    }

    private var skills: [SkillUsage] { run.skillsUsed ?? [] }
    private var tools: [ToolCallInfo] { run.toolsUsed ?? [] }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 8))
                        .foregroundColor(.purple)
                    Text(L("Skills & Tools", "技能与工具"))
                        .font(.system(size: 8.8, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(L("\(skills.count) skills · \(tools.count) tools", "\(skills.count) 个技能 · \(tools.count) 个工具"))
                        .font(.system(size: 7.3, weight: .medium))
                        .foregroundColor(.white.opacity(0.38))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white.opacity(0.35))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if !skills.isEmpty {
                    compactSection(title: L("Skills", "技能"), icon: "sparkles", tint: .purple) {
                        ForEach(skills) { skill in
                            compactItem(
                                text: skill.name,
                                trailing: skill.count.map { "×\($0)" },
                                tint: .purple
                            )
                        }
                    }
                }

                if !tools.isEmpty {
                    compactSection(title: L("Tools", "工具"), icon: "wrench.and.screwdriver.fill", tint: .teal) {
                        ForEach(tools) { tool in
                            compactItem(
                                text: tool.displayName,
                                trailing: tool.count.map { "×\($0)" },
                                tint: tool.isMcp == true ? .cyan : .teal
                            )
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.07), lineWidth: 0.7)
                )
        )
    }

    private func compactSection<Content: View>(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(.system(size: 7.6, weight: .semibold))
                .foregroundColor(tint.opacity(0.85))

            VStack(spacing: 3) {
                content()
            }
        }
    }

    private func compactItem(text: String, trailing: String?, tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint.opacity(0.85))
                .frame(width: 4, height: 4)

            HoverRevealText(
                text,
                font: .system(size: 8, weight: .medium, design: .monospaced),
                foregroundColor: .white.opacity(0.68),
                lineLimit: 1,
                popoverWidth: 380
            )
            .frame(maxWidth: .infinity, alignment: .leading)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 7.2, weight: .bold, design: .monospaced))
                    .foregroundColor(tint.opacity(0.75))
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.022)))
    }
}
