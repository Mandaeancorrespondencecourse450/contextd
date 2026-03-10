import Foundation
import GRDB

/// Database record for a single screen capture entry.
struct CaptureRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    /// Auto-incremented primary key
    var id: Int64?

    /// Unix timestamp of the capture
    var timestamp: Double

    /// Name of the frontmost application
    var appName: String

    /// Bundle identifier of the frontmost application
    var appBundleID: String?

    /// Title of the focused window
    var windowTitle: String?

    /// For keyframes: full screen text. For deltas: changed-region text only.
    var ocrText: String

    /// Always the full reconstructed screen text (for FTS and general queries).
    /// For keyframes: same as ocrText.
    /// For deltas: keyframe text + "\n" + ocrText.
    var fullOcrText: String

    /// JSON-encoded array of visible windows
    var visibleWindows: String?

    /// SHA256 hash of normalized OCR text for deduplication
    var textHash: String

    /// Whether this capture has been included in a progressive summary
    var isSummarized: Bool

    /// Frame type: "keyframe" or "delta"
    var frameType: String

    /// For deltas: DB ID of the parent keyframe. Nil for keyframes.
    var keyframeId: Int64?

    /// Percentage of screen tiles that changed (0.0-1.0).
    var changePercentage: Double

    // MARK: - Table mapping

    static let databaseTableName = "captures"

    enum Columns: String, ColumnExpression {
        case id, timestamp, appName, appBundleID, windowTitle
        case ocrText, fullOcrText, visibleWindows, textHash, isSummarized
        case frameType, keyframeId, changePercentage
    }

    // MARK: - Record lifecycle

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    // MARK: - Computed properties

    /// Whether this record is a keyframe.
    var isKeyframe: Bool { frameType == "keyframe" }

    /// Whether this record is a delta frame.
    var isDelta: Bool { frameType == "delta" }
}

// MARK: - Convenience initializer from CaptureFrame

extension CaptureRecord {
    init(frame: CaptureFrame) {
        self.id = nil
        self.timestamp = frame.timestamp.timeIntervalSince1970
        self.appName = frame.appName
        self.appBundleID = frame.appBundleID
        self.windowTitle = frame.windowTitle
        self.ocrText = frame.ocrText
        self.fullOcrText = frame.fullOcrText
        self.textHash = frame.textHash
        self.isSummarized = false
        self.frameType = frame.frameType.rawValue
        self.keyframeId = frame.keyframeId
        self.changePercentage = frame.changePercentage

        // Encode visible windows as JSON
        if let data = try? JSONEncoder().encode(frame.visibleWindows),
           let json = String(data: data, encoding: .utf8) {
            self.visibleWindows = json
        } else {
            self.visibleWindows = nil
        }
    }

    /// Decode the visible windows JSON back to an array.
    var decodedVisibleWindows: [VisibleWindow] {
        guard let json = visibleWindows,
              let data = json.data(using: .utf8),
              let windows = try? JSONDecoder().decode([VisibleWindow].self, from: data) else {
            return []
        }
        return windows
    }

    /// Convenience: timestamp as Date
    var date: Date {
        Date(timeIntervalSince1970: timestamp)
    }
}
