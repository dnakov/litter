import SwiftUI
import PhotosUI
import UIKit
import os

/// Composer variant for the home screen. When a project is selected, typing
/// and hitting send creates a new thread on (project.serverId, project.cwd)
/// and submits the initial turn. User stays on home — the new thread appears
/// in the task list and streams in place.
struct HomeComposerView: View {
    let project: AppProject?
    let onThreadCreated: (ThreadKey) -> Void
    /// Fires when the composer becomes "active" (keyboard up, text/image
    /// entered, or voice recording/transcribing) or returns to idle.
    var onActiveChange: ((Bool) -> Void)? = nil
    /// When true, the composer requests keyboard focus the moment it
    /// appears. Used when the view is revealed by tapping `+`.
    var autoFocus: Bool = false

    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState

    @State private var inputText = ""
    @State private var attachedImage: UIImage?
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    /// Plain `@State`, not `@FocusState`: the composer's text view is a
    /// UIKit `UITextView` wrapped in a UIViewRepresentable, not a SwiftUI
    /// focusable view. Using `@FocusState` without a matching `.focused()`
    /// modifier causes SwiftUI's focus manager to immediately revert any
    /// programmatic `true` back to `false`, which made the keyboard close
    /// the moment it opened.
    @State private var isComposerFocused: Bool = false

    private var isDisabled: Bool { project == nil }

    private var isActive: Bool {
        isComposerFocused
            || !inputText.isEmpty
            || attachedImage != nil
            || voiceManager.isRecording
            || voiceManager.isTranscribing
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(LitterTheme.warning)
                    Text(errorMessage)
                        .litterFont(.caption)
                        .foregroundStyle(LitterTheme.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        self.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(LitterTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
            }

            ConversationComposerContentView(
                attachedImage: attachedImage,
                collaborationMode: .default,
                activePlanProgress: nil,
                pendingUserInputRequest: nil,
                hasPendingPlanImplementation: false,
                activeTaskSummary: nil,
                queuedFollowUps: [],
                rateLimits: nil,
                contextPercent: nil,
                isTurnActive: isSubmitting,
                showModeChip: false,
                voiceManager: voiceManager,
                showAttachMenu: $showAttachMenu,
                onClearAttachment: { attachedImage = nil },
                onRespondToPendingUserInput: { _ in },
                onSteerQueuedFollowUp: { _ in },
                onDeleteQueuedFollowUp: { _ in },
                onPasteImage: { image in attachedImage = image },
                onOpenModePicker: {},
                onSendText: handleSend,
                onStopRecording: stopVoiceRecording,
                onStartRecording: startVoiceRecording,
                onInterrupt: {},
                inputText: $inputText,
                isComposerFocused: Binding(
                    get: { isComposerFocused },
                    set: { isComposerFocused = $0 }
                )
            )
        }
        .onChange(of: isActive) { _, active in
            onActiveChange?(active)
        }
        .sheet(isPresented: $showAttachMenu) {
            ConversationComposerAttachSheet(
                onPickPhotoLibrary: {
                    showAttachMenu = false
                    showPhotoPicker = true
                },
                onTakePhoto: {
                    showAttachMenu = false
                    showCamera = true
                }
            )
            .presentationDetents([.height(210)])
            .presentationDragIndicator(.visible)
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task { await loadSelectedPhoto(item) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $attachedImage)
                .ignoresSafeArea()
        }
        .task {
            // Focus as early as possible so the keyboard rises in parallel
            // with the glass-morph spring — the two animations then feel
            // like one fluid motion. A tiny 40ms yield lets the view land
            // in the window tree; the UIViewRepresentable picks up focus on
            // its next `updateUIView` pass. Re-issue once after the spring
            // settles as a safety net for edge cases where the first pass
            // fired before the window attachment.
            guard autoFocus else { return }
            try? await Task.sleep(nanoseconds: 40_000_000)
            isComposerFocused = true
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !isComposerFocused {
                isComposerFocused = true
            }
        }
    }

    private func handleSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = attachedImage
        guard !text.isEmpty || image != nil else { return }
        guard !isSubmitting else { return }
        guard let project else {
            errorMessage = "Pick a project before sending."
            return
        }

        inputText = ""
        attachedImage = nil
        isComposerFocused = false
        isSubmitting = true
        errorMessage = nil

        Task {
            defer { isSubmitting = false }
            do {
                let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                let modelOverride = pendingModel.isEmpty ? nil : pendingModel
                let pendingEffort = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                let effortOverride = ReasoningEffort(wireValue: pendingEffort.isEmpty ? nil : pendingEffort)
                let launchConfig = AppThreadLaunchConfig(
                    model: modelOverride,
                    approvalPolicy: appState.launchApprovalPolicy(for: nil),
                    sandbox: appState.launchSandboxMode(for: nil),
                    developerInstructions: nil,
                    persistExtendedHistory: true
                )
                let threadKey = try await appModel.client.startThread(
                    serverId: project.serverId,
                    params: launchConfig.threadStartRequest(cwd: project.cwd)
                )
                RecentDirectoryStore.shared.record(path: project.cwd, for: project.serverId)
                let preparedAttachment = image.flatMap(ConversationAttachmentSupport.prepareImage)
                var additionalInputs: [AppUserInput] = []
                if let preparedAttachment {
                    additionalInputs.append(preparedAttachment.userInput)
                }
                let payload = AppComposerPayload(
                    text: text,
                    additionalInputs: additionalInputs,
                    approvalPolicy: appState.launchApprovalPolicy(for: threadKey),
                    sandboxPolicy: appState.turnSandboxPolicy(for: threadKey),
                    model: modelOverride,
                    effort: effortOverride,
                    serviceTier: nil
                )
                try await appModel.startTurn(key: threadKey, payload: payload)
                await appModel.refreshSnapshot()
                onThreadCreated(threadKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else { return }
            voiceManager.startRecording()
        }
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            attachedImage = image
        }
        selectedPhoto = nil
    }

    private func stopVoiceRecording() {
        guard let project else {
            voiceManager.cancelRecording()
            return
        }
        Task {
            let auth = try? await appModel.client.authStatus(
                serverId: project.serverId,
                params: AuthStatusRequest(includeToken: true, refreshToken: false)
            )
            if let text = await voiceManager.stopAndTranscribe(
                authMethod: auth?.authMethod,
                authToken: auth?.authToken
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = text
                DispatchQueue.main.async {
                    isComposerFocused = true
                }
            }
        }
    }
}
