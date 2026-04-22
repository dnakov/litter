#if targetEnvironment(macCatalyst)
import SwiftUI

struct HomeVoiceOrbButton: View {
    let session: VoiceSessionState?
    let isAvailable: Bool
    let isStarting: Bool
    let action: () -> Void

    var body: some View {
        EmptyView()
    }
}

struct RealtimeVoiceScreen: View {
    let threadKey: ThreadKey
    let onEnd: () -> Void
    let onToggleSpeaker: () -> Void

    var body: some View {
        EmptyView()
    }
}

struct InlineVoiceButton: View {
    let session: VoiceSessionState?
    let action: () -> Void

    var body: some View {
        EmptyView()
    }
}
#endif
