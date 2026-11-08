import AppIntents
import Foundation
import Combine

@MainActor
final class PendingLinkRouter: ObservableObject {
    static let shared = PendingLinkRouter()
    @Published var pendingURL: URL?

    func submit(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: "GigaGrabber.pendingLink")
        pendingURL = url
    }

    func consumePersistedLink() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: "GigaGrabber.pendingLink"),
              let url = URL(string: raw) else { return nil }
        UserDefaults.standard.removeObject(forKey: "GigaGrabber.pendingLink")
        return url
    }
}

struct OpenMegaLinkIntent: AppIntent {
    static var title: LocalizedStringResource = "Open MEGA link in Giga Grabber"
    static var description = IntentDescription("Send a public MEGA file or folder link to Giga Grabber.")
    static var openAppWhenRun = true

    @Parameter(title: "MEGA link")
    var megaURL: URL

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            PendingLinkRouter.shared.submit(megaURL)
        }
        return .result()
    }
}

struct GigaGrabberShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMegaLinkIntent(),
            phrases: [
                "Open a MEGA link with \(.applicationName)",
                "Send a MEGA link to \(.applicationName)"
            ],
            shortTitle: "Open MEGA link",
            systemImageName: "arrow.down.circle"
        )
    }
}
