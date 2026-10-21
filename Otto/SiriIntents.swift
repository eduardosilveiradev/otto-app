import AppIntents

/// "Hey Siri, ask Otto", and the same thing on the Action Button. App Intents need
/// no Siri entitlement; SiriKit's INSendMessageIntent would, and a free personal team
/// can't provision it. There's only one recipient, so nothing to resolve.
struct MessageOtto: AppIntent {
    static let title: LocalizedStringResource = "Message Otto"
    static let description = IntentDescription("Send Otto a message without opening the app.")
    static let openAppWhenRun = false

    @Parameter(title: "Message", requestValueDialog: "What should I tell Otto?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let sent = await OttoStore.shared.sendAndConfirm(text)
        return .result(dialog: sent ? "Sent." : "Otto's offline. It goes out next time the app connects.")
    }
}

struct OttoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MessageOtto(),
                    // Not "message/tell Otto": Siri hands those to Messages, and there's a contact named Otto.
                    phrases: ["Ask \(.applicationName)", "Ping \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Message Otto", systemImageName: "message")
    }
}
