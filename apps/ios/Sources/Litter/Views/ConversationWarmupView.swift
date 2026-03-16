import SwiftUI
import UIKit
import os

private let conversationWarmupSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "ConversationWarmup"
)

struct ConversationWarmupView: View {
    let warmupID: UUID
    let onComplete: () -> Void

    @State private var warmupInputText = ""
    @State private var shouldPrimeKeyboard = false
    @State private var didCompleteWarmup = false
    @FocusState private var warmupComposerFocused: Bool
    @State private var voiceManager = VoiceTranscriptionManager()

    var body: some View {
        ZStack {
            ConversationComposerEntryRowView(
                inputText: $warmupInputText,
                isComposerFocused: $warmupComposerFocused,
                voiceManager: voiceManager,
                isTurnActive: false,
                onShowAttachMenu: {},
                onSendText: {},
                onStopRecording: {},
                onStartRecording: {},
                onInterrupt: {}
            )
            .frame(width: 220, height: 56)
            .clipped()

            ConversationKeyboardWarmupTextView(
                shouldPrimeKeyboard: $shouldPrimeKeyboard,
                onDidPrimeKeyboard: completeWarmup
            )
            .frame(width: 100, height: 44)
        }
        .offset(x: -9999)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: warmupID) {
            await runWarmup()
        }
    }

    @MainActor
    private func runWarmup() async {
        let signpostID = OSSignpostID(log: conversationWarmupSignpostLog)
        os_signpost(.begin, log: conversationWarmupSignpostLog, name: "PrewarmConversation", signpostID: signpostID)
        defer {
            os_signpost(.end, log: conversationWarmupSignpostLog, name: "PrewarmConversation", signpostID: signpostID)
        }

        try? await Task.sleep(nanoseconds: 60_000_000)
        guard !didCompleteWarmup else { return }
        shouldPrimeKeyboard = true

        try? await Task.sleep(nanoseconds: 900_000_000)
        completeWarmup()
    }

    @MainActor
    private func completeWarmup() {
        guard !didCompleteWarmup else { return }
        didCompleteWarmup = true
        shouldPrimeKeyboard = false
        warmupComposerFocused = false
        onComplete()
    }
}

private struct ConversationKeyboardWarmupTextView: UIViewRepresentable {
    @Binding var shouldPrimeKeyboard: Bool
    let onDidPrimeKeyboard: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDidPrimeKeyboard: onDidPrimeKeyboard)
    }

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: CGRect(x: -9999, y: -9999, width: 100, height: 44))
        field.delegate = context.coordinator
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.spellCheckingType = .no
        context.coordinator.field = field
        return field
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        guard shouldPrimeKeyboard else {
            if uiView.isFirstResponder {
                uiView.resignFirstResponder()
            }
            return
        }

        guard !context.coordinator.didPrimeKeyboard else { return }

        DispatchQueue.main.async {
            guard shouldPrimeKeyboard, !context.coordinator.didPrimeKeyboard else { return }
            uiView.becomeFirstResponder()
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        weak var field: UITextField?
        var didPrimeKeyboard = false
        let onDidPrimeKeyboard: () -> Void

        init(onDidPrimeKeyboard: @escaping () -> Void) {
            self.onDidPrimeKeyboard = onDidPrimeKeyboard
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            guard !didPrimeKeyboard else { return }
            didPrimeKeyboard = true

            DispatchQueue.main.async {
                textField.resignFirstResponder()
                self.onDidPrimeKeyboard()
            }
        }
    }
}
