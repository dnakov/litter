import SwiftUI

struct ExperimentalFeaturesView: View {
    @State private var toggleStates: [LitterFeature: Bool] = {
        var states: [LitterFeature: Bool] = [:]
        for feature in LitterFeature.allCases {
            states[feature] = ExperimentalFeatures.shared.isEnabled(feature)
        }
        return states
    }()

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            Form {
                Section {
                    ForEach(LitterFeature.allCases) { feature in
                        Toggle(isOn: binding(for: feature)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.displayName)
                                    .font(LitterFont.styled(.subheadline))
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text(feature.description)
                                    .font(LitterFont.styled(.caption))
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                        .tint(LitterTheme.accentStrong)
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                } header: {
                    Text("Features")
                        .foregroundColor(LitterTheme.textSecondary)
                } footer: {
                    Text("Experimental features may be unstable or change without notice.")
                        .foregroundColor(LitterTheme.textMuted)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for feature: LitterFeature) -> Binding<Bool> {
        Binding(
            get: { toggleStates[feature] ?? feature.defaultEnabled },
            set: { newValue in
                toggleStates[feature] = newValue
                ExperimentalFeatures.shared.setEnabled(feature, newValue)
            }
        )
    }
}

#if DEBUG
#Preview("Experimental Features") {
    NavigationStack {
        ExperimentalFeaturesView()
    }
}
#endif
