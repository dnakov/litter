import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var sidebarOpen = false
    @Published var currentCwd = ""
    @Published var showServerPicker = false
    @Published var selectedModel = ""
    @Published var reasoningEffort = "medium"
}
