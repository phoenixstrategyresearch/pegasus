import AppIntents
import Foundation

/// App Intent that lets users ask Pegasus questions via Shortcuts or Action Button.
@available(iOS 16.0, *)
struct AskPegasusIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Pegasus"
    static let description = IntentDescription("Ask Pegasus AI agent a question or give it a command.")
    static let openAppWhenRun = true

    @Parameter(title: "Question")
    var question: String?

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let isVoice = question == nil || question?.isEmpty == true
        let userInfo: [String: Any] = [
            "source": "shortcut",
            "query": question ?? "",
            "mode": isVoice ? "voice" : "text"
        ]
        // Delay slightly so the app UI is ready to receive the notification
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(name: .pegasusShortcutTriggered, object: nil, userInfo: userInfo)
        }

        if let q = question, !q.isEmpty {
            return .result(dialog: "Asking Pegasus: \(q)")
        } else {
            // Empty dialog avoids a Shortcuts "Done" banner overlapping the voice overlay
            return .result(dialog: "")
        }
    }
}

/// Voice mode intent — opens Pegasus and immediately starts recording.
@available(iOS 16.0, *)
struct PegasusVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Pegasus"
    static let description = IntentDescription("Open Pegasus and start voice input for hands-free interaction.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NotificationCenter.default.post(
                name: .pegasusShortcutTriggered,
                object: nil,
                userInfo: ["source": "shortcut", "mode": "voice"]
            )
        }
        return .result()
    }
}

/// Shortcuts provider — makes intents discoverable in the Shortcuts app and Siri.
/// PegasusVoiceIntent is listed first so it's the default Action Button shortcut.
@available(iOS 16.0, *)
struct PegasusShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PegasusVoiceIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "\(.applicationName) voice",
                "\(.applicationName) listen",
                "\(.applicationName)"
            ],
            shortTitle: "Talk to Pegasus",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: AskPegasusIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Hey \(.applicationName)"
            ],
            shortTitle: "Ask Pegasus",
            systemImageName: "sparkles"
        )
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let pegasusShortcutTriggered = Notification.Name("pegasusShortcutTriggered")
}
