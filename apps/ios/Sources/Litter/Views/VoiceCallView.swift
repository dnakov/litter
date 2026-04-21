import SwiftUI

struct VoiceCallView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(VoiceRuntimeController.self) private var voiceRuntime
    @AppStorage("conversationTextSizeStep") private var conversationTextSizeStep = VoiceConversationTextSize.medium.rawValue
    @State private var screenModel = ConversationScreenModel()
#if DEBUG
    @State private var showDebugSheet = false
#endif

    private var textScale: CGFloat {
        VoiceConversationTextSize.clamped(rawValue: conversationTextSizeStep).scale
    }

    private var voiceContext: VoiceCallContext? {
        guard let session = voiceRuntime.activeVoiceSession,
              let thread = appModel.snapshot?.threadSnapshot(for: session.threadKey) else {
            return nil
        }
        return VoiceCallContext(session: session, thread: thread)
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient
                .ignoresSafeArea()

            if let context = voiceContext {
                VoiceCreditsTranscriptView(
                    items: screenModel.transcript.items,
                    threadStatus: screenModel.transcript.threadStatus,
                    session: context.session,
                    textScale: textScale
                )
                .safeAreaInset(edge: .top, spacing: 0) {
                    topBar(context.session)
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    bottomBar(context.session)
                }
            } else {
                ProgressView()
                    .tint(LitterTheme.accent)
            }
        }
        .interactiveDismissDisabled(true)
        .task(id: voiceContext?.session.id) {
            bindModel()
        }
#if DEBUG
        .sheet(isPresented: $showDebugSheet) {
            if let session = voiceRuntime.activeVoiceSession {
                VoiceCallDebugSheet(session: session)
            }
        }
#endif
    }

    private func bindModel() {
        guard let context = voiceContext else { return }
        screenModel.bind(
            thread: context.thread,
            appModel: appModel,
            agentDirectoryVersion: appModel.snapshot?.agentDirectoryVersion ?? 0
        )
    }

    private func topBar(_ session: VoiceSessionState) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                CompactSpeakerIndicator(
                    title: "You",
                    level: visualWaveformLevel(
                        session.inputLevel,
                        active: session.phase == .listening || session.inputLevel > 0.01
                    ),
                    active: session.phase == .listening || session.inputLevel > 0.01,
                    tint: LitterTheme.accent
                )

                CompactSpeakerIndicator(
                    title: "Codex",
                    level: visualWaveformLevel(
                        session.outputLevel,
                        active: session.phase == .speaking || session.isSpeaking
                    ),
                    active: session.phase == .speaking || session.isSpeaking,
                    tint: LitterTheme.warning
                )

                Spacer(minLength: 0)

                routeButton(session)

#if DEBUG
                Button {
                    showDebugSheet = true
                } label: {
                    Image(systemName: "ladybug.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(LitterTheme.surface.opacity(0.92)))
                }
                .buttonStyle(.plain)
#endif
            }

            HStack(spacing: 8) {
                Text(session.threadTitle)
                    .font(LitterFont.styled(.caption, weight: .semibold))
                    .foregroundColor(LitterTheme.textPrimary)
                    .lineLimit(1)

                Text("•")
                    .font(LitterFont.styled(.caption))
                    .foregroundColor(LitterTheme.textMuted)

                Text(session.phase.displayTitle)
                    .font(LitterFont.monospaced(.caption, weight: .semibold))
                    .foregroundColor(phaseColor(session.phase))

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(
            LinearGradient(
                colors: [Color.black.opacity(0.9), Color.black.opacity(0.52), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func bottomBar(_ session: VoiceSessionState) -> some View {
        HStack {
            Spacer()

            Button(role: .destructive) {
                Task { await voiceRuntime.stopActiveVoiceSession() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "phone.down.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text(session.phase == .error ? "Close" : "Hang Up")
                        .font(LitterFont.styled(.callout, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Capsule().fill(LitterTheme.danger))
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [.clear, Color.black.opacity(0.58), Color.black.opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func routeButton(_ session: VoiceSessionState) -> some View {
        Button {
            Task { try? await voiceRuntime.toggleActiveVoiceSessionSpeaker() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: routeIcon(session.route))
                    .font(.system(size: 12, weight: .semibold))
                Text(session.route.label)
                    .font(LitterFont.styled(.caption, weight: .semibold))
            }
            .foregroundColor(session.route.supportsSpeakerToggle ? LitterTheme.textPrimary : LitterTheme.textMuted)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Capsule().fill(LitterTheme.surface.opacity(0.92)))
        }
        .buttonStyle(.plain)
        .disabled(!session.route.supportsSpeakerToggle)
    }

    private func visualWaveformLevel(_ rawLevel: Float, active: Bool) -> Float {
        let scaled = min(1, rawLevel * 3.1)
        return active ? max(0.08, scaled) : max(0, scaled)
    }

    private func phaseColor(_ phase: VoiceSessionPhase) -> Color {
        switch phase {
        case .connecting, .thinking, .handoff:
            return LitterTheme.warning
        case .listening, .speaking:
            return LitterTheme.accent
        case .error:
            return LitterTheme.danger
        }
    }

    private func routeIcon(_ route: VoiceSessionAudioRoute) -> String {
        switch route {
        case .speaker:
            return "speaker.wave.3.fill"
        case .receiver:
            return "phone.fill"
        case .headphones:
            return "headphones"
        case .bluetooth:
            return "dot.radiowaves.left.and.right"
        case .airPlay:
            return "airplayaudio"
        case .carPlay:
            return "car.fill"
        case .unknown:
            return "speaker.wave.2.fill"
        }
    }
}

private struct VoiceCallContext {
    let session: VoiceSessionState
    let thread: AppThreadSnapshot
}

private enum VoiceConversationTextSize: Int {
    case xSmall = 0
    case small = 1
    case medium = 2
    case large = 3
    case xLarge = 4

    var scale: CGFloat {
        switch self {
        case .xSmall: 0.86
        case .small: 0.93
        case .medium: 1.0
        case .large: 1.1
        case .xLarge: 1.22
        }
    }

    static func clamped(rawValue: Int) -> VoiceConversationTextSize {
        let bounded = min(max(rawValue, xSmall.rawValue), xLarge.rawValue)
        return VoiceConversationTextSize(rawValue: bounded) ?? .medium
    }
}

private struct CompactSpeakerIndicator: View {
    let title: String
    let level: Float
    let active: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(active ? tint : LitterTheme.textMuted.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(LitterFont.styled(.caption, weight: .semibold))
                    .foregroundColor(active ? LitterTheme.textPrimary : LitterTheme.textSecondary)
            }

            AudioWaveformView(level: level, tint: tint)
                .frame(width: 86, height: 18)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Capsule().fill(LitterTheme.surface.opacity(0.92)))
    }
}

private struct VoiceCreditsTranscriptView: View {
    let items: [ConversationItem]
    let threadStatus: ConversationStatus
    let session: VoiceSessionState
    let textScale: CGFloat

    private var entries: [VoiceTranscriptEntry] {
        var result = items.compactMap(VoiceTranscriptEntry.init)
        if let liveEntry = VoiceTranscriptEntry.live(from: session),
           result.last != liveEntry {
            result.append(liveEntry)
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(spacing: 26) {
                        if entries.isEmpty {
                            placeholder
                        } else {
                            ForEach(entries) { entry in
                                VoiceCreditsEntryRow(entry: entry, textScale: textScale)
                            }
                        }

                        if case .thinking = threadStatus {
                            Text("...")
                                .font(LitterFont.monospaced(.title3, weight: .semibold))
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.top, 36)
                    .padding(.bottom, 150)

                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .frame(maxWidth: .infinity)
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: 52)
                    Rectangle().fill(.black)
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: 68)
                }
                .ignoresSafeArea()
            }
            .onAppear {
                scrollToBottom(proxy, animated: false)
            }
            .onChange(of: entries) { _, _ in
                scrollToBottom(proxy, animated: true)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Text("Voice Transcript")
                .font(LitterFont.monospaced(.caption, weight: .semibold))
                .foregroundColor(LitterTheme.textMuted)
            Text("The live conversation, tool calls, and other text output will appear here.")
                .font(LitterFont.styled(.body, scale: textScale))
                .foregroundColor(LitterTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

private enum VoiceTranscriptEntryKind: Equatable {
    case user
    case assistant
    case liveUser
    case liveAssistant
    case reasoning
    case tool
    case note
    case error
    case system
}

private struct VoiceTranscriptEntry: Identifiable, Equatable {
    let id: String
    let kind: VoiceTranscriptEntryKind
    let title: String
    let body: String

    init(
        id: String,
        kind: VoiceTranscriptEntryKind,
        title: String,
        body: String
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
    }

    init?(_ item: ConversationItem) {
        switch item.content {
        case .user(let data):
            let body = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty && !data.images.isEmpty {
                self = VoiceTranscriptEntry(
                    id: item.id,
                    kind: .user,
                    title: "YOU",
                    body: "_Image omitted in voice transcript_"
                )
            } else if !body.isEmpty {
                self = VoiceTranscriptEntry(id: item.id, kind: .user, title: "YOU", body: body)
            } else {
                return nil
            }

        case .assistant(let data):
            let body = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let label = AgentLabelFormatter.format(
                nickname: data.agentNickname,
                role: data.agentRole
            ) ?? "CODEX"
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .assistant,
                title: label.uppercased(),
                body: body
            )

        case .codeReview(let data):
            guard let first = data.findings.first else { return nil }
            let body = ([first.title, first.body] + data.findings.dropFirst().map(\.title))
                .joined(separator: "\n\n")
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .assistant,
                title: "CODE REVIEW",
                body: body
            )

        case .reasoning(let data):
            let chunks = (data.summary + data.content)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !chunks.isEmpty else { return nil }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .reasoning,
                title: "REASONING",
                body: chunks.joined(separator: "\n\n")
            )

        case .todoList(let data):
            guard !data.steps.isEmpty else { return nil }
            let lines = data.steps.map { "[\(planStepLabel($0.status))] \($0.step)" }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "PLAN",
                body: lines.joined(separator: "\n")
            )

        case .proposedPlan(let data):
            let body = data.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            self = VoiceTranscriptEntry(id: item.id, kind: .tool, title: "PLAN", body: body)

        case .commandExecution(let data):
            let chunks = [data.command, data.status.displayLabel, data.output]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !chunks.isEmpty else { return nil }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "COMMAND",
                body: chunks.joined(separator: "\n\n")
            )

        case .fileChange(let data):
            var chunks = ["Status: \(data.status.displayLabel)"]
            let changeSummaries = data.changes.map { "\($0.kind.uppercased()) \($0.path)\n\($0.diff)" }
            chunks.append(contentsOf: changeSummaries)
            if let outputDelta = data.outputDelta?.trimmingCharacters(in: .whitespacesAndNewlines),
               !outputDelta.isEmpty {
                chunks.append(outputDelta)
            }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "FILE CHANGES",
                body: chunks.joined(separator: "\n\n")
            )

        case .turnDiff(let data):
            let body = data.diff.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            self = VoiceTranscriptEntry(id: item.id, kind: .tool, title: "DIFF", body: body)

        case .mcpToolCall(let data):
            var chunks = ["\(data.server) / \(data.tool)", "Status: \(data.status.displayLabel)"]
            if let summary = data.contentSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                chunks.append(summary)
            }
            if !data.progressMessages.isEmpty {
                chunks.append(data.progressMessages.joined(separator: "\n"))
            }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "MCP TOOL",
                body: chunks.joined(separator: "\n\n")
            )

        case .dynamicToolCall(let data):
            var chunks = [data.tool, "Status: \(data.status.displayLabel)"]
            if let summary = data.contentSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
               !summary.isEmpty {
                chunks.append(summary)
            }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "TOOL",
                body: chunks.joined(separator: "\n\n")
            )

        case .multiAgentAction(let data):
            var chunks = ["Tool: \(data.tool)", "Status: \(data.status.displayLabel)"]
            if let prompt = data.prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
               !prompt.isEmpty {
                chunks.append(prompt)
            }
            if !data.targets.isEmpty {
                chunks.append("Targets: \(data.targets.joined(separator: ", "))")
            }
            if !data.agentStates.isEmpty {
                let states = data.agentStates.map { "\($0.targetId): \($0.status)\($0.message.map { " - \($0)" } ?? "")" }
                chunks.append(states.joined(separator: "\n"))
            }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "COLLABORATION",
                body: chunks.joined(separator: "\n\n")
            )

        case .webSearch(let data):
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "WEB SEARCH",
                body: [data.query, data.actionJSON].compactMap { $0 }.joined(separator: "\n\n")
            )

        case .imageView(let data):
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "IMAGE VIEW",
                body: data.path
            )

        case .imageGeneration(let data):
            let statusWord: String = {
                switch data.status {
                case .completed: return "Completed"
                case .failed: return "Failed"
                default: return "Generating"
                }
            }()
            let body = [statusWord, data.revisedPrompt ?? ""]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "IMAGE GENERATION",
                body: body.isEmpty ? statusWord : body
            )

        case .widget(let data):
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .tool,
                title: "WIDGET",
                body: "Interactive widget rendered: \(data.widgetState.title)"
            )

        case .userInputResponse(let data):
            let chunks = data.questions.map { question in
                "\(question.header ?? question.id)\n\(question.question)\n\(question.answer)"
            }
            guard !chunks.isEmpty else { return nil }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .system,
                title: "USER INPUT",
                body: chunks.joined(separator: "\n\n")
            )

        case .divider(let kind):
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .system,
                title: "SYSTEM",
                body: Self.dividerText(kind)
            )

        case .error(let data):
            let parts = [data.message, data.details].compactMap { $0 }.filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .error,
                title: data.title.isEmpty ? "ERROR" : data.title.uppercased(),
                body: parts.joined(separator: "\n\n")
            )

        case .note(let data):
            let body = [data.title, data.body]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            guard !body.isEmpty else { return nil }
            self = VoiceTranscriptEntry(
                id: item.id,
                kind: .note,
                title: data.title.isEmpty ? "NOTE" : data.title.uppercased(),
                body: body
            )
        }
    }

    static func live(from session: VoiceSessionState) -> VoiceTranscriptEntry? {
        let text = session.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        let speaker = session.transcriptSpeaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? session.transcriptSpeaker!
            : (session.phase == .speaking ? "Codex" : "You")
        let kind: VoiceTranscriptEntryKind = speaker == "Codex" ? .liveAssistant : .liveUser
        let title = speaker == "Codex" ? "CODEX LIVE" : "YOU LIVE"
        return VoiceTranscriptEntry(
            id: "live-\(speaker.lowercased())",
            kind: kind,
            title: title,
            body: text
        )
    }

    private static func dividerText(_ kind: ConversationDividerKind) -> String {
        switch kind {
        case .contextCompaction(let isComplete):
            return isComplete ? "Context compaction completed." : "Context compaction in progress."
        case .modelRerouted(let fromModel, let toModel, let reason):
            return [fromModel, toModel, reason].compactMap { $0 }.joined(separator: " -> ")
        case .reviewEntered(let detail),
             .reviewExited(let detail),
             .workedFor(let detail):
            return detail
        case .generic(let title, let detail):
            return [title, detail].compactMap { $0 }.joined(separator: "\n\n")
        }
    }
}

private func planStepLabel(_ status: HydratedPlanStepStatus) -> String {
    switch status {
    case .pending:
        return "pending"
    case .inProgress:
        return "in_progress"
    case .completed:
        return "completed"
    }
}

private struct VoiceCreditsEntryRow: View {
    let entry: VoiceTranscriptEntry
    let textScale: CGFloat

    private var titleColor: Color {
        switch entry.kind {
        case .user, .liveUser:
            return LitterTheme.accent
        case .assistant, .liveAssistant:
            return LitterTheme.warning
        case .reasoning:
            return LitterTheme.textMuted
        case .tool, .note, .system:
            return LitterTheme.textSecondary
        case .error:
            return LitterTheme.danger
        }
    }

    private var bodyColor: Color {
        switch entry.kind {
        case .error:
            return LitterTheme.danger.opacity(0.92)
        case .reasoning:
            return LitterTheme.textSecondary
        default:
            return LitterTheme.textPrimary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.title)
                .font(LitterFont.monospaced(.caption, weight: .bold, scale: textScale))
                .foregroundColor(titleColor)

            Group {
                if entry.kind == .reasoning {
                    Text(verbatim: entry.body)
                        .italic()
                } else {
                    Text(verbatim: entry.body)
                }
            }
            .font(LitterFont.styled(.body, scale: textScale))
            .foregroundColor(bodyColor)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity)
        .opacity(entry.kind == .liveAssistant || entry.kind == .liveUser ? 0.94 : 1)
    }
}

#if DEBUG
private struct VoiceCallDebugSheet: View {
    let session: VoiceSessionState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(session.debugEntries) { entry in
                Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) \(entry.line)")
                    .font(LitterFont.monospaced(.caption2))
                    .foregroundColor(LitterTheme.textPrimary)
                    .textSelection(.enabled)
                    .listRowBackground(Color.black)
            }
            .scrollContentBackground(.hidden)
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .navigationTitle("Voice Debug")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
#endif
