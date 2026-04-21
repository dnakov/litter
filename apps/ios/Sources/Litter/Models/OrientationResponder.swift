import SwiftUI
import UIKit

/// Bridges device-orientation signals into explicit `UIWindowScene.requestGeometryUpdate`
/// calls. Two sources are observed:
///
///   1. `UIDevice.orientationDidChangeNotification` — the normal autorotation path
///      when iOS actually updates `UIDevice.current.orientation`.
///   2. Darwin notifications posted by KittyFarm (`com.sigkitten.kittyfarm.rotate.*`)
///      — a side-channel used because on iOS 26 the GSEvent device-orientation pipe
///      (PurpleWorkspacePort) is delivered to backboardd but no longer updates
///      `UIDevice.current.orientation`, so UIKit autorotation never fires. The
///      Darwin notification carries the target orientation in its name and
///      directly drives `requestGeometryUpdate`, bypassing autorotation entirely.
@MainActor
final class OrientationResponder {
    static let shared = OrientationResponder()

    private var uiKitObserver: NSObjectProtocol?
    private var darwinObservers: [CFNotificationName: UInt] = [:]

    private init() {}

    func start() {
        guard uiKitObserver == nil else { return }

        UIDevice.current.beginGeneratingDeviceOrientationNotifications()

        uiKitObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                let mask = Self.interfaceOrientationMask(for: UIDevice.current.orientation)
                OrientationResponder.shared.apply(mask: mask)
            }
        }

        registerDarwinObservers()
    }

    private func registerDarwinObservers() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()

        let bindings: [(String, UIInterfaceOrientationMask)] = [
            ("com.sigkitten.kittyfarm.rotate.portrait",              .portrait),
            ("com.sigkitten.kittyfarm.rotate.portrait-upside-down",  .portraitUpsideDown),
            ("com.sigkitten.kittyfarm.rotate.landscape-left",        .landscapeRight),
            ("com.sigkitten.kittyfarm.rotate.landscape-right",       .landscapeLeft),
        ]

        for (name, mask) in bindings {
            let cfName = CFNotificationName(name as CFString)
            let rawMask = UInt(mask.rawValue)
            CFNotificationCenterAddObserver(
                center,
                UnsafeRawPointer(bitPattern: rawMask),
                Self.darwinCallback,
                name as CFString,
                nil,
                .deliverImmediately
            )
            darwinObservers[cfName] = rawMask
        }
    }

    fileprivate func handleDarwinRotation(maskRawValue: UInt) {
        let mask = UIInterfaceOrientationMask(rawValue: maskRawValue)
        Task { @MainActor in
            self.apply(mask: mask)
        }
    }

    private func apply(mask: UIInterfaceOrientationMask?) {
        guard let mask else { return }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            windowScene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }

    private static func interfaceOrientationMask(for device: UIDeviceOrientation) -> UIInterfaceOrientationMask? {
        // UIDevice uses device-frame semantics; UIInterface uses status-bar-up
        // semantics, so landscape is swapped between the two enums.
        switch device {
        case .portrait:            return .portrait
        case .portraitUpsideDown:  return .portraitUpsideDown
        case .landscapeLeft:       return .landscapeRight
        case .landscapeRight:      return .landscapeLeft
        default:                   return nil
        }
    }

    private static let darwinCallback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let rawMask = UInt(bitPattern: observer)
        Task { @MainActor in
            OrientationResponder.shared.handleDarwinRotation(maskRawValue: rawMask)
        }
    }
}
