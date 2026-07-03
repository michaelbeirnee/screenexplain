import Foundation
import Security

/// A random bearer token gating the remote-control HTTP API. Anyone who has
/// it (and network access to the port, typically via a tunnel) can control
/// the app remotely, so it's stored in the Keychain rather than UserDefaults.
enum RemoteAccessToken {
    static var current: String? {
        Keychain.loadRemoteAccessToken()
    }

    @discardableResult
    static func getOrCreate() -> String {
        if let existing = Keychain.loadRemoteAccessToken(), !existing.isEmpty {
            return existing
        }
        return regenerate()
    }

    @discardableResult
    static func regenerate() -> String {
        let token = generate()
        Keychain.saveRemoteAccessToken(token)
        return token
    }

    private static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
