import SwiftUI

enum ConversationComposerPopupState {
    case none
    case slash([ComposerSlashCommand])
    case file(loading: Bool, error: String?, suggestions: [FileSearchResult])
    case skill(loading: Bool, suggestions: [SkillMetadata])
}

struct ConversationComposerPopupOverlayView: View {
    let state: ConversationComposerPopupState
    let onApplySlashSuggestion: (ComposerSlashCommand) -> Void
    let onApplyFileSuggestion: (FileSearchResult) -> Void
    let onApplySkillSuggestion: (SkillMetadata) -> Void

    var body: some View {
        switch state {
        case .none:
            EmptyView()

        case .slash(let suggestions):
            suggestionPopup {
                let indexedSuggestions = Array(suggestions.enumerated())
                ForEach(indexedSuggestions, id: \.offset) { item in
                    let index = item.offset
                    let command = item.element
                    VStack(spacing: 0) {
                        Button {
                            onApplySlashSuggestion(command)
                        } label: {
                            HStack(spacing: 10) {
                                Text("/\(command.rawValue)")
                                    .litterFont(.body)
                                    .foregroundColor(LitterTheme.success)
                                Text(command.description)
                                    .litterFont(.body)
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
                            .opacity(index < suggestions.count - 1 ? 1 : 0)
                    }
                }
            }

        case .file(let loading, let error, let suggestions):
            suggestionPopup {
                if loading {
                    popupStateText("Searching files...")
                } else if let error, !error.isEmpty {
                    popupStateText(error, color: .red)
                } else if suggestions.isEmpty {
                    popupStateText("No matches")
                } else {
                    let indexedSuggestions = Array(Array(suggestions.prefix(8)).enumerated())
                    ForEach(indexedSuggestions, id: \.offset) { item in
                        let index = item.offset
                        let suggestion = item.element
                        VStack(spacing: 0) {
                            Button {
                                onApplyFileSuggestion(suggestion)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "folder")
                                        .litterFont(.caption)
                                        .foregroundColor(LitterTheme.textSecondary)
                                    Text(suggestion.path)
                                        .litterFont(.footnote)
                                        .foregroundColor(LitterTheme.textPrimary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                            }
                            .buttonStyle(.plain)

                            Divider()
                                .background(LitterTheme.border)
                                .opacity(index < indexedSuggestions.count - 1 ? 1 : 0)
                        }
                    }
                }
            }

        case .skill(let loading, let suggestions):
            suggestionPopup {
                if loading && suggestions.isEmpty {
                    popupStateText("Loading skills...")
                } else if suggestions.isEmpty {
                    popupStateText("No skills found")
                } else {
                    let indexedSuggestions = Array(Array(suggestions.prefix(8)).enumerated())
                    ForEach(indexedSuggestions, id: \.offset) { item in
                        let index = item.offset
                        let skill = item.element
                        VStack(spacing: 0) {
                            Button {
                                onApplySkillSuggestion(skill)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("$\(skill.name)")
                                        .litterFont(.footnote)
                                        .foregroundColor(LitterTheme.success)
                                    Text(skill.description)
                                        .litterFont(.footnote)
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
                                .opacity(index < indexedSuggestions.count - 1 ? 1 : 0)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func popupStateText(_ text: String, color: Color = LitterTheme.textSecondary) -> some View {
        Text(text)
            .litterFont(.footnote)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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
        .padding(.bottom, 56)
    }
}
