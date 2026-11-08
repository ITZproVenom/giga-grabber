import AppIntents
import Foundation
import Combine

@MainActor
final class PendingLinkRouter: ObservableObject {
    static let shared = PendingLinkRouter()
    @Published var pendingURL: URL?
    @Published var pendingAutoQueue = false

    func submit(_ url: URL, autoQueue: Bool) {
        UserDefaults.standard.set(url.absoluteString, forKey: "GigaGrabber.pendingLink")
        UserDefaults.standard.set(autoQueue, forKey: "GigaGrabber.pendingAutoQueue")
        pendingAutoQueue = autoQueue
        pendingURL = url
    }

    func consumePersistedLink() -> (URL, Bool)? {
        guard let raw = UserDefaults.standard.string(forKey: "GigaGrabber.pendingLink"),
              let url = URL(string: raw) else { return nil }
        let autoQueue = UserDefaults.standard.bool(forKey: "GigaGrabber.pendingAutoQueue")
        UserDefaults.standard.removeObject(forKey: "GigaGrabber.pendingLink")
        UserDefaults.standard.removeObject(forKey: "GigaGrabber.pendingAutoQueue")
        return (url, autoQueue)
    }
}

struct OpenMegaLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Download MEGA link"
    static var description = IntentDescription("Queue a public MEGA file or every file in a shared folder.")
    static var openAppWhenRun = true

    @Parameter(title: "MEGA link")
    var megaURL: URL

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            PendingLinkRouter.shared.submit(megaURL, autoQueue: true)
        }
        return .result()
    }
}

struct GigaGrabberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMegaLinkIntent(),
            phrases: [
                "Download a MEGA link with \(.applicationName)",
                "Send a MEGA link to \(.applicationName)"
            ],
            shortTitle: "Download MEGA link",
            systemImageName: "arrow.down.circle"
        )
    }
}
