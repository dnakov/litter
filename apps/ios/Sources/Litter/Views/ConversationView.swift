import SwiftUI
import PhotosUI
import Inject

struct ConversationView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @FocusState private var composerFocused: Bool
    @State private var messageActionError: String?

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
                inputFocused: $composerFocused,
                onEditUserMessage: editMessage,
                onForkFromUserMessage: forkFromMessage
            )
            ConversationInputBar(
                onSend: sendMessage,
                onFileSearch: searchComposerFiles,
                inputFocused: $composerFocused
            )
        }
        .alert("Conversation Action Error", isPresented: Binding(
            get: { messageActionError != nil },
            set: { if !$0 { messageActionError = nil } }
        )) {
            Button("OK", role: .cancel) { messageActionError = nil }
        } message: {
            Text(messageActionError ?? "Unknown error")
        }
        .enableInjection()
    }

    private func sendMessage(_ text: String, skillMentions: [SkillMentionSelection]) {
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        let effort = appState.reasoningEffort
        Task {
            await serverManager.send(
                text,
                skillMentions: skillMentions,
                cwd: workDir,
                model: model,
                effort: effort,
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
        }
    }

    private func editMessage(_ message: ChatMessage) {
        Task {
            do {
                try await serverManager.editMessage(message)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func forkFromMessage(_ message: ChatMessage) {
        Task {
            do {
                _ = try await serverManager.forkFromMessage(
                    message,
                    approvalPolicy: appState.approvalPolicy,
                    sandboxMode: appState.sandboxMode
                )
                if let nextCwd = serverManager.activeThread?.cwd, !nextCwd.isEmpty {
                    workDir = nextCwd
                    appState.currentCwd = nextCwd
                }
            } catch {
                messageActionError = error.localizedDescription
            }
        }
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
    let onEditUserMessage: (ChatMessage) -> Void
    let onForkFromUserMessage: (ChatMessage) -> Void
    @State private var pendingScrollWorkItem: DispatchWorkItem?

    private var messageActionsDisabled: Bool {
        if case .thinking = threadStatus {
            return true
        }
        return false
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(messages) { message in
                        EquatableMessageBubble(
                            message: message,
                            messageActionsDisabled: messageActionsDisabled,
                            onEditUserMessage: onEditUserMessage,
                            onForkFromUserMessage: onForkFromUserMessage
                        )
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
    let messageActionsDisabled: Bool
    let onEditUserMessage: (ChatMessage) -> Void
    let onForkFromUserMessage: (ChatMessage) -> Void

    static func == (lhs: EquatableMessageBubble, rhs: EquatableMessageBubble) -> Bool {
        lhs.message.id == rhs.message.id &&
        lhs.message.role == rhs.message.role &&
        lhs.message.text == rhs.message.text &&
        lhs.message.images.count == rhs.message.images.count &&
        lhs.messageActionsDisabled == rhs.messageActionsDisabled
    }

    var body: some View {
        MessageBubbleView(
            message: message,
            actionsDisabled: messageActionsDisabled,
            onEditUserMessage: onEditUserMessage,
            onForkFromUserMessage: onForkFromUserMessage
        )
    }
}

private struct ConversationInputBar: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    let onSend: (String, [SkillMentionSelection]) -> Void
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
    @State private var showSkillPopup = false
    @State private var activeDollarToken: ComposerTokenContext?
    @State private var fileSearchLoading = false
    @State private var fileSearchError: String?
    @State private var fileSuggestions: [FuzzyFileSearchResult] = []
    @State private var fileSearchGeneration = 0
    @State private var fileSearchTask: Task<Void, Never>?
    @State private var popupRefreshTask: Task<Void, Never>?
    @State private var showModelSelector = false
    @State private var showPermissionsSheet = false
    @State private var showExperimentalSheet = false
    @State private var showSkillsSheet = false
    @State private var showRenamePrompt = false
    @State private var renameCurrentThreadTitle = ""
    @State private var renameDraft = ""
    @State private var slashErrorMessage: String?
    @State private var experimentalFeatures: [ExperimentalFeature] = []
    @State private var experimentalFeaturesLoading = false
    @State private var skills: [SkillMetadata] = []
    @State private var skillsLoading = false
    @State private var mentionSkillPathsByName: [String: String] = [:]
    @State private var hasAttemptedSkillMentionLoad = false

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
            composerRow
        }
        .overlay(alignment: .bottom) {
            if showSlashPopup {
                slashSuggestionPopup
                    .padding(.bottom, 56)
            } else if showFilePopup {
                fileSuggestionPopup
                    .padding(.bottom, 56)
            } else if showSkillPopup {
                skillSuggestionPopup
                    .padding(.bottom, 56)
            }
        }
        .confirmationDialog("Attach", isPresented: $showAttachMenu) {
            Button("Photo Library") { showPhotoPicker = true }
            Button("Take Photo") { showCamera = true }
        }
        .onChange(of: inputText) { _, next in
            scheduleComposerPopupRefresh(for: next)
        }
        .onChange(of: serverManager.composerPrefillRequest?.id) { _, _ in
            guard let prefill = serverManager.composerPrefillRequest else { return }
            inputText = prefill.text
            attachedImage = nil
            hideComposerPopups()
            inputFocused.wrappedValue = true
        }
        .onDisappear {
            popupRefreshTask?.cancel()
            popupRefreshTask = nil
            fileSearchTask?.cancel()
            fileSearchTask = nil
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
                                        .font(LitterFont.monospaced(.subheadline))
                                    Spacer()
                                    if preset.approvalPolicy == appState.approvalPolicy && preset.sandboxMode == appState.sandboxMode {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(LitterTheme.accent)
                                    }
                                }
                                Text(preset.description)
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .font(LitterFont.monospaced(.caption))
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
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(LitterTheme.textMuted)
                    } else {
                        List {
                            ForEach(Array(experimentalFeatures.enumerated()), id: \.element.id) { _, feature in
                                HStack(alignment: .top, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(feature.displayName ?? feature.name)
                                            .font(LitterFont.monospaced(.subheadline))
                                            .foregroundColor(.white)
                                        Text(feature.description ?? feature.stage)
                                            .font(LitterFont.monospaced(.caption))
                                            .foregroundColor(LitterTheme.textSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    Toggle(
                                        "",
                                        isOn: Binding(
                                            get: { isExperimentalFeatureEnabled(feature.id, fallback: feature.enabled) },
                                            set: { value in
                                                Task { await setExperimentalFeature(named: feature.name, enabled: value) }
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
                            .font(LitterFont.monospaced(.footnote))
                            .foregroundColor(LitterTheme.textMuted)
                    } else {
                        List {
                            ForEach(skills) { skill in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(skill.name)
                                            .font(LitterFont.monospaced(.subheadline))
                                            .foregroundColor(.white)
                                        Spacer()
                                        if skill.enabled {
                                            Text("enabled")
                                                .font(LitterFont.monospaced(.caption2))
                                                .foregroundColor(LitterTheme.accent)
                                        }
                                    }
                                    Text(skill.description)
                                        .font(LitterFont.monospaced(.caption))
                                        .foregroundColor(LitterTheme.textSecondary)
                                    Text(skill.path)
                                        .font(LitterFont.monospaced(.caption2))
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
        .alert("Rename Thread", isPresented: Binding(
            get: { showRenamePrompt },
            set: { isPresented in
                showRenamePrompt = isPresented
                if !isPresented {
                    renameCurrentThreadTitle = ""
                    renameDraft = ""
                }
            }
        )) {
            TextField("New thread title", text: $renameDraft)
            Button("Cancel", role: .cancel) {
                showRenamePrompt = false
            }
            Button("Rename") {
                let nextName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nextName.isEmpty else { return }
                Task { await renameThread(nextName) }
            }
        } message: {
            Text("Current thread title:\n\(renameCurrentThreadTitle)")
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

    private var composerRow: some View {
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
                        let skillMentions = collectSkillMentionsForSubmission(text)
                        onSend(text, skillMentions)
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

    private var slashSuggestionPopup: some View {
        suggestionPopup {
            ForEach(Array(slashSuggestions.enumerated()), id: \.element.rawValue) { index, command in
                VStack(spacing: 0) {
                    Button {
                        applySlashSuggestion(command)
                    } label: {
                        HStack(spacing: 10) {
                            Text("/\(command.rawValue)")
                                .font(LitterFont.monospaced(.body))
                                .foregroundColor(Color(hex: "#6EA676"))
                            Text(command.description)
                                .font(LitterFont.monospaced(.body))
                                .foregroundColor(LitterTheme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    Divider()
                        .background(LitterTheme.border)
                        .opacity(index < slashSuggestions.count - 1 ? 1 : 0)
                }
            }
        }
    }

    @ViewBuilder
    private var fileSuggestionPopup: some View {
        suggestionPopup {
            if fileSearchLoading {
                Text("Searching files...")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if let fileSearchError, !fileSearchError.isEmpty {
                Text(fileSearchError)
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if fileSuggestions.isEmpty {
                Text("No matches")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(fileSuggestions.prefix(8).enumerated()), id: \.element.id) { index, suggestion in
                    VStack(spacing: 0) {
                        Button {
                            applyFileSuggestion(suggestion)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .font(.system(.caption))
                                    .foregroundColor(LitterTheme.textSecondary)
                                Text(suggestion.path)
                                    .font(LitterFont.monospaced(.footnote))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(LitterTheme.border)
                            .opacity(index < min(fileSuggestions.count, 8) - 1 ? 1 : 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var skillSuggestionPopup: some View {
        suggestionPopup {
            if skillsLoading && skillSuggestions.isEmpty {
                Text("Loading skills...")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else if skillSuggestions.isEmpty {
                Text("No skills found")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(skillSuggestions.prefix(8).enumerated()), id: \.element.id) { index, skill in
                    VStack(spacing: 0) {
                        Button {
                            applySkillSuggestion(skill)
                        } label: {
                            HStack(spacing: 8) {
                                Text("$\(skill.name)")
                                    .font(LitterFont.monospaced(.footnote))
                                    .foregroundColor(Color(hex: "#6EA676"))
                                Text(skill.description)
                                    .font(LitterFont.monospaced(.footnote))
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                        }
                        .buttonStyle(.plain)
                        Divider()
                            .background(LitterTheme.border)
                            .opacity(index < min(skillSuggestions.count, 8) - 1 ? 1 : 0)
                    }
                }
            }
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

    private func clearFileSearchState(incrementGeneration: Bool = true) {
        let hadTask = fileSearchTask != nil
        fileSearchTask?.cancel()
        fileSearchTask = nil
        if incrementGeneration && (hadTask || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty) {
            fileSearchGeneration += 1
        }
        if fileSearchLoading {
            fileSearchLoading = false
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }
    }

    private func hideComposerPopups() {
        popupRefreshTask?.cancel()
        popupRefreshTask = nil
        if showSlashPopup {
            showSlashPopup = false
        }
        if activeSlashToken != nil {
            activeSlashToken = nil
        }
        if !slashSuggestions.isEmpty {
            slashSuggestions = []
        }
        if showFilePopup {
            showFilePopup = false
        }
        if activeAtToken != nil {
            activeAtToken = nil
        }
        if showSkillPopup {
            showSkillPopup = false
        }
        if activeDollarToken != nil {
            activeDollarToken = nil
        }
        clearFileSearchState()
    }

    private func startFileSearch(_ query: String) {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        let requestId = fileSearchGeneration + 1
        fileSearchGeneration = requestId
        if !fileSearchLoading {
            fileSearchLoading = true
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }

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

    private func scheduleComposerPopupRefresh(for nextText: String) {
        popupRefreshTask?.cancel()
        popupRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            refreshComposerPopups(for: nextText)
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
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if showSkillPopup {
                showSkillPopup = false
            }
            if activeDollarToken != nil {
                activeDollarToken = nil
            }
            if !showFilePopup {
                showFilePopup = true
            }
            if activeAtToken != atToken {
                activeAtToken = atToken
                startFileSearch(atToken.value)
            }
            return
        }

        if activeAtToken != nil || showFilePopup || fileSearchTask != nil || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty {
            activeAtToken = nil
            if showFilePopup {
                showFilePopup = false
            }
            clearFileSearchState()
        }

        if let dollarToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "$",
            allowEmpty: true
        ), isMentionQueryValid(dollarToken.value) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if !showSkillPopup {
                showSkillPopup = true
            }
            if activeDollarToken != dollarToken {
                activeDollarToken = dollarToken
            }
            if !hasAttemptedSkillMentionLoad && !skillsLoading {
                hasAttemptedSkillMentionLoad = true
                Task { await loadSkills(showErrors: false) }
            }
            return
        }

        if activeDollarToken != nil || showSkillPopup {
            activeDollarToken = nil
            if showSkillPopup {
                showSkillPopup = false
            }
        }

        guard let slashToken = currentSlashQueryContext(text: nextText, cursor: cursor) else {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            return
        }

        if activeSlashToken != slashToken {
            activeSlashToken = slashToken
        }
        let suggestions = filterSlashCommands(slashToken.query)
        if slashSuggestions != suggestions {
            slashSuggestions = suggestions
        }
        let shouldShow = !suggestions.isEmpty
        if showSlashPopup != shouldShow {
            showSlashPopup = shouldShow
        }
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
                let currentTitle = serverManager.activeThread?.preview.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                renameCurrentThreadTitle = currentTitle.isEmpty ? "Untitled thread" : currentTitle
                renameDraft = ""
                showRenamePrompt = true
            } else {
                Task { await renameThread(initialName) }
            }
        case .new:
            appState.showServerPicker = true
        case .fork:
            Task { await forkConversation() }
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
            renameCurrentThreadTitle = ""
            renameDraft = ""
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func forkConversation() async {
        do {
            _ = try await serverManager.forkActiveThread(
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
            if let nextCwd = serverManager.activeThread?.cwd, !nextCwd.isEmpty {
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
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

    private func isExperimentalFeatureEnabled(_ featureId: String, fallback: Bool) -> Bool {
        experimentalFeatures.first(where: { $0.id == featureId })?.enabled ?? fallback
    }

    private func setExperimentalFeature(named featureName: String, enabled: Bool) async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            slashErrorMessage = "Not connected to a server"
            return
        }
        guard let currentIndex = experimentalFeatures.firstIndex(where: { $0.name == featureName }) else {
            return
        }
        let currentFeature = experimentalFeatures[currentIndex]
        if currentFeature.enabled != enabled {
            experimentalFeatures[currentIndex] = ExperimentalFeature(
                name: currentFeature.name,
                stage: currentFeature.stage,
                displayName: currentFeature.displayName,
                description: currentFeature.description,
                announcement: currentFeature.announcement,
                enabled: enabled,
                defaultEnabled: currentFeature.defaultEnabled
            )
        }
        do {
            _ = try await conn.writeConfigValue(keyPath: "features.\(featureName)", value: enabled)
        } catch {
            slashErrorMessage = error.localizedDescription
            if let rollbackIndex = experimentalFeatures.firstIndex(where: { $0.name == currentFeature.name }) {
                experimentalFeatures[rollbackIndex] = ExperimentalFeature(
                    name: currentFeature.name,
                    stage: currentFeature.stage,
                    displayName: currentFeature.displayName,
                    description: currentFeature.description,
                    announcement: currentFeature.announcement,
                    enabled: currentFeature.enabled,
                    defaultEnabled: currentFeature.defaultEnabled
                )
            }
        }
    }

    private func loadSkills(forceReload: Bool = false) async {
        await loadSkills(forceReload: forceReload, showErrors: true)
    }

    private func loadSkills(forceReload: Bool = false, showErrors: Bool) async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            skills = []
            mentionSkillPathsByName = [:]
            if showErrors {
                slashErrorMessage = "Not connected to a server"
            }
            return
        }
        skillsLoading = true
        defer { skillsLoading = false }
        do {
            let response = try await conn.listSkills(cwds: [workDir], forceReload: forceReload)
            let loadedSkills = response.data.flatMap(\.skills).sorted { $0.name.lowercased() < $1.name.lowercased() }
            skills = loadedSkills
            let validPaths = Set(loadedSkills.map(\.path))
            mentionSkillPathsByName = mentionSkillPathsByName.filter { _, path in validPaths.contains(path) }
        } catch {
            if showErrors {
                slashErrorMessage = error.localizedDescription
            }
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

    private var skillSuggestions: [SkillMetadata] {
        guard let token = activeDollarToken else { return [] }
        return filterSkillSuggestions(token.value)
    }

    private func filterSkillSuggestions(_ query: String) -> [SkillMetadata] {
        guard !skills.isEmpty else { return [] }
        guard !query.isEmpty else { return skills.sorted { lhs, rhs in lhs.name.lowercased() < rhs.name.lowercased() } }
        return skills
            .compactMap { skill -> (SkillMetadata, Int)? in
                let scoreFromName = fuzzyScore(candidate: skill.name, query: query)
                let scoreFromDescription = fuzzyScore(candidate: skill.description, query: query)
                let best = max(scoreFromName ?? Int.min, scoreFromDescription ?? Int.min)
                guard best != Int.min else { return nil }
                return (skill, best)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
            .map(\.0)
    }

    private func applySkillSuggestion(_ skill: SkillMetadata) {
        guard let token = activeDollarToken else { return }
        let replacement = "$\(skill.name) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        mentionSkillPathsByName[skill.name.lowercased()] = skill.path
        showSkillPopup = false
        activeDollarToken = nil
    }

    private func collectSkillMentionsForSubmission(_ text: String) -> [SkillMentionSelection] {
        guard !skills.isEmpty else { return [] }
        let mentionNames = extractMentionNames(text)
        guard !mentionNames.isEmpty else { return [] }

        let skillsByName = Dictionary(grouping: skills, by: { $0.name.lowercased() })
        let skillsByPath = Dictionary(grouping: skills, by: \.path)
        var seenPaths = Set<String>()
        var resolved: [SkillMentionSelection] = []

        for mentionName in mentionNames {
            let normalizedName = mentionName.lowercased()
            if let selectedPath = mentionSkillPathsByName[normalizedName], !selectedPath.isEmpty {
                if let selectedSkill = skillsByPath[selectedPath]?.first {
                    guard seenPaths.insert(selectedPath).inserted else { continue }
                    resolved.append(SkillMentionSelection(name: selectedSkill.name, path: selectedPath))
                    continue
                }
                mentionSkillPathsByName.removeValue(forKey: normalizedName)
            }

            guard let candidates = skillsByName[normalizedName], candidates.count == 1 else {
                continue
            }
            let match = candidates[0]
            guard seenPaths.insert(match.path).inserted else { continue }
            resolved.append(SkillMentionSelection(name: match.name, path: match.path))
        }
        return resolved
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
    case fork
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
        case .fork: return "fork"
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
        case .fork: return "fork the current conversation into a new session"
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
        case "fork": self = .fork
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

private func isMentionNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case UInt8(ascii: "a")...UInt8(ascii: "z"),
        UInt8(ascii: "A")...UInt8(ascii: "Z"),
        UInt8(ascii: "0")...UInt8(ascii: "9"),
        UInt8(ascii: "_"),
        UInt8(ascii: "-"):
        return true
    default:
        return false
    }
}

private func isMentionQueryValid(_ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    return query.utf8.allSatisfy(isMentionNameByte)
}

private func extractMentionNames(_ text: String) -> [String] {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty else { return [] }

    var mentions: [String] = []
    var index = 0
    while index < bytes.count {
        guard bytes[index] == UInt8(ascii: "$") else {
            index += 1
            continue
        }

        if index > 0, isMentionNameByte(bytes[index - 1]) {
            index += 1
            continue
        }

        let nameStart = index + 1
        guard nameStart < bytes.count, isMentionNameByte(bytes[nameStart]) else {
            index += 1
            continue
        }

        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, isMentionNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }

        if let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) {
            mentions.append(name)
        }
        index = nameEnd
    }

    return mentions
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
