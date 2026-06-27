import Foundation

/// Generates and parses Klick channel invite URLs.
///
/// Two URL forms are accepted, both carrying the same payload string:
///   • Universal Link:  `https://klick.arknet.click/join?payload=<encoded>`
///   • Custom scheme:   `klick://join?payload=<encoded>`
///
/// The `<encoded>` part is whatever `PairingService.channelQRPayload(...)`
/// produces — `klick:ch:<id-b64>:<key-b64>:<name-b64>` — passed through
/// URL query encoding. We don't invent a new payload format; routing both
/// the link path and the QR-scan path through the same parser keeps the
/// invite codebase down to one source of truth.
enum InviteLink {
    /// Public-facing host. Must match the `applinks:` entitlement and the
    /// AASA file hosted on the Cloudflare Worker.
    static let host = "klick.arknet.click"

    /// Build a Universal Link from a channel's identity. Returned URL is
    /// safe to share via Messages / Mail / AirDrop — taps on iOS will open
    /// the app when installed, or fall back to the relay's `/join` page
    /// when not.
    static func makeURL(channelId: String, channelKey: Data, channelName: String,
                        pairing: PairingService = PairingService()) -> URL? {
        let payload = pairing.channelQRPayload(
            channelId: channelId,
            channelKey: channelKey,
            channelName: channelName
        )
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/join"
        components.queryItems = [URLQueryItem(name: "payload", value: payload)]
        return components.url
    }
}
