# ContextD — Building a Screen-Aware Context Engine for LLMs

## What is ContextD?

ContextD is a native macOS menu bar app that continuously monitors your screen, extracts text via OCR, and builds a searchable timeline of your computer activity. When you're ready to prompt an LLM, you press a global hotkey and ContextD automatically enriches your prompt with relevant context from your recent activity — things you were just looking at, code you reviewed, conversations you had — formatted as markdown footnotes.

The motivating use case: after doing manual research (reviewing PRs, reading docs, browsing Slack), you want to hand off context to an AI. Instead of manually copy-pasting screenshots and quotes, ContextD captures everything in the background and retrieves the relevant pieces when you need them.

## What was built

The full MVP was implemented in a single session: 29 Swift source files, ~3,700 lines of code, one external dependency (GRDB.swift for SQLite), building on macOS 14+ system frameworks.

### Architecture

```
Menu Bar App (SwiftUI)
    |
    +-- Capture Engine (2s timer, keyframe/delta compression)
    |       +-- ScreenCaptureKit (screenshots)
    |       +-- Pixel diff (64x64 tile grid) -> selective OCR
    |       +-- Vision / VNRecognizeTextRequest (full or partial OCR)
    |       +-- AXUIElement + CGWindowList (app/window metadata)
    |       +-- Keyframe: full-screen OCR on significant change / app switch / time cap
    |       +-- Delta: OCR only changed regions (~5-20% of screen)
    |       +-- Deduplication (SHA256 hash on fullOcrText)
    |
    +-- Storage Layer
    |       +-- SQLite via GRDB.swift (DatabasePool, WAL mode)
    |       +-- FTS5 full-text search (porter stemming + unicode)
    |       +-- Migrations for schema evolution
    |
    +-- Progressive Summarization (background actor)
    |       +-- Chunks captures into 5-minute windows
    |       +-- Sends to Claude Haiku for summarization
    |       +-- Extracts key topics/entities
    |
    +-- Enrichment Engine (strategy pattern)
    |       +-- Two-pass LLM retrieval:
    |       |     Pass 1: FTS5 + recency -> Haiku judges relevance
    |       |     Pass 2: Fetch raw captures -> LLM synthesizes footnotes
    |       +-- Extensible via EnrichmentStrategy protocol
    |
    +-- UI
            +-- MenuBarExtra (status, controls)
            +-- Global hotkey (Cmd+Shift+Space via Carbon API)
            +-- Floating enrichment panel (prompt input -> enriched output)
            +-- Settings (API key, models, prompt templates, retention)
            +-- Database debug window (live capture/summary viewer)
```

### Files created

```
contextd/
├── Package.swift
├── Makefile                              # 27 development targets
├── .gitignore
├── scripts/
│   ├── dev.sh                            # Build + run + live log streaming
│   ├── db-inspect.sh                     # Interactive database inspector
│   ├── reset-all.sh                      # Reset permissions/DB/build
│   ├── benchmark.sh                      # Capture pipeline performance
│   └── gen-info-plist.sh                 # Info.plist for .app bundle
├── docs/
│   └── summary.md                        # This file
├── .opencode/
│   └── plans/
│       └── contextd-architecture.md      # Full architecture plan with API references
└── ContextD/
    ├── App/
    │   ├── ContextDApp.swift             # @main, MenuBarExtra, service orchestration
    │   └── AppDelegate.swift             # NSApplicationDelegate, window controllers
    ├── Capture/
    │   ├── CaptureFrame.swift            # Data model (FrameType, CaptureFrame with ocrText/fullOcrText)
    │   ├── CaptureEngine.swift           # Keyframe/delta pipeline with pixel diff
    │   ├── ImageDiffer.swift             # Pixel-level tile diff between screenshots (NEW)
    │   ├── ScreenCapture.swift           # SCScreenshotManager wrapper
    │   ├── OCRProcessor.swift            # Full + partial region OCR via Vision
    │   └── AccessibilityReader.swift     # AXUIElement + CGWindowList + NSWorkspace
    ├── Storage/
    │   ├── Database.swift                # GRDB DatabasePool, migrations, FTS5 triggers
    │   ├── CaptureRecord.swift           # GRDB Record for captures table
    │   ├── SummaryRecord.swift           # GRDB Record for summaries table
    │   └── StorageManager.swift          # Queries, FTS search, cleanup
    ├── Summarization/
    │   ├── Chunker.swift                 # Time-based + app-switch chunking
    │   └── SummarizationEngine.swift     # Background actor, polls unsummarized chunks
    ├── Enrichment/
    │   ├── EnrichmentStrategy.swift      # Protocol + data types
    │   ├── TwoPassLLMStrategy.swift      # Two-pass LLM retrieval (FTS -> detail)
    │   └── EnrichmentEngine.swift        # Coordinator with strategy selection
    ├── LLMClient/
    │   ├── LLMClient.swift               # Protocol + error types
    │   ├── AnthropicClient.swift         # Hand-rolled Anthropic Messages API client
    │   └── KeychainHelper.swift          # Secure API key storage via Security framework
    ├── UI/
    │   ├── HotkeyManager.swift           # Carbon RegisterEventHotKey
    │   ├── EnrichmentPanel.swift         # Floating panel for prompt enrichment
    │   ├── SettingsView.swift            # Tabbed settings (API, models, prompts, storage)
    │   ├── MenuBarView.swift             # Menu bar dropdown
    │   └── DebugTimelineView.swift       # Live database viewer with 4 tabs
    ├── Permissions/
    │   ├── PermissionManager.swift       # Check/request Screen Recording + Accessibility
    │   └── OnboardingView.swift          # First-run permission walkthrough
    └── Utilities/
        ├── PromptTemplates.swift         # Default + user-customizable prompt templates
        ├── CaptureFormatter.swift        # Hierarchical keyframe+delta text for LLM input (NEW)
        ├── TextDiff.swift                # Jaccard similarity for deduplication
        └── Extensions.swift              # SHA256, date formatting, safe subscript
```

### Key design decisions

1. **macOS 14+ minimum** — required for `SCScreenshotManager` (single-frame capture without setting up a full stream).
2. **No screenshot storage** — OCR text is stored, images are discarded after processing. Saves ~4 GB/day vs ~86 MB/day.
3. **Keyframe/delta compression** — pixel diff detects changed screen regions before OCR. Keyframes capture full text; deltas only OCR changed portions (~5-20% of screen). Reduces OCR work by ~95% and LLM tokens by ~60%.
4. **Two text fields** — `ocrText` (delta-only for deltas, full for keyframes) for token-efficient LLM input; `fullOcrText` (always complete text) for FTS search and UI display.
5. **Pixel diff before OCR** — 64x64 tile grid comparison is immune to OCR jitter and takes ~5-10ms vs ~200ms for OCR. Noise threshold (~4%) filters cursor blink, clock updates.
6. **Non-sandboxed** — required for ScreenCaptureKit, AXUIElement, CGWindowList, and Carbon global hotkeys. Distributable via direct download + notarization, not Mac App Store.
7. **Single external dependency** (GRDB.swift) — everything else uses system frameworks. The Anthropic API client is hand-rolled with URLSession.
8. **Strategy pattern for enrichment** — `EnrichmentStrategy` protocol makes it easy to add keyword-only, semantic search, or hybrid strategies later.
9. **Carbon hotkey** — `RegisterEventHotKey` is the most reliable global hotkey API on macOS, still used by Raycast and Alfred.
10. **Progressive summarization is async** — background actor processes chunks without blocking capture. Recent unsummarized captures fall back to raw OCR in the enrichment pipeline.
11. **All prompts are user-configurable** — stored in UserDefaults, editable from Settings.

### Bugs fixed during development

1. **Onboarding window not showing** — SwiftUI `Window(id:)` scenes don't auto-open; they need `openWindow(id:)` from inside a view, but `MenuBarExtra` content is lazily loaded. Fixed by using `NSApplicationDelegate.applicationDidFinishLaunching` to imperatively create and show an `NSWindow`.

2. **Settings not opening** — `NSApp.sendAction(Selector(("showSettingsWindow:")))` doesn't work reliably from `MenuBarExtra` menu items because the responder chain doesn't route to the SwiftUI Settings scene. Fixed by using `SettingsLink` (macOS 14+), which is the native API for this.

### Development tooling

- **Makefile** with 27 targets: `build`, `run`, `clean`, `watch` (fswatch), `lint`, `loc`, `bundle` (.app), `db-stats`, `db-recent`, `db-search Q="..."`, `logs` (live unified logging), `reset-permissions`, `reset-db`, etc.
- **scripts/dev.sh** — single command to build, kill previous instance, and run with live log streaming.
- **scripts/db-inspect.sh** — interactive database inspector (stats, recent, search, export JSON, tail, capture detail).
- **scripts/reset-all.sh** — clean slate for testing (kill app, reset TCC permissions, clear UserDefaults, optionally delete DB and build).
- **scripts/benchmark.sh** — measure screenshot + OCR pipeline performance.

### How to run

```bash
make run          # build + run debug binary
make run-bundle   # build .app bundle + launch (needed for permission prompts)
make logs         # stream live logs in another terminal
make db-stats     # check what's in the database
```

On first launch, the onboarding window guides you through granting Screen Recording and Accessibility permissions. Configure your Anthropic API key in Settings. Press **Cmd+Shift+Space** to open the enrichment panel.

### What's next

The architecture plan (`.opencode/plans/contextd-architecture.md`) documents future enhancements:

- Semantic search via local embeddings (CoreML / NLEmbedding)
- Full accessibility API integration (deep UI element traversal)
- Screenshot archive (optional, for multimodal LLM context)
- Browser extension for URLs/page content
- Multi-monitor capture
- MCP server (expose timeline as a Model Context Protocol tool)
- Per-app privacy exclusions and PII redaction
- Streaming enrichment for faster UX
