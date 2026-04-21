import SwiftUI
import UIKit

struct ConversationComposerEntryRowView: View {
    @Binding var showAttachMenu: Bool
    @Binding var inputText: String
    @Binding var isComposerFocused: Bool
    let voiceManager: VoiceTranscriptionManager
    let isTurnActive: Bool
    let hasAttachment: Bool
    let onPasteImage: (UIImage) -> Void
    let onSendText: () -> Void
    let onStopRecording: () -> Void
    let onStartRecording: () -> Void
    let onInterrupt: () -> Void

    init(
        showAttachMenu: Binding<Bool>,
        inputText: Binding<String>,
        isComposerFocused: Binding<Bool>,
        voiceManager: VoiceTranscriptionManager,
        isTurnActive: Bool,
        hasAttachment: Bool,
        onPasteImage: @escaping (UIImage) -> Void,
        onSendText: @escaping () -> Void,
        onStopRecording: @escaping () -> Void,
        onStartRecording: @escaping () -> Void,
        onInterrupt: @escaping () -> Void
    ) {
        _showAttachMenu = showAttachMenu
        _inputText = inputText
        _isComposerFocused = isComposerFocused
        self.voiceManager = voiceManager
        self.isTurnActive = isTurnActive
        self.hasAttachment = hasAttachment
        self.onPasteImage = onPasteImage
        self.onSendText = onSendText
        self.onStopRecording = onStopRecording
        self.onStartRecording = onStartRecording
        self.onInterrupt = onInterrupt
    }

    @State private var showExpanded: Bool = false

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSend: Bool {
        hasText || hasAttachment
    }

    /// Show the expand affordance once the composer is multi-line or starts to
    /// wrap, matching ChatGPT's behaviour. Short prompts stay clutter-free.
    private var shouldShowExpand: Bool {
        !voiceManager.isRecording
            && !voiceManager.isTranscribing
            && (inputText.contains("\n") || inputText.count > 60)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if !voiceManager.isRecording && !voiceManager.isTranscribing && !isTurnActive {
                Button {
                    showAttachMenu = true
                } label: {
                    Image(systemName: "plus")
                        .font(LitterFont.styled(size: 17, weight: .semibold))
                        .foregroundColor(LitterTheme.textPrimary)
                        .frame(width: 36, height: 36)
                        .modifier(GlassCircleModifier())
                }
                .transition(.scale.combined(with: .opacity))
            }

            HStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    ConversationComposerTextView(
                        text: $inputText,
                        isFocused: $isComposerFocused,
                        onPasteImage: onPasteImage
                    )

                    if inputText.isEmpty {
                        Text("Message litter...")
                            .font(LitterFont.styled(size: 17))
                            .foregroundColor(LitterTheme.textMuted)
                            .padding(.leading, 16)
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }
                }

                if canSend {
                    Button(action: onSendText) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(LitterFont.styled(size: 22))
                            .foregroundColor(LitterTheme.accent)
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                } else if voiceManager.isRecording {
                    AudioWaveformView(level: voiceManager.audioLevel)
                        .frame(width: 48, height: 20)

                    Button(action: onStopRecording) {
                        Image(systemName: "stop.circle.fill")
                            .font(LitterFont.styled(size: 22))
                            .foregroundColor(LitterTheme.accentStrong)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                } else if voiceManager.isTranscribing {
                    ProgressView()
                        .tint(LitterTheme.accent)
                        .padding(.trailing, 8)
                } else {
                    Button(action: onStartRecording) {
                        Image(systemName: "mic.fill")
                            .font(LitterFont.styled(size: 15))
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(width: 32, height: 32)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 4)
                }
            }
            .frame(minHeight: 36)
            .modifier(GlassRoundedRectModifier(cornerRadius: 20))
            .overlay(alignment: .topTrailing) {
                if shouldShowExpand {
                    Button {
                        showExpanded = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(LitterFont.styled(size: 12, weight: .semibold))
                            .foregroundColor(LitterTheme.textSecondary)
                            .padding(6)
                            .contentShape(Rectangle())
                    }
                    .padding(.top, 2)
                    .padding(.trailing, 6)
                    .accessibilityLabel("Expand composer")
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.15), value: shouldShowExpand)

            if isTurnActive {
                Button(action: onInterrupt) {
                    Text("Cancel")
                        .font(LitterFont.styled(size: 15, weight: .medium))
                        .foregroundColor(LitterTheme.textPrimary)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .modifier(GlassCapsuleModifier())
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

        }
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: isTurnActive)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 6)
        .fullScreenCover(isPresented: $showExpanded) {
            ConversationComposerExpandedView(
                inputText: $inputText,
                isPresented: $showExpanded,
                onPasteImage: onPasteImage,
                onSend: onSendText,
                hasAttachment: hasAttachment
            )
        }
    }
}
