import SwiftUI
import AppKit

/// Caption layout is independent of the pet's animation and transparent sprite.
struct PetCaptionView: View {
    let run: TaskRun?
    let reminder: TaskRun?
    let privacy: Bool
    let reduceMotion: Bool

    var body: some View {
        Group {
            if let reminder {
                VStack(spacing: 2) {
                    Text(L("Done", "完成啦"))
                        .foregroundStyle(Color(red: 0.72, green: 0.94, blue: 0.83))
                        .frame(height: 14)
                    PetCaptionMarquee(text: detail(reminder), reduceMotion: reduceMotion)
                        .id(reminder.id + detail(reminder))
                        .frame(height: 14)
                }
            } else if let run, run.totalTokens > 0 {
                VStack(spacing: 2) {
                    Text(L("Used", "本轮消耗"))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(height: 14)
                    Text(run.formattedTotalTokens)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(height: 14)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.9))
        .shadow(color: .black.opacity(0.85), radius: 1)
        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
    }

    private func detail(_ run: TaskRun) -> String {
        guard !privacy else { return L("Task complete", "任务已完成") }
        let goal = run.publishedGoal?.split(whereSeparator: { $0.isNewline }).first.map(String.init)
        let source = goal ?? run.projectName
        return source.isEmpty ? L("Tap to view", "点我查看") : source
    }
}

/// Long captions make three finite passes; no timer remains after the reminder settles.
private struct PetCaptionMarquee: View {
    let text: String
    let reduceMotion: Bool
    @State private var offset: CGFloat = 0
    @State private var finished = false

    var body: some View {
        GeometryReader { geometry in
            let width = ceil((text as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium)
            ]).width)
            let overflow = max(0, width - geometry.size.width)
            Group {
                if finished {
                    Text(L("Tap to view", "点我查看"))
                        .lineLimit(1).minimumScaleFactor(0.75)
                } else if reduceMotion || overflow == 0 {
                    Text(text).lineLimit(1).truncationMode(.tail)
                } else {
                    Text(text)
                        .fixedSize()
                        .offset(x: offset)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: (finished || reduceMotion || overflow == 0) ? .center : .leading)
            .clipped()
            .task(id: "\(text)|\(overflow)|\(reduceMotion)") {
                offset = 0
                finished = false
                guard !reduceMotion, overflow > 0 else { return }
                do {
                    for _ in 0..<3 {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        let seconds = Double(overflow) / 24
                        withAnimation(.linear(duration: seconds)) { offset = -overflow }
                        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { offset = 0 }
                    }
                    finished = true
                } catch {
                    // SwiftUI cancels when the notification is read or replaced.
                }
            }
        }
        .accessibilityLabel(text)
    }
}
