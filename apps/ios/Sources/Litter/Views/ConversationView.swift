import SwiftUI
import PhotosUI
import Inject

struct ConversationView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @FocusState private var composerFocused: Bool

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
                activeThreadKey: serverManager.activeThreadKey,
                inputFocused: $composerFocused
            )
            ConversationInputBar(
                onSend: sendMessage,
                onFileSearch: searchComposerFiles,
                inputFocused: $composerFocused
            )
        }
        .enableInjection()
    }

    private func sendMessage(_ text: String) {
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        let effort = appState.reasoningEffort
        Task { await serverManager.send(text, cwd: workDir, model: model, effort: effort) }
    }

    private func searchComposerFiles(_ query: String) async throws -> [FuzzyFileSearchResult] {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            throw NSError(
                domain: "Litter",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "No connected server available for file search"]
            )
        }
        let searchRoot = workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : workDir
        let resp = try await conn.fuzzyFileSearch(
            query: query,
            roots: [searchRoot],
            cancellationToken: "ios-composer-file-search"
        )
        return resp.files
    }
}

private struct ConversationMessageList: View {
    let messages: [ChatMessage]
    let threadStatus: ConversationStatus
    let activeThreadKey: ThreadKey?
    let inputFocused: FocusState<Bool>.Binding
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
            .scrollDismissesKeyboard(.interactively)
            .simultaneousGesture(
                TapGesture().onEnded {
                    inputFocused.wrappedValue = false
                }
            )
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
        lhs.message.id == rhs.message.id &&
        lhs.message.role == rhs.message.role &&
        lhs.message.text == rhs.message.text &&
        lhs.message.images.count == rhs.message.images.count
    }

    var body: some View {
        MessageBubbleView(message: message)
    }
}

private struct ConversationInputBar: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    let onSend: (String) -> Void
    let onFileSearch: (String) async throws -> [FuzzyFileSearchResult]
    let inputFocused: FocusState<Bool>.Binding

    @State private var inputText = ""
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var showSlashPopup = false
    @State private var activeSlashToken: ComposerSlashQueryContext?
    @State private var slashSuggestions: [ComposerSlashCommand] = []
    @State private var showFilePopup = false
    @State private var activeAtToken: ComposerTokenContext?
    @State private var fileSearchLoading = false
    @State private var fileSearchError: String?
    @State private var fileSuggestions: [FuzzyFileSearchResult] = []
    @State private var fileSearchGeneration = 0
    @State private var fileSearchTask: Task<Void, Never>?
    @State private var showModelSelector = false
    @State private var showPermissionsSheet = false
    @State private var showExperimentalSheet = false
    @State private var showSkillsSheet = false
    @State private var showRenamePrompt = false
    @State private var renameDraft = ""
    @State private var slashErrorMessage: String?
    @State private var experimentalFeatures: [ExperimentalFeature] = []
    @State private var experimentalFeaturesLoading = false
    @State private var skills: [SkillMetadata] = []
    @State private var skillsLoading = false

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

            if showSlashPopup {
                suggestionPopup {
                    ForEach(Array(slashSuggestions.enumerated()), id: \.element.rawValue) { index, command in
                        Button {
                            applySlashSuggestion(command)
                        } label: {
                            HStack(spacing: 10) {
                                Text("/\(command.rawValue)")
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(Color(hex: "#6EA676"))
                                Text(command.description)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        if index < slashSuggestions.count - 1 {
                            Divider().background(LitterTheme.border)
                        }
                    }
                }
            }

            if showFilePopup {
                suggestionPopup {
                    if fileSearchLoading {
                        Text("Searching files...")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    } else if let fileSearchError, !fileSearchError.isEmpty {
                        Text(fileSearchError)
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    } else if fileSuggestions.isEmpty {
                        Text("No matches")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    } else {
                        ForEach(Array(fileSuggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                applyFileSuggestion(suggestion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .font(.system(.caption))
                                        .foregroundColor(LitterTheme.textSecondary)
                                    Text(suggestion.path)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)
                            if index < min(fileSuggestions.count, 8) - 1 {
                                Divider().background(LitterTheme.border)
                            }
                        }
                    }
                }
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
                        .focused(inputFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .padding(.leading, 14)
                        .padding(.vertical, 8)

                    if hasText {
                        Button {
                            let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return }
                            if attachedImage == nil,
                               let invocation = parseSlashCommandInvocation(text) {
                                inputText = ""
                                attachedImage = nil
                                hideComposerPopups()
                                inputFocused.wrappedValue = false
                                executeSlashCommand(invocation.command, args: invocation.args)
                                return
                            }
                            inputText = ""
                            attachedImage = nil
                            hideComposerPopups()
                            inputFocused.wrappedValue = false
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
        .onChange(of: inputText) { _, next in
            refreshComposerPopups(for: next)
        }
        .onDisappear {
            fileSearchTask?.cancel()
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
        .sheet(isPresented: $showModelSelector) {
            ModelSelectorView()
                .environmentObject(serverManager)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPermissionsSheet) {
            NavigationStack {
                List {
                    ForEach(ComposerPermissionPreset.allCases) { preset in
                        Button {
                            appState.approvalPolicy = preset.approvalPolicy
                            appState.sandboxMode = preset.sandboxMode
                            showPermissionsSheet = false
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(preset.title)
                                        .foregroundColor(.white)
                                        .font(.system(.subheadline, design: .monospaced))
                                    Spacer()
                                    if preset.approvalPolicy == appState.approvalPolicy && preset.sandboxMode == appState.sandboxMode {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(LitterTheme.accent)
                                    }
                                }
                                Text(preset.description)
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
                .scrollContentBackground(.hidden)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                .navigationTitle("Permissions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showPermissionsSheet = false }
                            .foregroundColor(LitterTheme.accent)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showExperimentalSheet) {
            NavigationStack {
                Group {
                    if experimentalFeaturesLoading {
                        ProgressView().tint(LitterTheme.accent)
                    } else if experimentalFeatures.isEmpty {
                        Text("No experimental features available")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(LitterTheme.textMuted)
                    } else {
                        List {
                            ForEach(experimentalFeatures) { feature in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(feature.displayName ?? feature.name)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .foregroundColor(.white)
                                        Text(feature.description ?? feature.stage)
                                            .font(.system(.caption, design: .monospaced))
                                            .foregroundColor(LitterTheme.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { feature.enabled },
                                            set: { value in
                                                Task { await setExperimentalFeature(feature, enabled: value) }
                                            }
                                        )
                                    )
                                    .labelsHidden()
                                    .tint(LitterTheme.accent)
                                }
                                .listRowBackground(LitterTheme.surface.opacity(0.6))
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                .navigationTitle("Experimental")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reload") { Task { await loadExperimentalFeatures() } }
                            .foregroundColor(LitterTheme.accent)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showExperimentalSheet = false }
                            .foregroundColor(LitterTheme.accent)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .sheet(isPresented: $showSkillsSheet) {
            NavigationStack {
                Group {
                    if skillsLoading {
                        ProgressView().tint(LitterTheme.accent)
                    } else if skills.isEmpty {
                        Text("No skills available for this workspace")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundColor(LitterTheme.textMuted)
                    } else {
                        List {
                            ForEach(skills) { skill in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(skill.name)
                                            .font(.system(.subheadline, design: .monospaced))
                                            .foregroundColor(.white)
                                        Spacer()
                                        if skill.enabled {
                                            Text("enabled")
                                                .font(.system(.caption2, design: .monospaced))
                                                .foregroundColor(LitterTheme.accent)
                                        }
                                    }
                                    Text(skill.description)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(LitterTheme.textSecondary)
                                    Text(skill.path)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundColor(LitterTheme.textMuted)
                                }
                                .listRowBackground(LitterTheme.surface.opacity(0.6))
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(LitterTheme.backgroundGradient.ignoresSafeArea())
                .navigationTitle("Skills")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reload") { Task { await loadSkills(forceReload: true) } }
                            .foregroundColor(LitterTheme.accent)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { showSkillsSheet = false }
                            .foregroundColor(LitterTheme.accent)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .alert("Rename Thread", isPresented: $showRenamePrompt) {
            TextField("Thread name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let nextName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nextName.isEmpty else { return }
                Task { await renameThread(nextName) }
            }
        } message: {
            Text("Set a new name for the active thread.")
        }
        .alert("Slash Command Error", isPresented: Binding(
            get: { slashErrorMessage != nil },
            set: { if !$0 { slashErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { slashErrorMessage = nil }
        } message: {
            Text(slashErrorMessage ?? "Unknown error")
        }
    }

    @ViewBuilder
    private func suggestionPopup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity)
        .background(LitterTheme.surface.opacity(0.95))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitterTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func clearFileSearchState() {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        fileSearchGeneration += 1
        fileSearchLoading = false
        fileSearchError = nil
        fileSuggestions = []
    }

    private func hideComposerPopups() {
        showSlashPopup = false
        activeSlashToken = nil
        slashSuggestions = []
        showFilePopup = false
        activeAtToken = nil
        clearFileSearchState()
    }

    private func startFileSearch(_ query: String) {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        let requestId = fileSearchGeneration + 1
        fileSearchGeneration = requestId
        fileSearchLoading = true
        fileSearchError = nil
        fileSuggestions = []

        fileSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            guard activeAtToken?.value == query else { return }

            do {
                let matches = try await onFileSearch(query)
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = matches
                fileSearchLoading = false
                fileSearchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = []
                fileSearchLoading = false
                fileSearchError = error.localizedDescription
            }
        }
    }

    private func refreshComposerPopups(for nextText: String) {
        let cursor = nextText.count
        if let atToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "@",
            allowEmpty: true
        ) {
            showSlashPopup = false
            activeSlashToken = nil
            slashSuggestions = []
            showFilePopup = true
            if activeAtToken != atToken {
                activeAtToken = atToken
                startFileSearch(atToken.value)
            }
            return
        }

        activeAtToken = nil
        showFilePopup = false
        clearFileSearchState()

        guard let slashToken = currentSlashQueryContext(text: nextText, cursor: cursor) else {
            showSlashPopup = false
            activeSlashToken = nil
            slashSuggestions = []
            return
        }

        activeSlashToken = slashToken
        slashSuggestions = filterSlashCommands(slashToken.query)
        showSlashPopup = !slashSuggestions.isEmpty
    }

    private func applySlashSuggestion(_ command: ComposerSlashCommand) {
        showSlashPopup = false
        activeSlashToken = nil
        slashSuggestions = []
        inputText = ""
        attachedImage = nil
        executeSlashCommand(command, args: nil)
    }

    private func executeSlashCommand(_ command: ComposerSlashCommand, args: String?) {
        switch command {
        case .model:
            showModelSelector = true
        case .permissions:
            showPermissionsSheet = true
        case .experimental:
            showExperimentalSheet = true
            Task { await loadExperimentalFeatures() }
        case .skills:
            showSkillsSheet = true
            Task { await loadSkills() }
        case .review:
            Task { await startReview() }
        case .rename:
            let initialName = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if initialName.isEmpty {
                renameDraft = serverManager.activeThread?.preview ?? ""
                showRenamePrompt = true
            } else {
                Task { await renameThread(initialName) }
            }
        case .new:
            appState.showServerPicker = true
        case .resume:
            withAnimation(.easeInOut(duration: 0.25)) {
                appState.sidebarOpen = true
            }
        }
    }

    private func parseSlashCommandInvocation(_ text: String) -> (command: ComposerSlashCommand, args: String?)? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let commandAndArgs = trimmed.dropFirst()
        let commandName = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let command = ComposerSlashCommand(rawCommand: commandName) else { return nil }
        let args = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init)
        return (command, args)
    }

    private func startReview() async {
        do {
            try await serverManager.startReviewOnActiveThread()
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func renameThread(_ newName: String) async {
        do {
            try await serverManager.renameActiveThread(newName)
            showRenamePrompt = false
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func loadExperimentalFeatures() async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            experimentalFeatures = []
            slashErrorMessage = "Not connected to a server"
            return
        }
        experimentalFeaturesLoading = true
        defer { experimentalFeaturesLoading = false }
        do {
            let response = try await conn.listExperimentalFeatures(limit: 200)
            experimentalFeatures = response.data.sorted { lhs, rhs in
                let left = (lhs.displayName?.isEmpty == false ? lhs.displayName! : lhs.name).lowercased()
                let right = (rhs.displayName?.isEmpty == false ? rhs.displayName! : rhs.name).lowercased()
                return left < right
            }
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func setExperimentalFeature(_ feature: ExperimentalFeature, enabled: Bool) async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            slashErrorMessage = "Not connected to a server"
            return
        }
        do {
            _ = try await conn.writeConfigValue(keyPath: "features.\(feature.name)", value: enabled)
            if let index = experimentalFeatures.firstIndex(where: { $0.id == feature.id }) {
                experimentalFeatures[index] = ExperimentalFeature(
                    name: feature.name,
                    stage: feature.stage,
                    displayName: feature.displayName,
                    description: feature.description,
                    announcement: feature.announcement,
                    enabled: enabled,
                    defaultEnabled: feature.defaultEnabled
                )
            }
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func loadSkills(forceReload: Bool = false) async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            skills = []
            slashErrorMessage = "Not connected to a server"
            return
        }
        skillsLoading = true
        defer { skillsLoading = false }
        do {
            let response = try await conn.listSkills(cwds: [workDir], forceReload: forceReload)
            skills = response.data.flatMap(\.skills).sorted { $0.name.lowercased() < $1.name.lowercased() }
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func applyFileSuggestion(_ match: FuzzyFileSearchResult) {
        guard let token = activeAtToken else { return }
        let quotedPath = (match.path.contains(" ") && !match.path.contains("\"")) ? "\"\(match.path)\"" : match.path
        let replacement = "\(quotedPath) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        showFilePopup = false
        activeAtToken = nil
        clearFileSearchState()
    }
}

private enum ComposerSlashCommand: CaseIterable {
    case model
    case permissions
    case experimental
    case skills
    case review
    case rename
    case new
    case resume

    var rawValue: String {
        switch self {
        case .model: return "model"
        case .permissions: return "permissions"
        case .experimental: return "experimental"
        case .skills: return "skills"
        case .review: return "review"
        case .rename: return "rename"
        case .new: return "new"
        case .resume: return "resume"
        }
    }

    var description: String {
        switch self {
        case .model: return "choose what model and reasoning effort to use"
        case .permissions: return "choose what Codex is allowed to do"
        case .experimental: return "toggle experimental features"
        case .skills: return "use skills to improve how Codex performs specific tasks"
        case .review: return "review my current changes and find issues"
        case .rename: return "rename the current thread"
        case .new: return "start a new chat during a conversation"
        case .resume: return "resume a saved chat"
        }
    }

    init?(rawCommand: String) {
        switch rawCommand.lowercased() {
        case "model": self = .model
        case "permissions": self = .permissions
        case "experimental": self = .experimental
        case "skills": self = .skills
        case "review": self = .review
        case "rename": self = .rename
        case "new": self = .new
        case "resume": self = .resume
        default: return nil
        }
    }
}

private enum ComposerPermissionPreset: CaseIterable, Identifiable {
    case readOnly
    case auto
    case fullAccess

    var id: String { title }

    var title: String {
        switch self {
        case .readOnly: return "Read Only"
        case .auto: return "Auto"
        case .fullAccess: return "Full Access"
        }
    }

    var description: String {
        switch self {
        case .readOnly: return "Ask before commands and run in read-only sandbox"
        case .auto: return "No prompts and workspace-write sandbox"
        case .fullAccess: return "No prompts and danger-full-access sandbox"
        }
    }

    var approvalPolicy: String {
        switch self {
        case .readOnly: return "on-request"
        case .auto, .fullAccess: return "never"
        }
    }

    var sandboxMode: String {
        switch self {
        case .readOnly: return "read-only"
        case .auto: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }
}

private struct ComposerTokenRange: Equatable {
    let start: Int
    let end: Int
}

private struct ComposerTokenContext: Equatable {
    let value: String
    let range: ComposerTokenRange
}

private struct ComposerSlashQueryContext: Equatable {
    let query: String
    let range: ComposerTokenRange
}

private func filterSlashCommands(_ query: String) -> [ComposerSlashCommand] {
    guard !query.isEmpty else { return Array(ComposerSlashCommand.allCases) }
    return ComposerSlashCommand.allCases
        .compactMap { command -> (ComposerSlashCommand, Int)? in
            guard let score = fuzzyScore(candidate: command.rawValue, query: query) else { return nil }
            return (command, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.rawValue < rhs.0.rawValue
        }
        .map(\.0)
}

private func fuzzyScore(candidate: String, query: String) -> Int? {
    let normalizedCandidate = candidate.lowercased()
    let normalizedQuery = query.lowercased()

    if normalizedCandidate == normalizedQuery {
        return 1000
    }
    if normalizedCandidate.hasPrefix(normalizedQuery) {
        return 900 - (normalizedCandidate.count - normalizedQuery.count)
    }
    if normalizedCandidate.contains(normalizedQuery) {
        return 700 - (normalizedCandidate.count - normalizedQuery.count)
    }

    var score = 0
    var queryIndex = normalizedQuery.startIndex
    var candidateIndex = normalizedCandidate.startIndex

    while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
        if normalizedQuery[queryIndex] == normalizedCandidate[candidateIndex] {
            score += 10
            queryIndex = normalizedQuery.index(after: queryIndex)
        }
        candidateIndex = normalizedCandidate.index(after: candidateIndex)
    }

    return queryIndex == normalizedQuery.endIndex ? score : nil
}

private func currentPrefixedToken(
    text: String,
    cursor: Int,
    prefix: Character,
    allowEmpty: Bool
) -> ComposerTokenContext? {
    guard let tokenRange = tokenRangeAroundCursor(text: text, cursor: cursor) else { return nil }
    guard let tokenText = substring(text, within: tokenRange), tokenText.first == prefix else { return nil }
    let value = String(tokenText.dropFirst())
    if value.isEmpty && !allowEmpty {
        return nil
    }
    return ComposerTokenContext(value: value, range: tokenRange)
}

private func currentSlashQueryContext(
    text: String,
    cursor: Int
) -> ComposerSlashQueryContext? {
    let safeCursor = max(0, min(cursor, text.count))
    let firstLineEnd = text.firstIndex(of: "\n").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
    if safeCursor > firstLineEnd || firstLineEnd <= 0 {
        return nil
    }

    let firstLine = String(text.prefix(firstLineEnd))
    guard firstLine.hasPrefix("/") else { return nil }

    var commandEnd = 1
    let chars = Array(firstLine)
    while commandEnd < chars.count && !chars[commandEnd].isWhitespace {
        commandEnd += 1
    }
    if safeCursor > commandEnd {
        return nil
    }

    let query = commandEnd > 1 ? String(chars[1..<commandEnd]) : ""
    let rest = commandEnd < chars.count ? String(chars[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

    if query.isEmpty {
        if !rest.isEmpty {
            return nil
        }
    } else if query.contains("/") {
        return nil
    }

    return ComposerSlashQueryContext(query: query, range: ComposerTokenRange(start: 0, end: commandEnd))
}

private func tokenRangeAroundCursor(
    text: String,
    cursor: Int
) -> ComposerTokenRange? {
    guard !text.isEmpty else { return nil }

    let safeCursor = max(0, min(cursor, text.count))
    let chars = Array(text)

    if safeCursor < chars.count, chars[safeCursor].isWhitespace {
        var index = safeCursor
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        if index < chars.count {
            var end = index
            while end < chars.count && !chars[end].isWhitespace {
                end += 1
            }
            return ComposerTokenRange(start: index, end: end)
        }
    }

    var start = safeCursor
    while start > 0 && !chars[start - 1].isWhitespace {
        start -= 1
    }

    var end = safeCursor
    while end < chars.count && !chars[end].isWhitespace {
        end += 1
    }

    if end <= start {
        return nil
    }
    return ComposerTokenRange(start: start, end: end)
}

private func replacingRange(
    in text: String,
    with range: ComposerTokenRange,
    replacement: String
) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    var copy = text
    copy.replaceSubrange(lower..<upper, with: replacement)
    return copy
}

private func substring(_ text: String, within range: ComposerTokenRange) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    return String(text[lower..<upper])
}

private func index(in text: String, offset: Int) -> String.Index? {
    guard offset >= 0, offset <= text.count else { return nil }
    return text.index(text.startIndex, offsetBy: offset)
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
