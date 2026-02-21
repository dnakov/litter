import SwiftUI

struct SidebarOverlay: View {
    @EnvironmentObject var appState: AppState
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .leading) {
            if appState.sidebarOpen {
                Color.black.opacity(0.5)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            appState.sidebarOpen = false
                        }
                    }

                SessionSidebarView()
                    .frame(width: 300)
                    .offset(x: dragOffset)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.width < 0 {
                                    dragOffset = value.translation.width
                                }
                            }
                            .onEnded { value in
                                if value.translation.width < -80 {
                                    withAnimation(.easeInOut(duration: 0.25)) {
                                        appState.sidebarOpen = false
                                    }
                                }
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    dragOffset = 0
                                }
                            }
                    )
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: appState.sidebarOpen)
    }
}
