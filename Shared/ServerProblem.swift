import Foundation

/// Why a request to the Mac didn't go through, in the ways worth telling people apart.
/// Shared by the contact card's server check, the share sheet and the keyboard; each says it in its own words.
enum ServerProblem: Error, Equatable {
    /// The app hasn't left the server address and token where an extension can read them.
    case notSetUp
    case offline, unreachable, timedOut, refused
    case server(Int)
    /// Something answered, and it wasn't Otto: a hotel's sign-in page, a proxy, another site at that address.
    case notOtto

    /// What Otto's `/app/settings` answers is a JSON object. A 200 with anything else (a captive portal's page)
    /// is somebody else's server, and a pairing must not be saved against it.
    static func isOtto(_ body: Data) -> Bool { (try? JSONSerialization.jsonObject(with: body)) is [String: Any] }

    /// Nil when it went through: no error, and no HTTP status of 400 or more.
    /// A status wins over the error it caused (a websocket refused with a 401 fails with a URLError too).
    init?(status: Int?, error: (any Error)?) {
        if let status, status >= 400 {
            self = status == 401 || status == 403 ? .refused : .server(status)
        } else if let error {
            switch (error as? URLError)?.code {
            case .timedOut?: self = .timedOut
            case .notConnectedToInternet?, .dataNotAllowed?, .internationalRoamingOff?: self = .offline
            default: self = .unreachable
            }
        } else {
            return nil
        }
    }

    /// The share sheet's words. The keyboard (two short lines) and the contact card (where the address
    /// and token are typed) swap in their own where theirs differ. Retrying is each surface's own button.
    var message: String {
        switch self {
        case .notSetUp: "Open Otto once, so it knows where your Mac is."
        case .offline: "You're offline. Connect to Wi-Fi or mobile data."
        case .unreachable: "Can't reach your Mac. Check it's awake and on Tailscale."
        case .timedOut: "Your Mac took too long to answer."
        case .refused: "Your Mac didn't accept this phone's token. Pair again in Otto."
        case .server(let code): "Otto's server hit an error (\(code)). Try again in a moment."
        case .notOtto: "Something answered at that address, but it isn't Otto. Check the address, and that this network isn't asking you to sign in."
        }
    }
}
