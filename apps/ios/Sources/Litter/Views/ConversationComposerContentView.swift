import SwiftUI
import UIKit

struct ConversationComposerContentView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let attachedImage: UIImage?
    let collaborationMode: AppModeKind
    let activePlanProgress: AppPlanProgressSnapshot?
    let pendingUserInputRequest: PendingUserInputRequest?
    let hasPendingPlanImplementation: Bool
    let activeTaskSummary: ConversationActiveTaskSummary?
    let queuedFollowUps: [AppQueuedFollowUpPreview]
    let rateLimits: RateLimitSnapshot?
    let contextPercent: Int64?
    let isTurnActive: Bool
    let showModeChip: Bool
    let voiceManager: VoiceTranscriptionManager
    let allowsVoiceInput: Bool
    @Binding var showAttachMenu: Bool
    let onClearAttachment: () -> Void
    let onRespondToPendingUserInput: ([String: [String]]) -> Void
    let onImplementPlan: () -> Void
    let onDismissPlanImplementation: () -> Void
    let onSteerQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onDeleteQueuedFollowUp: (AppQueuedFollowUpPreview) -> Void
    let onPasteImage: (UIImage) -> Void
    let onOpenModePicker: () -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool

    init(
        attachedImage: UIImage?,
        collaborationMode: AppModeKind,
        activePlanProgress: AppPlanProgressSnapshot?,
        pendingUserInputRequest: PendingUserInputRequest?,
        hasPendingPlanImplementation: Bool = false,
        activeTaskSummary: ConversationActiveTaskSummary?,
        queuedFollowUps: [AppQueuedFollowUpPreview],
        rateLimits: RateLimitSnapshot?,
        contextPercent: Int64?,
        isTurnActive: Bool,
        showModeChip: Bool = true,
        voiceManager: VoiceTranscriptionManager,
        allowsVoiceInput: Bool = true,
        showAttachMenu: Binding<Bool>,
        onClearAttachment: @escaping () -> Void,
        onRespondToPendingUserInput: @escaping ([String: [String]]) -> Void,
        onImplementPlan: @escaping () -> Void = {},
        onDismissPlanImplementation: @escaping () -> Void = {},
        onSteerQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onDeleteQueuedFollowUp: @escaping (AppQueuedFollowUpPreview) -> Void,
        onPasteImage: @escaping (UIImage) -> Void,
        onOpenModePicker: @escaping () -> Void,
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>
    ) {
        self.attachedImage = attachedImage
        self.collaborationMode = collaborationMode
        self.activePlanProgress = activePlanProgress
        self.pendingUserInputRequest = pendingUserInputRequest
        self.hasPendingPlanImplementation = hasPendingPlanImplementation
        self.activeTaskSummary = activeTaskSummary
        self.queuedFollowUps = queuedFollowUps
        self.rateLimits = rateLimits
        self.contextPercent = contextPercent
        self.isTurnActive = isTurnActive
        self.showModeChip = showModeChip
        self.voiceManager = voiceManager
        self.allowsVoiceInput = allowsVoiceInput
        _showAttachMenu = showAttachMenu
        self.onClearAttachment = onClearAttachment
        self.onRespondToPendingUserInput = onRespondToPendingUserInput
        self.onImplementPlan = onImplementPlan
        self.onDismissPlanImplementation = onDismissPlanImplementation
        self.onSteerQueuedFollowUp = onSteerQueuedFollowUp
        self.onDeleteQueuedFollowUp = onDeleteQueuedFollowUp
        self.onPasteImage = onPasteImage
        self.onOpenModePicker = onOpenModePicker
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
        _inputText = inputText
        _isComposerFocused = isComposerFocused
    }

    var body: some View {
        VStack(spacing: 0) {
            if let attachedImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: attachedImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Button(action: onClearAttachment) {
                            Image(systemName: "xmark.circle.fill")
                                .litterFont(.body)
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                        }
                        .offset(x: 4, y: -4)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            VStack(alignment: .trailing, spacing: 0) {
                if let activePlanProgress {
                    ConversationComposerPlanProgressView(progress: activePlanProgress)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let activeTaskSummary {
                    ConversationComposerActiveTaskRowView(summary: activeTaskSummary)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if let pendingUserInputRequest {
                    PendingUserInputPromptView(request: pendingUserInputRequest, onSubmit: onRespondToPendingUserInput)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                if hasPendingPlanImplementation {
                    PlanImplementationPromptView(
                        onImplement: onImplementPlan,
                        onDismiss: onDismissPlanImplementation
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                }

                if !queuedFollowUps.isEmpty {
                    QueuedFollowUpsPreviewView(
                        previews: queuedFollowUps,
                        onSteer: onSteerQueuedFollowUp,
                        onDelete: onDeleteQueuedFollowUp
                    )
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                }

                ConversationComposerEntryRowView(
                    showAttachMenu: $showAttachMenu,
                    inputText: $inputText,
                    isComposerFocused: $isComposerFocused,
                    voiceManager: voiceManager,
                    isTurnActive: isTurnActive,
                    hasAttachment: attachedImage != nil,
                    allowsVoiceInput: allowsVoiceInput,
                    onPasteImage: onPasteImage,
                    onSendText: onSendText,
                    onStopRecording: onStopRecording,
                    onStartRecording: onStartRecording,
                    onInterrupt: onInterrupt
                )

                ConversationComposerContextBarView(
                    rateLimits: rateLimits,
                    contextPercent: contextPercent
                )
            }
        }
        .frame(maxWidth: LitterPlatform.isRegularSurface(horizontalSizeClass: horizontalSizeClass) ? 760 : .infinity)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct ConversationComposerModeChip: View {
    let mode: AppModeKind
    let onTap: () -> Void

    private var label: String {
        switch mode {
        case .plan:
            return "Plan"
        case .`default`:
            return "Default"
        }
    }

    private var foreground: Color {
        mode == .plan ? Color.black : LitterTheme.textPrimary
    }

    private var background: Color {
        mode == .plan ? LitterTheme.accent : LitterTheme.surfaceLight
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Text(label)
                    .litterFont(.caption, weight: .semibold)
                Image(systemName: "chevron.up.chevron.down")
                    .litterFont(size: 10, weight: .semibold)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(background))
        }
        .buttonStyle(.plain)
    }
}

private struct ConversationComposerPlanProgressView: View {
    let progress: AppPlanProgressSnapshot

    private var completedCount: Int {
        progress.plan.filter { $0.status == .completed }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard")
                    .litterFont(size: 12, weight: .semibold)
                    .foregroundStyle(LitterTheme.accent)
                Text("Plan Progress")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                Text("\(completedCount)/\(progress.plan.count)")
                    .litterMonoFont(size: 11, weight: .semibold)
                    .foregroundStyle(LitterTheme.textSecondary)
            }

            if let explanation = progress.explanation?.trimmingCharacters(in: .whitespacesAndNewlines),
               !explanation.isEmpty {
                Text(explanation)
                    .litterFont(.caption)
                    .foregroundStyle(LitterTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(progress.plan.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: iconName(for: step.status))
                            .litterFont(size: 11, weight: .semibold)
                            .foregroundStyle(iconColor(for: step.status))
                            .padding(.top, 2)
                        Text("\(index + 1).")
                            .litterMonoFont(size: 11, weight: .semibold)
                            .foregroundStyle(LitterTheme.textMuted)
                            .padding(.top, 1)
                        Text(step.step)
                            .litterFont(.caption)
                            .foregroundStyle(LitterTheme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LitterTheme.codeBackground.opacity(0.92))
        )
    }

    private func iconName(for status: AppPlanStepStatus) -> String {
        switch status {
        case .completed:
            return "checkmark.circle.fill"
        case .inProgress:
            return "circle.fill"
        case .pending:
            return "circle"
        }
    }

    private func iconColor(for status: AppPlanStepStatus) -> Color {
        switch status {
        case .completed:
            return LitterTheme.success
        case .inProgress:
            return LitterTheme.warning
        case .pending:
            return LitterTheme.textMuted
        }
    }
}

private struct ConversationComposerActiveTaskRowView: View {
    let summary: ConversationActiveTaskSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist")
                .litterFont(size: 11, weight: .semibold)
                .foregroundColor(LitterTheme.warning)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.title)
                        .litterFont(.caption, weight: .semibold)
                        .foregroundColor(LitterTheme.textPrimary)

                    Text(summary.progressLabel)
                        .litterMonoFont(size: 10, weight: .semibold)
                        .foregroundColor(LitterTheme.warning)
                }

                Text(summary.detail)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LitterTheme.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
