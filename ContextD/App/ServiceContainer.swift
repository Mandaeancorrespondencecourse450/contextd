import Foundation

/// Singleton container for all long-lived services.
/// Lives outside SwiftUI's struct lifecycle so services are created once
/// and never deallocated by view re-renders.
@MainActor
final class ServiceContainer {
    static let shared = ServiceContainer()

    private let logger = DualLogger(category: "Services")

    // Core services
    let database: AppDatabase?
    let storageManager: StorageManager?
    let llmClient: AnthropicClient
    let captureEngine: CaptureEngine?
    let enrichmentEngine: EnrichmentEngine?
    let summarizationEngine: SummarizationEngine?
    let panelController: EnrichmentPanelController?
    let debugController: DebugWindowController?

    private init() {
        llmClient = AnthropicClient()

        do {
            let db = try AppDatabase()
            let storage = StorageManager(database: db)

            database = db
            storageManager = storage
            captureEngine = CaptureEngine(storageManager: storage)

            let enrichment = EnrichmentEngine(storageManager: storage, llmClient: llmClient)
            enrichmentEngine = enrichment

            summarizationEngine = SummarizationEngine(storageManager: storage, llmClient: llmClient)
            panelController = EnrichmentPanelController(enrichmentEngine: enrichment)
            debugController = DebugWindowController(storageManager: storage)

            logger.info("ServiceContainer initialized successfully")
        } catch {
            logger.error("Failed to initialize services: \(error.localizedDescription)")
            database = nil
            storageManager = nil
            captureEngine = nil
            enrichmentEngine = nil
            summarizationEngine = nil
            panelController = nil
            debugController = nil
        }
    }

    /// Start capture + summarization. Call once after permissions are confirmed.
    func startServices() {
        guard PermissionManager.shared.allPermissionsGranted else {
            logger.warning("Cannot start services: missing permissions")
            return
        }

        // Apply user settings to capture engine
        if let engine = captureEngine {
            let interval = UserDefaults.standard.double(forKey: "captureInterval")
            if interval > 0 { engine.captureInterval = interval }

            let maxKFInterval = UserDefaults.standard.double(forKey: "maxKeyframeInterval")
            if maxKFInterval > 0 { engine.maxKeyframeInterval = maxKFInterval }

            let threshold = UserDefaults.standard.double(forKey: "keyframeChangeThreshold")
            if threshold > 0 { engine.imageDiffer.significantChangeThreshold = threshold }
        }

        captureEngine?.start()

        let hasAPIKey = AnthropicClient.hasAPIKey()
        logger.info("API key present: \(hasAPIKey)")

        if hasAPIKey {
            if let engine = summarizationEngine {
                Task {
                    await engine.start()
                }
            } else {
                logger.error("summarizationEngine is nil — cannot start summarization")
            }
        } else {
            logger.warning("No API key at \(AnthropicClient.apiKeyFileURL.path) — summarization disabled")
        }

        logger.info("All services started")
    }
}
