import SwiftUI
import HermesVoiceCore

/// The one call for the process. The screen can go away; the call keeps running behind the bar.
@MainActor
@Observable
final class VoiceCenter {
    static let shared = VoiceCenter()

    enum Mode { case hidden, full, minimized }

    private(set) var controller: LiveController?
    var mode: Mode = .hidden
    /// Drives the full-screen-to-bar clip. 0 is the call, 1 is the bar.
    var collapse: CGFloat = 0

    func open(store: Store, context: String, preview: Bool = false) {
        let controller = self.controller ?? LiveController(store: store)
        self.controller = controller
        collapse = 0
        mode = .full
        controller.start(context: context, preview: preview)
    }

    func expand() {
        guard controller != nil else { return }
        mode = .full
    }

    func minimize() {
        guard mode == .full else { return }
        mode = .minimized
    }

    func dismiss() {
        mode = .hidden
        collapse = 0
    }
}
