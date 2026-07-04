import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard
    private static let modeKey = "selectedMode"
    private static let targetLanguageKey = "targetLanguage"
    private static let intervalKey = "activeModeInterval"
    private static let audioManualPushKey = "audioManualPush"
    private static let remoteServerEnabledKey = "remoteServerEnabled"
    private static let micCaptureDisabledKey = "micCaptureDisabled"
    private static let hidePanelOnExplainNowKey = "hidePanelOnExplainNow"
    private static let modelKey = "geminiModel"

    static var mode: AppMode {
        get { AppMode(rawValue: defaults.string(forKey: modeKey) ?? "") ?? .explain }
        set { defaults.set(newValue.rawValue, forKey: modeKey) }
    }

    static var targetLanguage: String {
        get {
            let value = defaults.string(forKey: targetLanguageKey) ?? ""
            return value.isEmpty ? "English" : value
        }
        set { defaults.set(newValue, forKey: targetLanguageKey) }
    }

    /// Seconds between auto-captures in active mode (also used as the audio chunk length).
    static var activeModeInterval: TimeInterval {
        get {
            let value = defaults.double(forKey: intervalKey)
            return value > 0 ? value : 5
        }
        set { defaults.set(newValue, forKey: intervalKey) }
    }

    /// When true, Translate Audio mode never auto-flushes on a timer — audio
    /// only gets sent when the user manually pushes (menu item / hotkey).
    static var audioManualPushEnabled: Bool {
        get { defaults.bool(forKey: audioManualPushKey) }
        set { defaults.set(newValue, forKey: audioManualPushKey) }
    }

    /// Whether the local remote-control HTTP API should be running. Only
    /// gates the loopback listener itself — actual internet exposure is up
    /// to whatever tunnel (Tailscale Funnel, ngrok, etc.) points at it.
    static var remoteServerEnabled: Bool {
        get { defaults.bool(forKey: remoteServerEnabledKey) }
        set { defaults.set(newValue, forKey: remoteServerEnabledKey) }
    }

    /// Whether Translate Audio mode also captures the microphone as a second,
    /// separately-labeled track (defaults on — that's what lets the model
    /// tell "you talking" apart from call audio instead of guessing).
    static var micCaptureEnabled: Bool {
        get { !defaults.bool(forKey: micCaptureDisabledKey) }
        set { defaults.set(!newValue, forKey: micCaptureDisabledKey) }
    }

    /// When true, a remote "Explain Now" trigger only updates the panel's
    /// content (visible via the web dashboard's live output) without forcing
    /// the window on screen if it's currently closed. If it's already open,
    /// it still updates in place. Local triggers (hotkey, Option+Click)
    /// always show the panel regardless of this setting, since the user is
    /// physically there to see it pop up. Defaults to showing (off).
    static var showPanelOnExplainNow: Bool {
        get { !defaults.bool(forKey: hidePanelOnExplainNowKey) }
        set { defaults.set(!newValue, forKey: hidePanelOnExplainNowKey) }
    }

    /// Which Gemini model to request. GeminiClient automatically falls back
    /// to a cheaper model on a 429 without changing this setting.
    static var model: GeminiModel {
        get { GeminiModel(rawValue: defaults.string(forKey: modelKey) ?? "") ?? .flash }
        set { defaults.set(newValue.rawValue, forKey: modelKey) }
    }
}
