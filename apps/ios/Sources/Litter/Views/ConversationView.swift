import SwiftUI
import PhotosUI
import Inject

struct ConversationView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private var messages: [ChatMessage] {
        serverManager.activeThread?.messages ?? []
    }

    private var threadStatus: ConversationStatus {
        serverManager.activeThread?.status ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationMessageList(
                messages: messages,
                threadStatus: threadStatus,
                activeThreadKey: serverManager.activeThreadKey
            )
            ConversationInputBar(onSend: sendMessage)
        }
        .enableInjection()
    }

    private func sendMessage(_ text: String) {
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        let effort = appState.reasoningEffort
        Task { await serverManager.send(text, cwd: workDir, model: model, effort: effort) }
    }
}

private struct ConversationMessageList: View {
    let messages: [ChatMessage]
    let threadStatus: ConversationStatus
    let activeThreadKey: ThreadKey?
    @State private var pendingScrollWorkItem: DispatchWorkItem?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        EquatableMessageBubble(message: message)
                            .id(message.id)
                    }
                    if case .thinking = threadStatus {
                        TypingIndicator()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onAppear {
                scheduleScrollToBottom(proxy, delay: 0)
            }
            .onChange(of: activeThreadKey) {
                scheduleScrollToBottom(proxy, delay: 0)
            }
            .onChange(of: messages.count) {
                scheduleScrollToBottom(proxy)
            }
            .onDisappear {
                pendingScrollWorkItem?.cancel()
                pendingScrollWorkItem = nil
            }
        }
    }

    private func scheduleScrollToBottom(_ proxy: ScrollViewProxy, delay: TimeInterval = 0.05) {
        pendingScrollWorkItem?.cancel()
        let work = DispatchWorkItem {
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        pendingScrollWorkItem = work
        if delay == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

private struct EquatableMessageBubble: View, Equatable {
    let message: ChatMessage

    static func == (lhs: EquatableMessageBubble, rhs: EquatableMessageBubble) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        MessageBubbleView(message: message)
    }
}

private struct ConversationInputBar: View {
    let onSend: (String) -> Void

    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let img = attachedImage {
                HStack {
                    ZStack(alignment: .topTrailing) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        Button {
                            attachedImage = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(.body))
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

            HStack(alignment: .center, spacing: 8) {
                Button { showAttachMenu = true } label: {
                    Image(systemName: "plus")
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .modifier(GlassCircleModifier())
                }

                HStack(spacing: 0) {
                    TextField("Message litter...", text: $inputText, axis: .vertical)
                        .font(.system(.body))
                        .foregroundColor(.white)
                        .lineLimit(1...5)
                        .focused($inputFocused)
                        .padding(.leading, 14)
                        .padding(.vertical, 8)

                    if hasText {
                        Button {
                            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            inputText = ""
                            attachedImage = nil
                            onSend(text)
                        } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(.title2))
                                .foregroundColor(LitterTheme.accent)
                        }
                        .padding(.trailing, 4)
                    }
                }
                .frame(minHeight: 32)
                .modifier(GlassCapsuleModifier())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .confirmationDialog("Attach", isPresented: $showAttachMenu) {
            Button("Photo Library") { showPhotoPicker = true }
            Button("Take Photo") { showCamera = true }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data) {
                    attachedImage = img
                }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraView(image: $attachedImage)
                .ignoresSafeArea()
        }
    }
}

struct TypingIndicator: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(LitterTheme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .padding(.leading, 12)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeInOut(duration: 0.15)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
