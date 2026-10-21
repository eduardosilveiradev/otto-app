import AppIntents
import CoreLocation
import MapKit
import UIKit

/// "Hey Siri, ask Otto", and the same thing on the Action Button. App Intents need
/// no Siri entitlement; SiriKit's INSendMessageIntent would, and a free personal team
/// can't provision it. There's only one recipient, so nothing to resolve.
struct MessageOtto: AppIntent {
    static let title: LocalizedStringResource = "Message Otto"
    static let description = IntentDescription("Ask Otto something and hear the answer, without opening the app.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    // Siri now reads out the user's day, so a locked phone has to be unlocked first; a Face ID glance does that hands-free.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Message", requestValueDialog: "What should I tell Otto?")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = OttoStore.shared
        let mine = Message(from: .me, text: text)
        if let a = await store.siri(mine, send: { await $0.ask(id: mine.wireID, text: text, via: "siri") }) {
            return .result(dialog: try await spoken(a))
        }
        let sent = await store.sendAndConfirm(mine.id)
        return .result(dialog: sent ? "Sent." : "Otto's offline. It goes out next time the app connects.")
    }
}

/// A photo to file. It gets no AppShortcut phrase: Siri can't fill a photo parameter, and a camera
/// can't run headless. The only system camera outside the app is the Shortcuts "Take Photo" action,
/// so the user builds "Take Photo, then Snap to Otto" once.
struct SnapToOtto: AppIntent {
    static let title: LocalizedStringResource = "Snap to Otto"
    static let description = IntentDescription("Send Otto a photo to file: homework, a receipt, something to keep. Put Take Photo before it in a shortcut.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Photo", supportedContentTypes: [.image], inputConnectionBehavior: .connectToPreviousIntentResult)
    var photo: IntentFile

    @Parameter(title: "Note")
    var note: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let image = UIImage(data: photo.data), let jpeg = OttoStore.jpeg(image) else {
            return .result(dialog: "That isn't a photo I can read.")
        }
        let words = note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mine = Message(from: .me, text: words, image: jpeg)
        // ponytail: an offline snap only stays in the thread; queue the upload like voice notes if that bites.
        guard let a = await OttoStore.shared.siri(mine, send: { await $0.snap(jpeg, note: words, id: mine.wireID) }) else {
            return .result(dialog: "Otto's offline. The photo's in the chat; send it again when it's back.")
        }
        return .result(dialog: try await spoken(a))
    }
}

struct SaveThisPlace: AppIntent {
    static let title: LocalizedStringResource = "Save This Place"
    static let description = IntentDescription("Tell Otto where you are and what you think of it.")
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "Comment")
    var comment: String?

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        var said = comment
        if said == nil { said = try? await $comment.requestValue("Anything about it?") }   // the optional voice comment
        let words = said?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var fix = await Here.location()
        if fix == nil {   // first use (the permission prompt) or not "in use" yet: once in the foreground
            try await continueInForeground("Otto needs your location for this.", alwaysConfirm: false)
            fix = await Here.location()
        }
        guard let fix else { return .result(dialog: "Couldn't get your location.") }
        let place = await Here.describe(fix)
        let mine = Message(from: .me, text: "📍 " + (words.isEmpty ? (place["name"] as? String ?? "here") : words))
        guard let a = await OttoStore.shared.siri(mine, send: { await $0.ask(id: mine.wireID, text: words, via: "here", place: place) })
        else { return .result(dialog: "Otto's offline, so that place isn't saved.") }
        return .result(dialog: try await spoken(a))
    }
}

/// Where the phone is, and what it calls the place. Reverse geocoding happens on the phone,
/// so there's no key and no third party on the Mac.
enum Here {
    @MainActor static func location() async -> CLLocation? {
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        return await withTaskGroup(of: CLLocation?.self) { g in
            g.addTask {
                do {
                    for try await u in CLLocationUpdate.liveUpdates() {
                        if u.authorizationDenied || u.authorizationDeniedGlobally || u.authorizationRestricted || u.insufficientlyInUse { return nil }
                        if let l = u.location, (0...100).contains(l.horizontalAccuracy) { return l }
                    }
                } catch {}
                return nil
            }
            g.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    static func describe(_ l: CLLocation) async -> [String: Any] {
        var out: [String: Any] = ["lat": l.coordinate.latitude, "lon": l.coordinate.longitude, "accuracy": l.horizontalAccuracy]
        // MapKit's iOS 26 request: CLGeocoder is deprecated in the 26 SDK.
        if let req = MKReverseGeocodingRequest(location: l), let item = try? await req.mapItems.first {
            out.merge(["name": item.name, "address": item.address?.shortAddress,
                       "city": item.addressRepresentations?.cityName, "country": item.addressRepresentations?.regionName]
                .compactMapValues { $0 }) { _, new in new }
        }
        return out
    }
}

extension AppIntent {
    /// What Siri says back: Otto's first reply, or `late` while it's still coming. A reply with
    /// buttons is waiting on a tap (a write never happens from Siri), so the app opens on the thread.
    @MainActor func spoken(_ a: LiveBackend.Answer, late: IntentDialog = "Still on it. The answer will be in the chat.") async throws -> IntentDialog {
        guard let r = a.reply else { return late }
        if !r.buttons.isEmpty { try await continueInForeground(nil, alwaysConfirm: false) }
        return "\(r.text)"
    }
}

struct OttoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MessageOtto(),
                    // Not "message/tell Otto": Siri hands those to Messages, and there's a contact named Otto.
                    phrases: ["Ask \(.applicationName)", "Ping \(.applicationName)", "Talk to \(.applicationName)"],
                    shortTitle: "Message Otto", systemImageName: "message")
        AppShortcut(intent: SaveThisPlace(),
                    phrases: ["Save this place in \(.applicationName)", "Pin this place in \(.applicationName)", "\(.applicationName), save this place"],
                    shortTitle: "Save This Place", systemImageName: "mappin.and.ellipse")
    }
}
