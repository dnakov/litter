import SwiftUI

/// Per-task detail — shows the task's steps, subtitle, and nav links to
/// its transcript or a reply composer. Requesting focus on this task from
/// the phone causes the next snapshot to carry this task's transcript.
struct TaskDetailScreen: View {
    @EnvironmentObject var store: WatchAppStore
    let task: WatchTask

    var body: some View {
        // Prefer the freshest version from the store — the task param might
        // be stale if we've been on this screen across multiple snapshots.
        let current = store.tasks.first(where: { $0.id == task.id }) ?? task

        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                header(for: current)

                Text(current.title)
                    .font(WatchTheme.mono(13, weight: .bold))
                    .foregroundStyle(WatchTheme.text)
                    .fixedSize(horizontal: false, vertical: true)

                if let subtitle = current.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(WatchTheme.mono(10))
                        .foregroundStyle(WatchTheme.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if current.status == .needsApproval,
                   let approval = store.pendingApproval,
                   current.pendingApprovalId == approval.id {
                    NavigationLink {
                        ApprovalScreen()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(WatchTheme.ginger)
                            Text("review approval")
                                .font(WatchTheme.mono(11, weight: .bold))
                                .foregroundStyle(WatchTheme.text)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(WatchTheme.ginger.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(WatchTheme.ginger.opacity(0.4), lineWidth: 1)
                                )
                        )
                    }
                    .buttonStyle(.plain)
                }

                if !current.steps.isEmpty {
                    WatchEyebrow(text: "recent", size: 9)
                        .padding(.top, 4)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(current.steps) { step in
                            StepRow(step: step)
                        }
                    }
                }

                HStack(spacing: 4) {
                    NavigationLink {
                        TranscriptScreen()
                    } label: {
                        actionLabel("transcript", icon: "text.bubble")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        VoiceScreen()
                    } label: {
                        actionLabel("reply", icon: "mic.fill", accent: true)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 4)
        }
        .onAppear {
            store.focus(on: current)
        }
        .containerBackground(WatchTheme.bg.gradient, for: .navigation)
    }

    private func header(for task: WatchTask) -> some View {
        HStack(spacing: 6) {
            switch task.status {
            case .running:
                PulsingDot(color: WatchTheme.ginger, size: 7)
                Text("running")
                    .font(WatchTheme.mono(10, weight: .bold))
                    .foregroundStyle(WatchTheme.ginger)
            case .needsApproval:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(WatchTheme.ginger)
                Text("needs approval")
                    .font(WatchTheme.mono(10, weight: .bold))
                    .foregroundStyle(WatchTheme.ginger)
            case .idle:
                Circle().fill(WatchTheme.dim).frame(width: 6, height: 6)
                Text("idle")
                    .font(WatchTheme.mono(10, weight: .bold))
                    .foregroundStyle(WatchTheme.dim)
            case .error:
                Circle().fill(WatchTheme.danger).frame(width: 6, height: 6)
                Text("error")
                    .font(WatchTheme.mono(10, weight: .bold))
                    .foregroundStyle(WatchTheme.danger)
            }
            Spacer()
            Text(task.serverName)
                .font(WatchTheme.mono(9))
                .foregroundStyle(WatchTheme.dim)
                .lineLimit(1)
                .truncationMode(.middle)
            if !task.relativeTime.isEmpty {
                Text(task.relativeTime)
                    .font(WatchTheme.mono(9))
                    .foregroundStyle(WatchTheme.dim)
            }
        }
    }

    private func actionLabel(_ label: String, icon: String, accent: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .font(WatchTheme.mono(11, weight: .bold))
        }
        .frame(maxWidth: .infinity, minHeight: 30)
        .foregroundStyle(accent ? WatchTheme.onAccent : WatchTheme.text)
        .background(
            Capsule().fill(accent
                ? LinearGradient(colors: [WatchTheme.gingerLight, WatchTheme.ginger],
                                 startPoint: .top, endPoint: .bottom)
                : LinearGradient(colors: [WatchTheme.surfaceHi, WatchTheme.surfaceHi],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(
                Capsule().stroke(accent ? Color.clear : WatchTheme.borderHi, lineWidth: 1)
            )
        )
    }
}

private struct StepRow: View {
    let step: WatchTaskStep

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StepBullet(state: step.state)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(step.tool)
                    .font(WatchTheme.mono(11, weight: step.state == .active ? .bold : .regular))
                    .foregroundStyle(color(for: step.state))
                    .lineLimit(1)
                if !step.arg.isEmpty {
                    Text(step.arg)
                        .font(WatchTheme.mono(9))
                        .foregroundStyle(WatchTheme.dimMore)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func color(for state: WatchTaskStep.State) -> Color {
        switch state {
        case .active:  return WatchTheme.ginger
        case .done:    return WatchTheme.text
        case .pending: return WatchTheme.dim
        }
    }
}

private struct StepBullet: View {
    let state: WatchTaskStep.State
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().stroke(stroke, lineWidth: 1)

            switch state {
            case .done:
                Image(systemName: "checkmark")
                    .font(.system(size: 6, weight: .heavy))
                    .foregroundStyle(WatchTheme.success)
            case .active:
                Circle()
                    .fill(WatchTheme.ginger)
                    .frame(width: 4, height: 4)
                    .opacity(pulse ? 0.3 : 1)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
                    .onAppear { pulse = true }
            case .pending:
                EmptyView()
            }
        }
    }

    private var fill: Color {
        switch state {
        case .done:    return WatchTheme.success.opacity(0.15)
        case .active:  return WatchTheme.ginger.opacity(0.2)
        case .pending: return WatchTheme.surfaceHi
        }
    }

    private var stroke: Color {
        switch state {
        case .done:    return WatchTheme.success.opacity(0.4)
        case .active:  return WatchTheme.ginger
        case .pending: return WatchTheme.borderHi
        }
    }
}

#if DEBUG
#Preview("running") {
    NavigationStack {
        TaskDetailScreen(task: WatchPreviewFixtures.tasks[0])
            .environmentObject(WatchAppStore.previewStore())
    }
}

#Preview("idle") {
    NavigationStack {
        TaskDetailScreen(task: WatchPreviewFixtures.tasks[1])
            .environmentObject(WatchAppStore.previewStore())
    }
}
#endif
