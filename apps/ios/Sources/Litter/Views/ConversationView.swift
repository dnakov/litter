import SwiftUI
import PhotosUI
import Inject

struct ConversationView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var inputText = ""
    @FocusState private var inputFocused: Bool
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?

    private var messages: [ChatMessage] {
        serverManager.activeThread?.messages ?? []
    }

    private var threadStatus: ConversationStatus {
        serverManager.activeThread?.status ?? .idle
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            inputBar
        }
        .enableInjection()
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }
                    if case .thinking = threadStatus {
                        TypingIndicator()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: messages.count) {
                withAnimation { proxy.scrollTo("bottom") }
            }
        }
    }

    private var hasText: Bool {
        !inputText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var inputBar: some View {
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
                            let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
                            let effort = appState.reasoningEffort
                            Task { await serverManager.send(text, cwd: workDir, model: model, effort: effort) }
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
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                withAnimation { phase = (phase + 1) % 3 }
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
