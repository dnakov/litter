import SwiftUI

struct ExperimentalFeaturesView: View {
    @State private var experimentalFeatures = ExperimentalFeatures.shared
    @State private var debugSettings = DebugSettings.shared

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            Form {
                Section {
                    ForEach(LitterFeature.allCases) { feature in
                        Toggle(isOn: binding(for: feature)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(feature.displayName)
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text(feature.description)
                                    .litterFont(.caption)
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

                Section {
                    Toggle(isOn: Binding(
                        get: { debugSettings.enabled },
                        set: { debugSettings.enabled = $0 }
                    )) {
                        HStack(spacing: 10) {
                            Image(systemName: "ant")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Debug Mode")
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text("Show debug controls in conversations")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    }
                    .tint(LitterTheme.accent)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))

                    #if DEBUG
                    NavigationLink {
                        ProximityPairView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "wave.3.right")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Pair")
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text("Walk-up pairing with proximity + haptics")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                    #endif

                    #if !targetEnvironment(macCatalyst) && DEBUG
                    NavigationLink {
                        UWBDebugView()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("UWB Debug")
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                Text("Live distance & direction to a paired Mac")
                                    .litterFont(.caption)
                                    .foregroundColor(LitterTheme.textSecondary)
                            }
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                    #endif
                } header: {
                    Text("Debug")
                        .foregroundColor(LitterTheme.textSecondary)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Experimental")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func binding(for feature: LitterFeature) -> Binding<Bool> {
        Binding(
            get: { experimentalFeatures.isEnabled(feature) },
            set: { newValue in
                experimentalFeatures.setEnabled(feature, newValue)
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
