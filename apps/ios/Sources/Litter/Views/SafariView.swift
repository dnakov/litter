import SwiftUI
import SafariServices
import UIKit

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    var onDismiss: (() -> Void)?

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let vc = SFSafariViewController(url: url)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDismiss: onDismiss) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDismiss: (() -> Void)?
        init(onDismiss: (() -> Void)?) { self.onDismiss = onDismiss }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDismiss?()
        }
    }
}
