import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class StableSafeAreaInsets {
    private(set) var bottomInset: CGFloat = 0

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    func start(fallback: CGFloat) {
        if bottomInset <= 0, fallback > 0 {
            bottomInset = fallback
        }

        guard !didStart else {
            refresh(fallback: fallback)
            return
        }

        didStart = true
        let center = NotificationCenter.default
        let observedNames: [Notification.Name] = [
            UIApplication.didBecomeActiveNotification,
            UIDevice.orientationDidChangeNotification,
            UIWindow.didBecomeKeyNotification,
            UIWindow.didResignKeyNotification
        ]

        observers = observedNames.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.refresh(fallback: self.bottomInset > 0 ? self.bottomInset : fallback)
                }
            }
        }

        refresh(fallback: fallback)
    }

    func refresh(fallback: CGFloat) {
        let keyWindowInset = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
        let resolvedInset = keyWindowInset > 0 ? keyWindowInset : fallback
        if resolvedInset > 0, abs(bottomInset - resolvedInset) > 0.5 {
            bottomInset = resolvedInset
        }
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }
}
