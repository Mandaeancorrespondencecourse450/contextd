# Keyframe OCR Pipeline Overhaul

## Overview

Replace the current "full OCR every 2 seconds" pipeline with a keyframe/delta approach
inspired by video compression. Keyframes capture full-screen OCR text; delta frames
only OCR the portions of the screen that changed (detected via pixel diffing before OCR).

### Goals

1. **Reduce OCR work** — delta frames only OCR changed regions (~5-20% of screen)
2. **Save LLM tokens** — summarization and enrichment receive keyframe text + delta-only
   text instead of full screen text for every sample
3. **Save storage** — delta `ocrText` is small; `fullOcrText` is redundant but cheaper
   than the current approach since many near-identical captures are now skipped or compressed
4. **More reliable change detection** — pixel diff is immune to OCR jitter

### Design Decisions

| Decision | Choice |
|----------|--------|
| Change detection method | Pixel diff first, then selective OCR |
| Diff resolution | Full capture resolution (1920px max) |
| Diff grid | 64x64 pixel tiles |
| Keyframe threshold | >= 50% of tiles changed |
| Time-based keyframe cap | Every 60 seconds (configurable) |
| OCR crop padding | 32px around changed tile groups |
| FTS indexing | All frames, using `fullOcrText` column |
| OCR regions in DB | No — force keyframe on restart |
| `fullOcrText` storage | Populated at insert time for all frame types |
| LLM input format | Hierarchical: keyframe full text + delta-only text |
| Text reconstruction | Simple concatenation (keyframe text + delta text appended) |

---

## Architecture

### Current Pipeline (every 2s)

```
Screenshot → Full OCR → Hash dedup → Store full text
```

### New Pipeline (every 2s)

```
Screenshot
    │
    ├─ Pixel diff against previous screenshot (64×64 tile grid)
    │
    ├─ 0% tiles changed → Skip entirely (no OCR, no storage)
    │
    ├─ >0% and <50% tiles changed → DELTA FRAME
    │   ├─ Crop changed regions (+ 32px padding) from screenshot
    │   ├─ Run OCR only on cropped regions
    │   ├─ ocrText = text from changed regions only
    │   ├─ fullOcrText = keyframe text + "\n" + delta text (for FTS)
    │   └─ Store both
    │
    ├─ ≥50% tiles changed → KEYFRAME
    │   ├─ Run full-screen OCR
    │   └─ ocrText = fullOcrText = complete screen text
    │
    ├─ ≥60s since last keyframe → KEYFRAME (time-based)
    │
    └─ App switch or first capture → KEYFRAME (event-based)
```

### LLM Token Strategy

When sending captures to LLMs (summarization, enrichment), captures are grouped
into keyframe→delta sequences and formatted hierarchically:

```
--- Keyframe (10:00:00) [Safari — GitHub Pull Request #42] ---
<full screen text>

--- Delta (10:00:02) [5% changed] ---
<changed-region text only>

--- Delta (10:00:04) [3% changed] ---
<changed-region text only>

--- Keyframe (10:01:00) [VS Code — src/config.ts] ---
<full screen text>
```

This sends the LLM the complete picture at keyframe moments, then only incremental
changes between keyframes. Compared to sending full text for every sample, this saves
roughly 60-80% of tokens while preserving the same information.

---

## Files to Change

### Phase 1: Image Diffing Module (NEW)

#### 1. NEW: `ContextD/Capture/ImageDiffer.swift`

Core pixel-diff engine. Compares two CGImages using a 64×64 tile grid.

**Public API:**

```swift
struct TileDiff {
    let changedTiles: [(row: Int, col: Int)]
    let totalTiles: Int
    var changePercentage: Double  // changedTiles.count / totalTiles
}

struct ChangedRegion {
    let bounds: CGRect          // pixel coordinates in full image
    let croppedImage: CGImage   // cropped portion for OCR
}

struct DiffResult {
    let tileDiff: TileDiff
    let changedRegions: [ChangedRegion]  // merged + padded bounding rects
    let isSignificantChange: Bool        // changePercentage >= threshold
}

final class ImageDiffer {
    let tileSize: Int = 64
    let paddingPixels: Int = 32
    var significantChangeThreshold: Double = 0.50

    /// Compare two screenshots. Returns diff result with changed regions.
    func diff(current: CGImage, previous: CGImage) -> DiffResult
}
```

**Implementation details:**

- Access raw pixel data via `CGImage.dataProvider` or render into `CGBitmapContext`
  with known format (32-bit BGRA, sRGB) for consistent pixel access
- For each 64×64 tile, compute mean absolute per-channel pixel difference
- Per-tile noise threshold: ~4% of max (10/255) filters sub-pixel rendering,
  font antialiasing, cursor blink, menu bar clock updates
- Merge adjacent changed tiles into rectangular bounding regions via flood-fill
  on the tile grid
- Expand each merged region by 32px on all sides (clamped to image bounds)
- Crop from the current CGImage for each region
- If images have different dimensions → return 100% changed (force keyframe)

---

### Phase 2: Partial OCR Support

#### 2. `ContextD/Capture/OCRProcessor.swift`

Add a new method for running OCR on multiple cropped regions:

```swift
/// Existing (unchanged):
func recognizeText(in image: CGImage) throws -> OCRResult

/// New:
func recognizeText(inRegions regions: [ChangedRegion],
                   fullImageSize: CGSize) throws -> OCRResult
```

New method:
- For each `ChangedRegion`, run `VNRecognizeTextRequest` on the `croppedImage`
- Translate bounding boxes from crop-local coordinates back to full-image coordinates
  using `region.bounds` offset
- Combine all region results into a single `OCRResult`
- Sort by position (top-to-bottom, left-to-right) same as current
- `fullText` = joined text from all changed regions (delta text only)
- `regions` = OCR regions with coordinates in full-image space

If the number of separate regions exceeds 8, fall back to full-screen OCR
(many scattered small crops is slower than one full OCR pass).

---

### Phase 3: Data Model Changes

#### 3. `ContextD/Capture/CaptureFrame.swift`

```swift
/// New enum:
enum FrameType: String, Codable, Sendable {
    case keyframe
    case delta
}

struct CaptureFrame: Sendable {
    let timestamp: Date
    let appName: String
    let appBundleID: String?
    let windowTitle: String?
    let visibleWindows: [VisibleWindow]

    /// For keyframes: full screen text. For deltas: changed-region text only.
    let ocrText: String

    /// Always the full reconstructed screen text (for FTS and general queries).
    /// For keyframes: same as ocrText.
    /// For deltas: keyframe text + "\n" + ocrText (simple concatenation).
    let fullOcrText: String

    let ocrRegions: [OCRRegion]
    let textHash: String

    /// Whether this is a keyframe or delta frame.
    let frameType: FrameType

    /// For deltas: the DB ID of the parent keyframe. Nil for keyframes.
    let keyframeId: Int64?

    /// Percentage of screen tiles that changed (0.0-1.0).
    let changePercentage: Double
}
```

#### 4. `ContextD/Storage/CaptureRecord.swift`

Add new columns and update mappings:

```swift
struct CaptureRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    var timestamp: Double
    var appName: String
    var appBundleID: String?
    var windowTitle: String?
    var ocrText: String              // Delta text for deltas, full text for keyframes
    var fullOcrText: String          // Always full text (for FTS + queries)
    var visibleWindows: String?
    var textHash: String
    var isSummarized: Bool
    var frameType: String            // "keyframe" or "delta"
    var keyframeId: Int64?           // FK to parent keyframe (nil for keyframes)
    var changePercentage: Double     // 0.0-1.0

    // Update Columns enum:
    enum Columns: String, ColumnExpression {
        case id, timestamp, appName, appBundleID, windowTitle
        case ocrText, fullOcrText, visibleWindows, textHash, isSummarized
        case frameType, keyframeId, changePercentage
    }

    // New computed properties:
    var isKeyframe: Bool { frameType == "keyframe" }
}
```

Update `init(frame:)` to map all new fields from CaptureFrame.

#### 5. `ContextD/Storage/Database.swift`

New migration:

```sql
-- Migration "v2_keyframeSupport"
ALTER TABLE captures ADD COLUMN frameType TEXT NOT NULL DEFAULT 'keyframe';
ALTER TABLE captures ADD COLUMN keyframeId INTEGER;
ALTER TABLE captures ADD COLUMN fullOcrText TEXT NOT NULL DEFAULT '';
ALTER TABLE captures ADD COLUMN changePercentage REAL NOT NULL DEFAULT 1.0;

-- Backfill existing records
UPDATE captures SET fullOcrText = ocrText WHERE fullOcrText = '';

-- New indexes
CREATE INDEX idx_captures_keyframe ON captures(keyframeId);
CREATE INDEX idx_captures_frametype ON captures(frameType);
```

Update FTS triggers to index `fullOcrText` instead of `ocrText`:

```sql
-- captures_ai trigger (AFTER INSERT):
INSERT INTO captures_fts(rowid, ocrText, windowTitle, appName)
VALUES (new.id, new.fullOcrText, new.windowTitle, new.appName);

-- Same change in captures_au (update) and captures_ad (delete) triggers
-- The FTS column name stays 'ocrText' for backward compat, but VALUE is fullOcrText
```

Note: In DEBUG builds, `eraseDatabaseOnSchemaChange = true` wipes the DB anyway,
so the migration is primarily for future production use.

---

### Phase 4: Capture Engine Rewrite

#### 6. `ContextD/Capture/CaptureEngine.swift` — Major rewrite

**New state:**

```swift
private let imageDiffer = ImageDiffer()
private var previousImage: CGImage?           // ~8MB, last captured screenshot
private var currentKeyframeId: Int64?         // DB ID of current keyframe
private var currentKeyframeText: String?      // full OCR text of current keyframe
private var currentKeyframeRegions: [OCRRegion]?
private var lastKeyframeTime: Date?
private var lastKeyframeAppName: String?
var maxKeyframeInterval: TimeInterval = 60    // configurable
```

**New `performCapture()` flow:**

```
1. Read accessibility metadata (unchanged)
2. Capture screenshot (unchanged)
3. If previousImage == nil (first capture / after restart):
   → Force KEYFRAME
4. Else: compute pixel diff
   a. diffResult = imageDiffer.diff(current: image, previous: previousImage)
   b. If changePercentage == 0.0:
      → Skip entirely (truly identical frame)
   c. Determine frame type — KEYFRAME if any of:
      - diffResult.isSignificantChange (≥50% tiles)
      - metadata.appName != lastKeyframeAppName
      - timeSinceLastKeyframe >= maxKeyframeInterval
   d. Otherwise → DELTA
5. KEYFRAME path:
   a. Full-screen OCR
   b. Hash dedup against last stored hash (skip if identical)
   c. Build CaptureFrame(frameType: .keyframe, keyframeId: nil,
      ocrText: fullText, fullOcrText: fullText, changePercentage: ...)
   d. Insert into DB → get back record.id
   e. Update state: currentKeyframeId, currentKeyframeText,
      currentKeyframeRegions, lastKeyframeTime, lastKeyframeAppName,
      previousImage = image
6. DELTA path:
   a. OCR only changed regions (or full OCR if >8 regions)
   b. deltaText = OCR result text (changed regions only)
   c. fullOcrText = (currentKeyframeText ?? "") + "\n" + deltaText
   d. Hash dedup on fullOcrText
   e. Build CaptureFrame(frameType: .delta, keyframeId: currentKeyframeId,
      ocrText: deltaText, fullOcrText: fullOcrText, changePercentage: ...)
   f. Insert into DB
   g. Update state: previousImage = image
```

**Init:** Load last keyframe from DB for continuity. previousImage starts nil → first
capture is always a keyframe.

#### 7. `ContextD/Utilities/TextDiff.swift` — No changes needed

Jaccard similarity exists but is not needed in the hot path. Pixel diff replaces
OCR-text-level similarity for change detection.

---

### Phase 5: Storage Layer Updates

#### 8. `ContextD/Storage/StorageManager.swift`

New queries:

```swift
/// Fetch the most recent keyframe.
func lastKeyframe() throws -> CaptureRecord?

/// Fetch only keyframes in a time range.
func keyframes(from: Date, to: Date, limit: Int?) throws -> [CaptureRecord]

/// Fetch all deltas belonging to a specific keyframe.
func deltasForKeyframe(id: Int64) throws -> [CaptureRecord]

/// Fetch captures in a time range, grouped into keyframe→delta sequences.
/// Returns an ordered array of KeyframeGroup, each containing a keyframe
/// and its subsequent deltas.
func captureGroups(from: Date, to: Date, limit: Int?) throws -> [KeyframeGroup]
```

New data structure for grouped access (can live in StorageManager.swift or its own file):

```swift
/// A keyframe and its associated delta frames, in chronological order.
struct KeyframeGroup {
    let keyframe: CaptureRecord
    let deltas: [CaptureRecord]

    /// All captures in chronological order (keyframe first, then deltas).
    var allCaptures: [CaptureRecord] { [keyframe] + deltas }

    /// Total number of captures in this group.
    var count: Int { 1 + deltas.count }
}
```

`captureGroups()` implementation:
- Fetch all captures in range ordered by timestamp ASC
- Walk through them: each keyframe starts a new group, deltas append to current group
- Edge case: if the range starts mid-sequence (first record is a delta), fetch the
  preceding keyframe via `keyframeId` as the group leader. If the keyframe has been
  pruned, treat the delta as a standalone entry (it has `fullOcrText`).

Update `pruneOldCaptures()`:
- No cascade needed — deltas have `fullOcrText` so they're self-contained
- `keyframeId` is informational only; orphaned references are harmless

---

### Phase 6: LLM Consumer Updates (Token-Efficient Formatting)

This is the critical phase for token savings. Both summarization and enrichment
format captures hierarchically instead of treating every capture as full text.

#### 9. NEW: `ContextD/Utilities/CaptureFormatter.swift`

Shared formatting utility used by both summarization and enrichment:

```swift
enum CaptureFormatter {

    /// Format capture groups into hierarchical keyframe+delta text for LLM input.
    /// Keyframes include full ocrText; deltas include only their ocrText (changed regions).
    ///
    /// Output format:
    ///   --- Keyframe (HH:MM:SS) [AppName — WindowTitle] ---
    ///   <full screen text>
    ///
    ///   --- Delta (HH:MM:SS) [X% changed] ---
    ///   <changed-region text only>
    ///
    static func formatHierarchical(
        groups: [KeyframeGroup],
        maxKeyframes: Int = 10,
        maxDeltasPerKeyframe: Int = 5,
        maxKeyframeTextLength: Int = 3000,
        maxDeltaTextLength: Int = 500
    ) -> String

    /// Format a flat list of captures into hierarchical text.
    /// Internally groups them into KeyframeGroups first.
    static func formatHierarchical(
        captures: [CaptureRecord],
        maxKeyframes: Int = 10,
        maxDeltasPerKeyframe: Int = 5,
        maxKeyframeTextLength: Int = 3000,
        maxDeltaTextLength: Int = 500
    ) -> String
}
```

Implementation:
- Group flat captures into `KeyframeGroup` sequences (keyframe starts a group,
  subsequent deltas belong to it)
- Limit to `maxKeyframes` keyframe groups (evenly spaced if more exist)
- Within each group, take up to `maxDeltasPerKeyframe` deltas (evenly spaced)
- For keyframes: include `ocrText` (= full screen text) truncated to `maxKeyframeTextLength`
- For deltas: include `ocrText` (= delta-only text) truncated to `maxDeltaTextLength`
- Include metadata: timestamp, app name, window title, change percentage
- For legacy captures (all frameType='keyframe', no deltas): each becomes a
  standalone keyframe group — identical to current behavior

#### 10. `ContextD/Summarization/SummarizationEngine.swift`

Replace the current sampling logic that reads `capture.ocrText` from evenly-spaced
captures.

**Current** (`summarizeChunk`, lines 109-114):
```swift
let sampleIndices = evenlySpacedIndices(count: chunk.captures.count, maxSamples: maxSamplesPerChunk)
let ocrSamples = sampleIndices.map { chunk.captures[$0].ocrText }
    .enumerated()
    .map { "--- Sample \($0.offset + 1) ---\n\($0.element)" }
    .joined(separator: "\n\n")
```

**New:**
```swift
let ocrSamples = CaptureFormatter.formatHierarchical(
    captures: chunk.captures,
    maxKeyframes: maxSamplesPerChunk,  // reuse existing setting
    maxDeltasPerKeyframe: 3,           // keep summarization concise
    maxKeyframeTextLength: 2000,
    maxDeltaTextLength: 300
)
```

The `evenlySpacedIndices` helper method can be removed (or kept as a utility) since
`CaptureFormatter` handles its own sampling internally.

#### 11. `ContextD/Summarization/Chunker.swift` — No changes needed

Chunking operates on timestamps and app names, both of which exist on all frame types.
The captures within a chunk will be a mix of keyframes and deltas, which
`CaptureFormatter.formatHierarchical()` handles.

#### 12. `ContextD/Enrichment/TwoPassLLMStrategy.swift`

**Pass 2 formatting** (lines 201-210) — replace flat formatting:

**Current:**
```swift
let capturesText: String = limitedCaptures.map { capture -> String in
    let time = capture.date.relativeString
    let window = capture.windowTitle ?? "Unknown"
    let text = capture.ocrText.count > 500
        ? String(capture.ocrText.prefix(500)) + "..."
        : capture.ocrText
    return "[\(time)] \(capture.appName) — \(window)\n\(text)"
}.joined(separator: "\n\n---\n\n")
```

**New:**
```swift
let capturesText = CaptureFormatter.formatHierarchical(
    captures: limitedCaptures,
    maxKeyframes: 10,
    maxDeltasPerKeyframe: 5,
    maxKeyframeTextLength: 3000,
    maxDeltaTextLength: 500
)
```

**Fallback formatting** (lines 264-272) — same change as above.

#### 13. `ContextD/Enrichment/EnrichmentStrategy.swift` — No changes

Protocol and data types are frame-type-agnostic.

#### 14. `ContextD/Enrichment/EnrichmentEngine.swift` — No changes

Coordinator delegates to strategy.

---

### Phase 7: UI Updates

#### 15. `ContextD/UI/DebugTimelineView.swift`

**CaptureRowView** (line 308+):
- Show frame type badge: "K" (green) for keyframe, "D" (gray) for delta
- `capture.ocrText.prefix(150)` → `capture.fullOcrText.prefix(150)` (preview shows full text)
- `capture.ocrText.count` → show both: "full: X chars" and for deltas "delta: Y chars"
- Show `changePercentage`: e.g. "12% changed"

**CaptureDetailView** (line 351+):
- Add rows: Frame Type, Keyframe ID, Change %
- Main text display: show `fullOcrText` as primary
- For deltas: add collapsible section "Delta Text (changed regions only)" showing `ocrText`
- `capture.ocrText` in the OCR Text section → `capture.fullOcrText`

**Stats tab** (line 181+):
- Add keyframe/delta count breakdown
- Add average change percentage for deltas
- Add storage efficiency: avg keyframe `ocrText` size vs avg delta `ocrText` size

#### 16. `ContextD/UI/SettingsView.swift`

New `@AppStorage` keys:
```swift
@AppStorage("maxKeyframeInterval") private var maxKeyframeInterval: Double = 60
@AppStorage("keyframeChangeThreshold") private var keyframeChangeThreshold: Double = 0.50
```

In the "Capture" section of `generalTab`:
- Keep: capture interval slider (1-10s)
- Add: "Keyframe interval" slider (30-300s, default 60s)
- Add: "Keyframe threshold" slider (20-80%, default 50%)
- Remove: "Dedup threshold" slider (replaced by keyframe threshold)

#### 17. `ContextD/App/ServiceContainer.swift`

In `startServices()`, wire settings to engine:
```swift
if let engine = captureEngine {
    let interval = UserDefaults.standard.double(forKey: "captureInterval")
    if interval > 0 { engine.captureInterval = interval }

    let maxKFInterval = UserDefaults.standard.double(forKey: "maxKeyframeInterval")
    if maxKFInterval > 0 { engine.maxKeyframeInterval = maxKFInterval }

    let threshold = UserDefaults.standard.double(forKey: "keyframeChangeThreshold")
    if threshold > 0 { engine.imageDiffer.significantChangeThreshold = threshold }
}
```

This fixes the existing disconnect where UI settings weren't applied to the engine.

#### 18. `ContextD/UI/MenuBarView.swift` — No changes needed

Minimal status display, no frame-type info needed.

---

### Phase 8: Prompt Template Updates

#### 19. `ContextD/Utilities/PromptTemplates.swift`

Update `summarizationSystem` template to mention the format:
```
+ The screen data is organized as keyframes (full screen snapshots) and deltas
+ (only the text that changed between snapshots). Use keyframes to understand
+ the overall context and deltas to track specific changes.
```

Update `summarizationUser` template:
```
- Screen text samples (captured every 2 seconds):
+ Screen activity (keyframes show full screen, deltas show only what changed):
```

Update `enrichmentPass2User` template:
```
- ## Detailed Screen Captures
+ ## Detailed Screen Activity
```

No structural changes — just description text updates to match the new format.

---

### Phase 9: CLI and Script Updates

#### 20. `Makefile`

**`db-recent`** (line 149): Add `frameType` column, use `fullOcrText` for preview:
```sql
SELECT id, datetime(timestamp, 'unixepoch', 'localtime') AS time,
    frameType AS type, appName AS app,
    substr(fullOcrText, 1, 80) AS text_preview
FROM captures ORDER BY timestamp DESC LIMIT 10;
```

**`db-stats`** (line 130): Add frame type breakdown:
```sql
SELECT '  keyframes:  ' || COUNT(*) FROM captures WHERE frameType = 'keyframe';
SELECT '  deltas:     ' || COUNT(*) FROM captures WHERE frameType = 'delta';
```

**`db-search`** (line 178): Change `ocrText` → `fullOcrText` in preview:
```sql
substr(captures.fullOcrText, 1, 120) AS text_preview
```

**New target `db-keyframes`**: Show keyframes with delta counts:
```sql
SELECT k.id, datetime(k.timestamp, 'unixepoch', 'localtime') AS time,
    k.appName AS app, COUNT(d.id) AS deltas,
    substr(k.fullOcrText, 1, 80) AS text_preview
FROM captures k LEFT JOIN captures d ON d.keyframeId = k.id
WHERE k.frameType = 'keyframe'
GROUP BY k.id ORDER BY k.timestamp DESC LIMIT 20;
```

#### 21. `scripts/db-inspect.sh`

- `cmd_recent`: Add `frameType` column, show `length(fullOcrText)` and `length(ocrText)`
- `cmd_search`: Change `substr(captures.ocrText, ...)` → `substr(captures.fullOcrText, ...)`
- `cmd_capture_detail`: Add `frameType`, `keyframeId`, `changePercentage` to metadata;
  show `fullOcrText` as main text, show `ocrText` separately for deltas
- `cmd_stats`: Add keyframe/delta breakdown
- `cmd_export`: Add new columns to JSON output

#### 22. `scripts/benchmark.sh`

Split stats by frame type:
```sql
SELECT 'Keyframes: ' || COUNT(*) || ', avg ' || CAST(AVG(length(ocrText)) AS INT) || ' chars'
FROM captures WHERE frameType = 'keyframe';
SELECT 'Deltas: ' || COUNT(*) || ', avg ' || CAST(AVG(length(ocrText)) AS INT) || ' delta chars'
FROM captures WHERE frameType = 'delta';
```

---

### Phase 10: Documentation

#### 23. `docs/mvp-v0-capture-pipeline-and-enrichment.md`

- Update architecture diagram to show pixel diff → keyframe/delta branching
- Update "Key design decisions" section
- Update file listing to include new files (ImageDiffer.swift, CaptureFormatter.swift)
- Update storage estimates

---

## Data Flow Summary

### What each consumer reads

| Consumer | Field Used | Why |
|----------|-----------|-----|
| **FTS5 full-text search** | `fullOcrText` (via trigger) | Search needs complete text for all frames |
| **Deduplication (hash)** | `fullOcrText` hash | Dedup compares complete screen state |
| **Summarization (LLM)** | `ocrText` via `CaptureFormatter` | Token-efficient: keyframe full + delta changes only |
| **Enrichment Pass 2 (LLM)** | `ocrText` via `CaptureFormatter` | Token-efficient: keyframe full + delta changes only |
| **Enrichment Fallback (LLM)** | `ocrText` via `CaptureFormatter` | Token-efficient: keyframe full + delta changes only |
| **Debug Timeline UI (preview)** | `fullOcrText` | User wants to see complete text |
| **Debug Timeline UI (delta detail)** | `ocrText` | User wants to inspect what changed |
| **Makefile db-recent** | `fullOcrText` | Complete text for quick inspection |
| **Makefile db-search** | `fullOcrText` (via FTS) | Search matches need full context |
| **db-inspect.sh** | `fullOcrText` + `ocrText` | Both shown in detail view |
| **benchmark.sh** | `length(ocrText)` by type | Measure compression effectiveness |

### The two text fields

| Field | Keyframe Value | Delta Value | Purpose |
|-------|---------------|-------------|---------|
| `ocrText` | Full screen text | Changed-region text only | LLM input (via CaptureFormatter), storage efficiency metric |
| `fullOcrText` | Same as `ocrText` | Keyframe text + "\n" + delta text | FTS indexing, search, dedup hash, UI display |

### Why two fields?

- **`ocrText`** is what gets sent to LLMs via `CaptureFormatter`. For keyframes it's
  the full screen. For deltas it's only the changed portion. This is the key to token
  savings: the LLM sees a keyframe's complete context, then only incremental changes.
- **`fullOcrText`** is what gets indexed in FTS and shown in the UI. It's always the
  complete text so that search works correctly and the user can see the full screen
  state for any frame. For deltas, it's a simple concatenation (keyframe + delta).

---

## Edge Cases and Mitigations

### 1. First Capture / Restart Recovery

**Problem:** No previous image in memory, can't compute pixel diff.
**Mitigation:** `previousImage == nil` → force keyframe. Load `currentKeyframeId`
and `currentKeyframeText` from DB via `lastKeyframe()` query. First capture after
restart is always full OCR — same as current behavior.

### 2. Orphaned Delta References on Pruning

**Problem:** If a keyframe is deleted by retention pruning, its deltas' `keyframeId`
points to a non-existent record.
**Mitigation:** Not a problem. Every record has `fullOcrText` populated at insert time,
so deltas are self-contained for all downstream use (FTS, search, UI). The `keyframeId`
is informational only — used for debug display and `captureGroups()` grouping, both
of which handle missing keyframes gracefully (treat orphaned deltas as standalone entries).

### 3. Screen Resolution Changes

**Problem:** External monitor connect/disconnect changes image dimensions.
**Mitigation:** `ImageDiffer.diff()` checks dimensions — if they differ, returns 100%
changed → triggers keyframe. Clean reset.

### 4. Pixel Noise: Sub-pixel Rendering, Cursor Blink, Clock

**Problem:** Even on a "static" screen, cursor blinks and the menu bar clock update.
**Mitigation:** Per-tile noise threshold (~4% mean pixel difference) filters this.
A blinking cursor affects 1-2 tiles out of ~500 total → below both the per-tile
noise threshold and the 50% keyframe threshold. Worst case: generates a delta with
near-zero text (just clock digits), which is harmless.

### 5. Scrolling Content

**Problem:** Scrolling shifts most of the window content, potentially triggering
keyframe even though 90% of text is the same (just repositioned).
**Mitigation:** With 50% threshold, a significant scroll triggers a keyframe — which
is correct. Scrolling means the user navigated to new content. For small scrolls
(1-2 lines), ~10-20% of tiles change → stays as delta.

### 6. Video / Animation Playing

**Problem:** Continuous visual changes would create many keyframes.
**Mitigation:** The 60s time-based keyframe cap limits frequency. Between keyframes,
the high change % triggers keyframes on every capture. For video content this is
acceptable — the text content is also changing rapidly. Future optimization: detect
consistently high change % and reduce capture rate.

### 7. Delta OCR Boundary Clipping

**Problem:** Cropping changed regions may cut text at the boundary.
**Mitigation:** 32px padding around changed tile groups. At typical screen DPI
(2x retina), 32px ≈ 2-3 lines of 12pt text. Sufficient for complete text lines.
The `fullOcrText` concatenation means boundary artifacts in delta text are additive,
not destructive — the keyframe has the correct text for unchanged regions.

### 8. Multiple Scattered Changed Regions

**Problem:** Many small, scattered changes produce many separate OCR crops.
**Mitigation:** If more than 8 separate regions, fall back to full-screen OCR.
The overhead of many small Vision calls exceeds one full pass at that point.
Still stored as a delta (unless change % hits 50%), just OCR'd differently.

### 9. fullOcrText Staleness for Deltas

**Problem:** `fullOcrText = keyframeText + "\n" + deltaText` means removed text
from the screen remains in `fullOcrText` until the next keyframe.
**Mitigation:** Acceptable for v1. The stale text is at most 60 seconds old.
For FTS: extra indexed text means more matches, not fewer (conservative).
For UI: user sees "full text" which is slightly stale but clearly timestamped.
Future: smarter region-based text merging.

### 10. Memory: Holding Previous Image

**Problem:** Keeping the previous CGImage costs ~8MB.
**Mitigation:** Trivial on macOS. If memory pressure is detected, drop the image
and force a keyframe on next capture.

### 11. CaptureFormatter with Legacy Data

**Problem:** Existing captures in the DB (pre-migration) all have `frameType = 'keyframe'`
and no `keyframeId`. `CaptureFormatter.formatHierarchical()` would treat them all as
standalone keyframes.
**Mitigation:** This is correct behavior — legacy captures ARE effectively keyframes
(they have full screen text). The formatter handles this naturally: each legacy capture
becomes a keyframe group with zero deltas.

### 12. Summarization Chunk Contains Only Deltas

**Problem:** A 5-minute chunk might start mid-sequence with no keyframe in range.
**Mitigation:** `StorageManager.captureGroups()` fetches the preceding keyframe as
the group leader when the first record in range is a delta (via its `keyframeId`).
The formatter always has a keyframe to start from. Additionally, keyframe interval
(60s) << chunk duration (300s), so every chunk contains ~5 keyframes minimum.

### 13. Enrichment Time Range Spans Many Keyframe Groups

**Problem:** A 2-hour enrichment query could contain hundreds of keyframe groups.
Formatting all of them would exceed token limits.
**Mitigation:** `CaptureFormatter.formatHierarchical()` accepts `maxKeyframes`
parameter. For enrichment Pass 2, this is set to 10 (matching current behavior
of limiting captures). The formatter selects evenly-spaced keyframe groups.

---

## Performance Estimates

| Metric | Current | With Keyframes | Reduction |
|--------|---------|---------------|-----------|
| Full OCR calls/min | 30 | ~1 (keyframe) + ~0-1 (fallback) | ~95% |
| Partial OCR calls/min | 0 | ~29 (small crops) | N/A |
| Avg OCR time/capture | ~200ms | ~50ms (partial), ~200ms (keyframe) | ~70% weighted |
| Pixel diff time/capture | N/A | ~5-10ms | Negligible overhead |
| ocrText stored/hour | ~18MB | ~1.5MB (KF) + ~1MB (deltas) | ~85% |
| fullOcrText stored/hour | ~18MB (same field) | ~5MB | ~70% |
| FTS index size/hour | ~18MB | ~5MB (indexes fullOcrText) | ~70% |
| LLM tokens/summarization | ~10 full-text samples | ~5 KF full + ~15 delta-only | ~50-60% |
| LLM tokens/enrichment | ~50 × 500 chars | ~10 KF × 3000 + ~50 delta × 500 | varies |
| Memory overhead | ~0 | +8MB (previous image) | Negligible |

---

## Implementation Phases

| Phase | Files | Complexity | Ships Independently? |
|-------|-------|-----------|---------------------|
| **1** | ImageDiffer.swift (new) | High | No — needs Phase 2-4 |
| **2** | OCRProcessor.swift | Medium | No |
| **3** | CaptureFrame.swift, CaptureRecord.swift, Database.swift | Medium | No |
| **4** | CaptureEngine.swift | High | **Yes — Phases 1-4 = MVP** |
| **5** | StorageManager.swift + KeyframeGroup struct | Low | No — needed for Phase 6 |
| **6** | CaptureFormatter.swift (new), SummarizationEngine, TwoPassLLMStrategy | Medium | **Yes — token savings** |
| **7** | DebugTimelineView, SettingsView, ServiceContainer | Medium | Yes |
| **8** | PromptTemplates.swift | Low | Yes |
| **9** | Makefile, db-inspect.sh, benchmark.sh | Low | Yes |
| **10** | docs/ | Low | Yes |

**Minimum viable change:** Phases 1-4 (pixel diff + partial OCR + data model + engine)
**Full token savings:** Add Phases 5-6 (grouped queries + hierarchical formatter)
**Polish:** Phases 7-10

---

## New Files Summary

| File | Purpose |
|------|---------|
| `ContextD/Capture/ImageDiffer.swift` | Pixel-level tile diff between screenshots |
| `ContextD/Utilities/CaptureFormatter.swift` | Hierarchical keyframe+delta text formatting for LLM input |

All other changes are modifications to existing files (20 existing files modified).
