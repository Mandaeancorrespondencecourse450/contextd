import Foundation
import CoreGraphics

/// Represents a single screen region with recognized text.
struct OCRRegion: Codable, Sendable {
    let text: String
    let bounds: CodableCGRect
    let confidence: Float
}

/// Codable wrapper for CGRect since CGRect doesn't conform to Codable.
struct CodableCGRect: Codable, Sendable {
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Represents a visible window on screen.
struct VisibleWindow: Codable, Sendable {
    let appName: String
    let windowTitle: String?
}

/// Whether this capture is a keyframe (full screen) or delta (changed regions only).
enum FrameType: String, Codable, Sendable {
    case keyframe
    case delta
}

/// A single capture frame produced by the CaptureEngine every 2 seconds.
/// Contains all the metadata and OCR text from one screenshot cycle.
///
/// For keyframes: `ocrText` and `fullOcrText` are identical (full screen text).
/// For deltas: `ocrText` contains only changed-region text; `fullOcrText` contains
/// the keyframe text + delta text (for FTS and general queries).
struct CaptureFrame: Sendable {
    /// When this frame was captured
    let timestamp: Date

    /// The frontmost (focused) application name
    let appName: String

    /// Bundle identifier of the frontmost app (e.g., "com.apple.Safari")
    let appBundleID: String?

    /// Title of the focused window (from Accessibility API)
    let windowTitle: String?

    /// All visible windows on screen
    let visibleWindows: [VisibleWindow]

    /// For keyframes: full screen text. For deltas: changed-region text only.
    let ocrText: String

    /// Always the full reconstructed screen text (for FTS and general queries).
    /// For keyframes: same as ocrText.
    /// For deltas: keyframe text + "\n" + ocrText (simple concatenation).
    let fullOcrText: String

    /// Individual text regions with bounding boxes and confidence scores
    let ocrRegions: [OCRRegion]

    /// SHA256 hash of the normalized OCR text, used for deduplication
    let textHash: String

    /// Whether this is a keyframe or delta frame.
    let frameType: FrameType

    /// For deltas: the DB ID of the parent keyframe. Nil for keyframes.
    let keyframeId: Int64?

    /// Percentage of screen tiles that changed (0.0-1.0).
    let changePercentage: Double
}
