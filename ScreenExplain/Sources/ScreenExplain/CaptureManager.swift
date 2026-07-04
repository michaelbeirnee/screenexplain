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

    /// Silently captures a screen (no flash, no sound, no user interaction)
    /// for use by active mode's polling loop. With a region, captures just
    /// that display + rect (as chosen via RegionSelector); without one,
    /// falls back to the whole main display.
    static func captureFullScreen(region: SelectedRegion? = nil) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            let display: SCDisplay
            if let region, let match = content.displays.first(where: { $0.displayID == region.displayID }) {
                display = match
            } else if let first = content.displays.first {
                display = first
            } else {
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = displayScale(for: display.displayID)
            config.showsCursor = false

            if let region {
                config.sourceRect = region.rect
                config.width = max(1, Int(region.rect.width * scale))
                config.height = max(1, Int(region.rect.height * scale))
            } else {
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
            }

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let rep = NSBitmapImageRep(cgImage: image)
            return rep.representation(using: .png, properties: [:])
        } catch {
            return nil
        }
    }

    private static func displayScale(for displayID: CGDirectDisplayID) -> CGFloat {
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID
        }
        return screen?.backingScaleFactor ?? 2
    }
}
