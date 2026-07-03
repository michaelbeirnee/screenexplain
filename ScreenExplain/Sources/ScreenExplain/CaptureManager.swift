import Foundation
import AppKit
import ScreenCaptureKit

enum CaptureManager {
    /// Runs the interactive macOS region-selection screenshot tool and returns
    /// the captured PNG data, or nil if the user cancelled (pressed Escape).
    static func captureRegion() -> Data? {
        let tempPath = NSTemporaryDirectory() + "screenexplain-\(UUID().uuidString).png"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive selection, -x: no camera shutter sound
        process.arguments = ["-i", "-x", tempPath]

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        defer { try? FileManager.default.removeItem(atPath: tempPath) }

        guard FileManager.default.fileExists(atPath: tempPath) else {
            return nil
        }
        return FileManager.default.contents(atPath: tempPath)
    }

    /// Silently captures the whole main display (no flash, no sound, no user
    /// interaction) for use by active mode's polling loop.
    static func captureFullScreen() async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return nil }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = Int(NSScreen.main?.backingScaleFactor ?? 2)
            config.width = display.width * scale
            config.height = display.height * scale
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .png, properties: [:])
        } catch {
            return nil
        }
    }
}
