import AppKit

enum ClickModeError: LocalizedError {
    case audioModeNotSupported

    var errorDescription: String? {
        switch self {
        case .audioModeNotSupported:
            return "Click to Explain doesn't apply to Translate Audio mode. Switch to Explain or Translate Screen Text first."
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isCapturing = false

    private var activeModeTimer: Timer?
    private var isActiveModeRunning = false
    private var lastAudioTranscript = ""
    private var audioPanelStarted = false
    /// Screen + rect chosen via RegionSelector for this active-mode session.
    /// Persists across in-place restarts (e.g. changing the interval) so
    /// those don't re-prompt; only a fresh Active Mode toggle-on does.
    private var activeModeRegion: SelectedRegion?

    private var isClickModeRunning = false
    private var clickModeRegion: SelectedRegion?
    private var clickModeMonitor: Any?
    private var isClickCapturing = false

    private static let idleIcon = "text.viewfinder"
    private static let activeIcon = "eye.fill"

    private weak var remoteServerMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setUpStatusItem()
        setUpHotkey()

        RemoteServer.shared.delegate = self
        if Settings.remoteServerEnabled {
            try? RemoteServer.shared.start()
        }
    }

    // MARK: - Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: Self.idleIcon, accessibilityDescription: "Explain")
        }

        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(withTitle: "Capture (⌘⇧E)", action: #selector(triggerCapture), keyEquivalent: "")
        menu.addItem(.separator())

        let activeModeItem = NSMenuItem(title: "Active Mode", action: #selector(toggleActiveMode), keyEquivalent: "")
        activeModeItem.target = self
        menu.addItem(activeModeItem)

        let clickModeItem = NSMenuItem(title: "Click to Explain (⌥+Click)", action: #selector(toggleClickMode), keyEquivalent: "")
        clickModeItem.target = self
        menu.addItem(clickModeItem)

        let intervalMenu = NSMenu()
        for seconds in [3.0, 5.0, 10.0, 20.0] {
            let item = NSMenuItem(title: "Every \(Int(seconds))s", action: #selector(setInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = seconds
            intervalMenu.addItem(item)
        }
        let intervalItem = NSMenuItem(title: "Active Mode Interval", action: nil, keyEquivalent: "")
        menu.setSubmenu(intervalMenu, for: intervalItem)
        menu.addItem(intervalItem)

        let manualPushItem = NSMenuItem(title: "Manual Push (Audio)", action: #selector(toggleAudioManualPush), keyEquivalent: "")
        manualPushItem.target = self
        menu.addItem(manualPushItem)
        menu.addItem(withTitle: "Push Audio Now (⌘⇧T)", action: #selector(pushAudioNow), keyEquivalent: "")

        let micItem = NSMenuItem(title: "Include Microphone (Audio Mode)", action: #selector(toggleMicCapture), keyEquivalent: "")
        micItem.target = self
        menu.addItem(micItem)
        menu.addItem(.separator())

        let modeMenu = NSMenu()
        for mode in AppMode.allCases {
            let item = NSMenuItem(title: mode.displayName, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            modeMenu.addItem(item)
        }
        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        menu.setSubmenu(modeMenu, for: modeItem)
        menu.addItem(modeItem)

        menu.addItem(withTitle: "Target Language…", action: #selector(promptForTargetLanguage), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Set Gemini API Key…", action: #selector(promptForAPIKey), keyEquivalent: "")
        menu.addItem(.separator())

        let remoteServerItem = NSMenuItem(title: "Remote Access Server", action: #selector(toggleRemoteServer), keyEquivalent: "")
        remoteServerItem.target = self
        menu.addItem(remoteServerItem)
        remoteServerMenuItem = remoteServerItem
        menu.addItem(withTitle: "Copy Remote Access Token", action: #selector(copyRemoteAccessToken), keyEquivalent: "")
        menu.addItem(withTitle: "Regenerate Remote Access Token…", action: #selector(regenerateRemoteAccessToken), keyEquivalent: "")
        menu.addItem(.separator())

        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.items.forEach { $0.target = $0.target ?? self }
        item.menu = menu

        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if let mode = item.representedObject as? AppMode {
                item.state = (mode == Settings.mode) ? .on : .off
            } else if let seconds = item.representedObject as? Double {
                item.state = (seconds == Settings.activeModeInterval) ? .on : .off
            }
            if item.title == "Active Mode" {
                item.state = isActiveModeRunning ? .on : .off
            }
            if item.title == "Click to Explain (⌥+Click)" {
                item.state = isClickModeRunning ? .on : .off
            }
            if item.title == "Manual Push (Audio)" {
                item.state = Settings.audioManualPushEnabled ? .on : .off
            }
            if item.title == "Include Microphone (Audio Mode)" {
                item.state = Settings.micCaptureEnabled ? .on : .off
            }
        }

        if let remoteServerMenuItem {
            let running = RemoteServer.shared.isRunning
            remoteServerMenuItem.state = running ? .on : .off
            remoteServerMenuItem.title = running ? "Remote Access Server (Running on :\(RemoteServer.port))" : "Remote Access Server"
        }
    }

    @objc private func toggleAudioManualPush() {
        applyAudioManualPush(!Settings.audioManualPushEnabled)
    }

    private func applyAudioManualPush(_ enabled: Bool) {
        guard Settings.audioManualPushEnabled != enabled else { return }
        Settings.audioManualPushEnabled = enabled
        if isActiveModeRunning && Settings.mode == .translateAudio {
            stopActiveMode()
            restartActiveModeKeepingRegion()
        }
    }

    @objc private func toggleMicCapture() {
        applyMicCapture(!Settings.micCaptureEnabled)
    }

    private func applyMicCapture(_ enabled: Bool) {
        guard Settings.micCaptureEnabled != enabled else { return }
        Settings.micCaptureEnabled = enabled
        if isActiveModeRunning && Settings.mode == .translateAudio {
            stopActiveMode()
            restartActiveModeKeepingRegion()
        }
    }

    @objc private func setMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? AppMode else { return }
        applyMode(mode)
    }

    @objc private func setInterval(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Double else { return }
        applyInterval(seconds)
    }

    /// Mode changes always require a restart since screen polling and audio
    /// streaming use entirely different capture pipelines.
    private func applyMode(_ mode: AppMode) {
        Settings.mode = mode
        if isActiveModeRunning {
            stopActiveMode()
            startActiveMode()
        }
        if isClickModeRunning && mode == .translateAudio {
            stopClickMode()
        }
    }

    /// Interval changes shouldn't force the user to re-pick a screen region,
    /// so this restarts in place using whatever region is already active
    /// (region selection only happens on a fresh Active Mode toggle-on).
    private func applyInterval(_ seconds: Double) {
        Settings.activeModeInterval = seconds
        if isActiveModeRunning {
            stopActiveMode()
            restartActiveModeKeepingRegion()
        }
    }

    // MARK: - Remote access

    @objc private func toggleRemoteServer() {
        if RemoteServer.shared.isRunning {
            RemoteServer.shared.stop()
            Settings.remoteServerEnabled = false
        } else {
            do {
                try RemoteServer.shared.start()
                Settings.remoteServerEnabled = true
            } catch {
                showError(error)
            }
        }
    }

    @objc private func copyRemoteAccessToken() {
        let token = RemoteAccessToken.getOrCreate()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    @objc private func regenerateRemoteAccessToken() {
        let alert = NSAlert()
        alert.messageText = "Regenerate Remote Access Token?"
        alert.informativeText = "Any web page or device using the current token will stop working until they're given the new one."
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let token = RemoteAccessToken.regenerate()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(token, forType: .string)
    }

    // MARK: - Hotkey

    private func setUpHotkey() {
        let matchesKey: (NSEvent, String) -> Bool = { event, key in
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .shift]
                && event.charactersIgnoringModifiers?.lowercased() == key
        }

        let handle: (NSEvent) -> Bool = { [weak self] event in
            if matchesKey(event, "e") {
                self?.triggerCapture()
                return true
            }
            if matchesKey(event, "t") {
                self?.pushAudioNow()
                return true
            }
            return false
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            _ = handle(event)
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    // MARK: - One-shot capture (hotkey / menu item)

    @objc private func triggerCapture() {
        guard !isCapturing else { return }
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            promptForAPIKey()
            return
        }
        isCapturing = true

        let mouseLocation = NSEvent.mouseLocation

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let imageData = CaptureManager.captureRegion()
            DispatchQueue.main.async {
                self?.isCapturing = false
                guard let imageData else { return }
                self?.runOneShot(imageData: imageData, apiKey: apiKey, near: mouseLocation)
            }
        }
    }

    private func runOneShot(imageData: Data, apiKey: String, near point: NSPoint) {
        let panel = ResultPanel.shared ?? ResultPanel()
        ResultPanel.shared = panel
        panel.title = Settings.mode == .translateScreen ? "Translate" : "Explain"
        panel.resetText()
        panel.showNear(point: point)

        Task {
            do {
                var started = false
                let onDelta: (String) -> Void = { chunk in
                    DispatchQueue.main.async {
                        if !started {
                            panel.resetText()
                            started = true
                        }
                        panel.append(chunk)
                    }
                }

                switch Settings.mode {
                case .translateScreen:
                    try await GeminiClient.translateImage(pngData: imageData, targetLanguage: Settings.targetLanguage, apiKey: apiKey, onDelta: onDelta)
                case .explain, .translateAudio:
                    try await GeminiClient.explainImage(pngData: imageData, apiKey: apiKey, onDelta: onDelta)
                }
            } catch {
                await MainActor.run {
                    panel.resetText()
                    panel.append("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Active mode

    @objc private func toggleActiveMode() {
        if isActiveModeRunning {
            stopActiveMode()
        } else {
            startActiveMode()
        }
    }

    /// Entry point for a fresh Active Mode toggle-on. For screen-based modes,
    /// prompts for which monitor/region to watch (screenshot-tool style)
    /// before starting — in-place restarts (interval changes etc.) skip this
    /// and reuse the chosen region via restartActiveModeKeepingRegion().
    private func startActiveMode() {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            promptForAPIKey()
            return
        }

        switch Settings.mode {
        case .explain, .translateScreen:
            RegionSelector.choose { [weak self] region in
                guard let self, let region else { return }
                self.activeModeRegion = region
                self.beginActiveMode(apiKey: apiKey)
            }
        case .translateAudio:
            activeModeRegion = nil
            beginActiveMode(apiKey: apiKey)
        }
    }

    /// Used when settings change while Active Mode is already running — reuses
    /// whatever region was already chosen instead of prompting again.
    private func restartActiveModeKeepingRegion() {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else { return }
        if Settings.mode != .translateAudio && activeModeRegion == nil {
            startActiveMode()
            return
        }
        beginActiveMode(apiKey: apiKey)
    }

    private func beginActiveMode(apiKey: String) {
        isActiveModeRunning = true
        updateStatusIcon()

        let panel = ResultPanel.shared ?? ResultPanel()
        ResultPanel.shared = panel
        panel.title = Settings.mode == .translateScreen ? "Live Translate" : (Settings.mode == .translateAudio ? "Live Audio Translate" : "Live Explain")
        panel.resetText()
        positionPanelTopRight(panel)
        panel.orderFront(nil)

        switch Settings.mode {
        case .explain, .translateScreen:
            runActiveModeImageTick()
            let timer = Timer.scheduledTimer(withTimeInterval: Settings.activeModeInterval, repeats: true) { [weak self] _ in
                self?.runActiveModeImageTick()
            }
            RunLoop.main.add(timer, forMode: .common)
            activeModeTimer = timer

        case .translateAudio:
            lastAudioTranscript = ""
            audioPanelStarted = false
            Task {
                do {
                    try await AudioCapture.shared.start(onStreamError: { [weak self] error in
                        DispatchQueue.main.async {
                            self?.showError(error)
                            self?.stopActiveMode()
                        }
                    })
                    if Settings.micCaptureEnabled {
                        try MicrophoneCapture.shared.start()
                    }
                } catch {
                    await MainActor.run {
                        self.showError(error)
                        self.stopActiveMode()
                    }
                    return
                }

                guard !Settings.audioManualPushEnabled else { return }
                await MainActor.run {
                    let timer = Timer.scheduledTimer(withTimeInterval: Settings.activeModeInterval, repeats: true) { [weak self] _ in
                        self?.runAudioTick()
                    }
                    RunLoop.main.add(timer, forMode: .common)
                    self.activeModeTimer = timer
                }
            }
        }
    }

    private func stopActiveMode() {
        isActiveModeRunning = false
        activeModeTimer?.invalidate()
        activeModeTimer = nil
        AudioCapture.shared.stop()
        MicrophoneCapture.shared.stop()
        lastAudioTranscript = ""
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let isActive = isActiveModeRunning || isClickModeRunning
        let icon = isActive ? Self.activeIcon : Self.idleIcon
        statusItem?.button?.image = NSImage(systemSymbolName: icon, accessibilityDescription: isActive ? "Active" : "Explain")
    }

    // MARK: - Click to explain

    @objc private func toggleClickMode() {
        if isClickModeRunning {
            stopClickMode()
        } else {
            startClickMode()
        }
    }

    /// Prompts for which screen/region to watch (same picker Active Mode
    /// uses), then arms a global Option+Click monitor. Each qualifying click
    /// captures that region and explains/translates it — the click's exact
    /// position only decides where the result panel appears, not what's
    /// captured, so it works the same regardless of what's under the cursor
    /// (a native button, a webpage, anything).
    private func startClickMode() {
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            promptForAPIKey()
            return
        }
        guard Settings.mode != .translateAudio else {
            showError(ClickModeError.audioModeNotSupported)
            return
        }

        RegionSelector.choose { [weak self] region in
            guard let self, let region else { return }
            self.clickModeRegion = region
            self.isClickModeRunning = true
            self.updateStatusIcon()
            self.setUpClickModeMonitor()
        }
    }

    private func stopClickMode() {
        isClickModeRunning = false
        clickModeRegion = nil
        if let clickModeMonitor {
            NSEvent.removeMonitor(clickModeMonitor)
        }
        clickModeMonitor = nil
        updateStatusIcon()
    }

    private func setUpClickModeMonitor() {
        clickModeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard event.modifierFlags.contains(.option) else { return }
            self?.handleClickModeTrigger(at: NSEvent.mouseLocation)
        }
    }

    private func handleClickModeTrigger(at point: NSPoint) {
        guard isClickModeRunning, !isClickCapturing, let region = clickModeRegion else { return }
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            stopClickMode()
            return
        }
        isClickCapturing = true

        Task {
            let imageData = await CaptureManager.captureFullScreen(region: region)
            await MainActor.run {
                self.isClickCapturing = false
                guard let imageData else { return }
                self.runOneShot(imageData: imageData, apiKey: apiKey, near: point)
            }
        }
    }

    /// Manually flushes whatever audio has buffered since the last chunk —
    /// used by the hotkey/menu item, and the only way audio gets sent when
    /// Manual Push is enabled.
    @objc private func pushAudioNow() {
        runAudioTick()
    }

    /// Pulls whatever's buffered from both audio sources at the same instant
    /// so they land in one request as two clearly-labeled tracks.
    private func runAudioTick() {
        guard isActiveModeRunning, Settings.mode == .translateAudio else { return }
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            stopActiveMode()
            return
        }
        let micEnabled = Settings.micCaptureEnabled
        Task {
            async let systemWav = AudioCapture.shared.flush()
            async let micWav: Data? = micEnabled ? MicrophoneCapture.shared.flush() : nil
            let (systemAudio, micAudio) = await (systemWav, micWav)
            guard systemAudio != nil || micAudio != nil else { return }
            processAudioChunk(micAudio: micAudio, systemAudio: systemAudio, apiKey: apiKey)
        }
    }

    private func runActiveModeImageTick() {
        guard isActiveModeRunning else { return }
        guard let apiKey = Keychain.loadAPIKey(), !apiKey.isEmpty else {
            stopActiveMode()
            return
        }
        let region = activeModeRegion
        Task {
            guard let imageData = await CaptureManager.captureFullScreen(region: region) else { return }
            guard isActiveModeRunning, let panel = ResultPanel.shared else { return }

            do {
                var started = false
                let onDelta: (String) -> Void = { chunk in
                    DispatchQueue.main.async {
                        if !started {
                            panel.resetText()
                            started = true
                        }
                        panel.append(chunk)
                    }
                }

                switch Settings.mode {
                case .translateScreen:
                    try await GeminiClient.translateImage(pngData: imageData, targetLanguage: Settings.targetLanguage, apiKey: apiKey, onDelta: onDelta)
                case .explain:
                    try await GeminiClient.explainImage(pngData: imageData, apiKey: apiKey, onDelta: onDelta)
                case .translateAudio:
                    break
                }
            } catch {
                await MainActor.run {
                    panel.resetText()
                    panel.append("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Translated audio streams into the panel as a running transcript
    /// (rather than replacing it each chunk) so a multi-speaker conversation
    /// stays readable across turns.
    private func processAudioChunk(micAudio: Data?, systemAudio: Data?, apiKey: String) {
        guard isActiveModeRunning, let panel = ResultPanel.shared else { return }
        let contextForThisChunk = lastAudioTranscript
        Task {
            do {
                var isFirstDeltaOfChunk = true
                var fullText = ""
                try await GeminiClient.translateAudio(micAudio: micAudio, systemAudio: systemAudio, targetLanguage: Settings.targetLanguage, previousContext: contextForThisChunk, apiKey: apiKey) { chunk in
                    fullText += chunk
                    DispatchQueue.main.async {
                        if isFirstDeltaOfChunk {
                            isFirstDeltaOfChunk = false
                            if !self.audioPanelStarted {
                                panel.resetText()
                                self.audioPanelStarted = true
                            } else {
                                panel.append("\n")
                            }
                        }
                        panel.append(chunk)
                    }
                }
                if !fullText.isEmpty {
                    await MainActor.run {
                        self.lastAudioTranscript = String(fullText.suffix(500))
                    }
                }
            } catch {
                await MainActor.run {
                    panel.append("\n[Error: \(error.localizedDescription)]")
                }
            }
        }
    }

    private func positionPanelTopRight(_ panel: ResultPanel) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(x: visible.maxX - panel.frame.width - 20, y: visible.maxY - panel.frame.height - 20)
        panel.setFrameOrigin(origin)
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Active Mode Error"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Settings prompts

    @objc private func promptForAPIKey() {
        let alert = NSAlert()
        alert.messageText = "Gemini API Key"
        alert.informativeText = "Enter your Gemini API key. It's stored securely in the macOS Keychain."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "AIza..."
        if let existing = Keychain.loadAPIKey() {
            field.stringValue = existing
        }
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                Keychain.saveAPIKey(key)
            }
        }
    }

    @objc private func promptForTargetLanguage() {
        let alert = NSAlert()
        alert.messageText = "Target Language"
        alert.informativeText = "Language to translate into (used by Translate Screen Text and Translate Audio modes)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "e.g. Spanish, French, Japanese"
        field.stringValue = Settings.targetLanguage
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let language = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !language.isEmpty {
                Settings.targetLanguage = language
            }
        }
    }
}

// MARK: - RemoteServerDelegate

extension AppDelegate: RemoteServerDelegate {
    func remoteStatus() -> RemoteStatus {
        RemoteStatus(
            activeModeRunning: isActiveModeRunning,
            mode: Settings.mode.rawValue,
            availableModes: AppMode.allCases.map(\.rawValue),
            targetLanguage: Settings.targetLanguage,
            interval: Settings.activeModeInterval,
            manualPushEnabled: Settings.audioManualPushEnabled,
            micEnabled: Settings.micCaptureEnabled,
            panelTitle: ResultPanel.shared?.title ?? "",
            transcript: ResultPanel.shared?.currentText ?? ""
        )
    }

    func remoteToggleActiveMode() {
        toggleActiveMode()
    }

    func remoteSetMode(_ mode: AppMode) {
        applyMode(mode)
    }

    func remoteSetTargetLanguage(_ language: String) {
        Settings.targetLanguage = language
    }

    func remoteSetInterval(_ seconds: Double) {
        applyInterval(seconds)
    }

    func remoteSetManualPush(_ enabled: Bool) {
        applyAudioManualPush(enabled)
    }

    func remoteSetMicEnabled(_ enabled: Bool) {
        applyMicCapture(enabled)
    }

    func remotePushAudioNow() {
        pushAudioNow()
    }
}
