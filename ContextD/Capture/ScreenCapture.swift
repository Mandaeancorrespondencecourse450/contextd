import Foundation
import ScreenCaptureKit
import CoreGraphics

/// Wraps ScreenCaptureKit to capture single-frame screenshots of the main display.
/// Requires macOS 14+ for SCScreenshotManager.
actor ScreenCapture {
    private let logger = DualLogger(category: "ScreenCapture")

    /// Capture a screenshot of the main display.
    /// Returns a CGImage, or nil if capture fails (e.g., no permission).
    func captureMainDisplay() async throws -> CGImage? {
        // Get available content (displays, windows, apps)
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard let mainDisplay = content.displays.first else {
            logger.error("No displays found")
            return nil
        }

        // Create a filter for the main display, excluding nothing
        let filter = SCContentFilter(display: mainDisplay, excludingWindows: [])

        // Configure capture: scale down to 1920 width max for performance
        let config = SCStreamConfiguration()
        let scale = min(1.0, 1920.0 / CGFloat(mainDisplay.width))
        config.width = Int(CGFloat(mainDisplay.width) * scale)
        config.height = Int(CGFloat(mainDisplay.height) * scale)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = false

        // Capture a single screenshot
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        logger.debug("Captured screenshot: \(config.width)x\(config.height)")
        return image
    }
}
