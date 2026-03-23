import SwiftUI
import UIKit

struct ConversationComposerContentView: View {
    let attachedImage: UIImage?
    let pendingUserInputRequest: PendingUserInputRequest?
    let rateLimits: RateLimitSnapshot?
    let contextPercent: Int64?
    let isTurnActive: Bool
    let voiceManager: VoiceTranscriptionManager
    @Binding var showAttachMenu: Bool
    let onClearAttachment: () -> Void
    let onRespondToPendingUserInput: ([String: [String]]) -> Void
    let onPasteImage: (UIImage) -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool

    init(
        attachedImage: UIImage?,
        pendingUserInputRequest: ServerManager.PendingUserInputRequest?,
        rateLimits: RateLimitSnapshot?,
        contextPercent: Int64?,
        isTurnActive: Bool,
        voiceManager: VoiceTranscriptionManager,
        showAttachMenu: Binding<Bool>,
        onClearAttachment: @escaping () -> Void,
        onRespondToPendingUserInput: @escaping ([String: [String]]) -> Void,
        onPasteImage: @escaping (UIImage) -> Void,
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>
    ) {
        self.attachedImage = attachedImage
        self.pendingUserInputRequest = pendingUserInputRequest
        self.rateLimits = rateLimits
        self.contextPercent = contextPercent
        self.isTurnActive = isTurnActive
        self.voiceManager = voiceManager
        _showAttachMenu = showAttachMenu
        self.onClearAttachment = onClearAttachment
        self.onRespondToPendingUserInput = onRespondToPendingUserInput
        self.onPasteImage = onPasteImage
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
                if let pendingUserInputRequest {
                    PendingUserInputPromptView(request: pendingUserInputRequest, onSubmit: onRespondToPendingUserInput)
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
    }
}
