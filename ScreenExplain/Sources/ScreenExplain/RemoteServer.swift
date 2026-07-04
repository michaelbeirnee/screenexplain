import Foundation
import FlyingFox

protocol RemoteServerDelegate: AnyObject {
    func remoteStatus() -> RemoteStatus
    func remoteToggleActiveMode()
    func remoteToggleClickMode()
    func remoteSetMode(_ mode: AppMode)
    func remoteSetModel(_ model: GeminiModel)
    func remoteSetTargetLanguage(_ language: String)
    func remoteSetInterval(_ seconds: Double)
    func remoteSetManualPush(_ enabled: Bool)
    func remoteSetMicEnabled(_ enabled: Bool)
    func remoteSetShowPanelOnExplainNow(_ enabled: Bool)
    func remotePushAudioNow()
    /// Captures whatever region was last selected and explains/translates it
    /// right now — the remote equivalent of an Option+Click. Returns false if
    /// no region has ever been selected yet, or the mode doesn't support it.
    func remoteExplainNow() -> Bool
}

struct RemoteStatus: Codable {
    var activeModeRunning: Bool
    var clickModeRunning: Bool
    var hasSelectedRegion: Bool
    var mode: String
    var availableModes: [String]
    var model: String
    var availableModels: [String]
    var targetLanguage: String
    var interval: Double
    var manualPushEnabled: Bool
    var micEnabled: Bool
    var showPanelOnExplainNow: Bool
    var panelTitle: String
    var transcript: String
}

enum RemoteServerError: LocalizedError {
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .alreadyRunning: return "Remote server is already running."
        }
    }
}

/// Local HTTP API that a separate web frontend (e.g. hosted on GitHub Pages)
/// can call to view live status and remote-control active mode. Binds to
/// loopback only — reaching it from another device or the public internet
/// requires pointing a tunnel (Tailscale Funnel, ngrok, etc.) at this port.
/// All state-changing requests require a Keychain-stored bearer token
/// (see RemoteAccessToken) since anyone holding it can control screen/audio
/// capture on this Mac.
final class RemoteServer: @unchecked Sendable {
    static let shared = RemoteServer()
    static let port: UInt16 = 8787

    weak var delegate: RemoteServerDelegate?

    private var server: HTTPServer?

    private init() {}

    var isRunning: Bool { server != nil }

    func start() throws {
        guard server == nil else { throw RemoteServerError.alreadyRunning }

        // IPv4 loopback specifically (FlyingFox's .loopback helper is IPv6-only)
        // since tunnels like Tailscale Funnel proxy to 127.0.0.1, not [::1].
        let server = try HTTPServer(address: .inet(ip4: "127.0.0.1", port: Self.port), handler: RemoteHTTPHandler(owner: self))
        self.server = server

        Task { try? await server.run() }
    }

    func stop() {
        guard let server else { return }
        self.server = nil
        Task { await server.stop(timeout: 2) }
    }

    fileprivate func handle(_ request: HTTPRequest) async -> HTTPResponse {
        if request.method == .OPTIONS {
            return HTTPResponse(statusCode: .noContent, headers: Self.corsHeaders)
        }

        guard request.path == "/" else {
            guard isAuthorized(request) else {
                return Self.json(.unauthorized, ["error": "unauthorized"])
            }
            guard let delegate else {
                return Self.json(.internalServerError, ["error": "not ready"])
            }
            return await route(request, delegate: delegate)
        }

        return HTTPResponse(
            statusCode: .ok,
            headers: [.contentType: "text/plain; charset=utf-8"] + Self.corsHeaders,
            body: Data("ScreenExplain remote API is running.".utf8)
        )
    }

    private func route(_ request: HTTPRequest, delegate: RemoteServerDelegate) async -> HTTPResponse {
        switch (request.method, request.path) {
        case (.GET, "/api/status"):
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/toggle-active-mode"):
            await MainActor.run { delegate.remoteToggleActiveMode() }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/toggle-click-mode"):
            await MainActor.run { delegate.remoteToggleClickMode() }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/mode"):
            guard let raw: String = await field(request, "mode"), let mode = AppMode(rawValue: raw) else {
                return Self.json(.badRequest, ["error": "invalid mode"])
            }
            await MainActor.run { delegate.remoteSetMode(mode) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/model"):
            guard let raw: String = await field(request, "model"), let model = GeminiModel(rawValue: raw) else {
                return Self.json(.badRequest, ["error": "invalid model"])
            }
            await MainActor.run { delegate.remoteSetModel(model) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/target-language"):
            guard let language: String = await field(request, "language"), !language.isEmpty else {
                return Self.json(.badRequest, ["error": "invalid language"])
            }
            await MainActor.run { delegate.remoteSetTargetLanguage(language) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/interval"):
            guard let seconds: Double = await field(request, "seconds"), seconds > 0 else {
                return Self.json(.badRequest, ["error": "invalid interval"])
            }
            await MainActor.run { delegate.remoteSetInterval(seconds) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/manual-push"):
            guard let enabled: Bool = await field(request, "enabled") else {
                return Self.json(.badRequest, ["error": "invalid value"])
            }
            await MainActor.run { delegate.remoteSetManualPush(enabled) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/mic-enabled"):
            guard let enabled: Bool = await field(request, "enabled") else {
                return Self.json(.badRequest, ["error": "invalid value"])
            }
            await MainActor.run { delegate.remoteSetMicEnabled(enabled) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/show-panel-on-explain-now"):
            guard let enabled: Bool = await field(request, "enabled") else {
                return Self.json(.badRequest, ["error": "invalid value"])
            }
            await MainActor.run { delegate.remoteSetShowPanelOnExplainNow(enabled) }
            let status = await MainActor.run { delegate.remoteStatus() }
            return Self.json(.ok, status)

        case (.POST, "/api/push-audio-now"):
            await MainActor.run { delegate.remotePushAudioNow() }
            return Self.json(.ok, ["ok": true])

        case (.POST, "/api/explain-now"):
            let started = await MainActor.run { delegate.remoteExplainNow() }
            guard started else {
                return Self.json(.badRequest, ["error": "No region selected yet — use Click to Explain or Active Mode locally once first, and make sure the mode isn't Translate Audio."])
            }
            return Self.json(.ok, ["ok": true])

        default:
            return Self.json(.notFound, ["error": "not found"])
        }
    }

    private func field<T>(_ request: HTTPRequest, _ key: String) async -> T? {
        guard let body = try? await request.bodyData,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json[key] as? T
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard let token = RemoteAccessToken.current, !token.isEmpty else { return false }
        return request.headers[.authorization] == "Bearer \(token)"
    }

    private static var corsHeaders: HTTPHeaders {
        [
            HTTPHeader("Access-Control-Allow-Origin"): "*",
            HTTPHeader("Access-Control-Allow-Headers"): "Authorization, Content-Type",
            HTTPHeader("Access-Control-Allow-Methods"): "GET, POST, OPTIONS"
        ]
    }

    private static func json(_ statusCode: HTTPStatusCode, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return HTTPResponse(statusCode: statusCode, headers: [.contentType: "application/json"] + corsHeaders, body: data)
    }

    private static func json<T: Encodable>(_ statusCode: HTTPStatusCode, _ value: T) -> HTTPResponse {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return HTTPResponse(statusCode: statusCode, headers: [.contentType: "application/json"] + corsHeaders, body: data)
    }
}

private extension HTTPHeaders {
    static func + (lhs: HTTPHeaders, rhs: HTTPHeaders) -> HTTPHeaders {
        var result = lhs
        for header in rhs.keys {
            result[header] = rhs[header]
        }
        return result
    }
}

private struct RemoteHTTPHandler: HTTPHandler {
    let owner: RemoteServer

    func handleRequest(_ request: HTTPRequest) async throws -> HTTPResponse {
        await owner.handle(request)
    }
}
