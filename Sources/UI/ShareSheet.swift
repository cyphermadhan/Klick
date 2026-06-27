import SwiftUI
import UIKit

/// SwiftUI wrapper around `UIActivityViewController` so we can present
/// the system share sheet from a `.sheet(isPresented:)` modifier.
///
/// Pass any `[Any]` of items — typically `[URL]` for invite links, which
/// renders Messages / Mail / AirDrop / Copy as targets and lets the OS
/// pick the right preview metadata automatically.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
