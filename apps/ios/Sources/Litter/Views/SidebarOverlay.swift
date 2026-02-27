import SwiftUI

struct SidebarOverlay: View {
    @EnvironmentObject var appState: AppState
    @Binding var dragOffset: CGFloat

    static let sidebarWidth: CGFloat = 300
    private let animation = Animation.spring(response: 0.3, dampingFraction: 0.86)

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
                .opacity(0.42 * revealProgress)
                .ignoresSafeArea()
                .allowsHitTesting(revealProgress > 0.01)
                .onTapGesture {
                    closeSidebar()
                }

            SessionSidebarView()
                .frame(width: Self.sidebarWidth)
                .offset(x: panelOffset)
                .shadow(color: .black.opacity(0.35), radius: 20, x: 6, y: 0)
                .gesture(
                    DragGesture(minimumDistance: 6, coordinateSpace: .local)
                        .onChanged { value in
                            guard appState.sidebarOpen else { return }
                            dragOffset = min(0, value.translation.width)
                        }
                        .onEnded { value in
                            guard appState.sidebarOpen else { return }
                            let shouldClose = value.translation.width < -Self.sidebarWidth * 0.33 ||
                                value.predictedEndTranslation.width < -Self.sidebarWidth * 0.5
                            withAnimation(animation) {
                                appState.sidebarOpen = !shouldClose
                                dragOffset = 0
                            }
                        }
                )
        }
        .allowsHitTesting(appState.sidebarOpen || revealProgress > 0.01)
        .animation(animation, value: appState.sidebarOpen)
        .animation(animation, value: dragOffset)
    }

    private var panelOffset: CGFloat {
        if appState.sidebarOpen {
            return min(0, max(-Self.sidebarWidth, dragOffset))
        }
        return -Self.sidebarWidth
    }

    private var revealProgress: CGFloat {
        guard appState.sidebarOpen else { return 0 }
        return min(1, max(0, 1 + (dragOffset / Self.sidebarWidth)))
    }

    private func closeSidebar() {
        withAnimation(animation) {
            appState.sidebarOpen = false
            dragOffset = 0
        }
    }
}
