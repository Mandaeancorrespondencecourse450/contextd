import Foundation

/// Coordinates enrichment by selecting and running the active strategy.
/// Provides the main entry point for the UI to request enrichment.
@MainActor
final class EnrichmentEngine: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var lastResult: EnrichedResult?
    @Published var lastError: String?

    /// Available enrichment strategies.
    let strategies: [EnrichmentStrategy]

    /// Index of the currently active strategy.
    @Published var activeStrategyIndex: Int = 0

    private let storageManager: StorageManager
    private let llmClient: LLMClient
    private let logger = DualLogger(category: "Enrichment")

    var activeStrategy: EnrichmentStrategy {
        strategies[activeStrategyIndex]
    }

    init(storageManager: StorageManager, llmClient: LLMClient) {
        self.storageManager = storageManager
        self.llmClient = llmClient

        // Register available strategies
        self.strategies = [
            TwoPassLLMStrategy(),
        ]
    }

    /// Enrich a user prompt with context from recent screen activity.
    /// - Parameters:
    ///   - query: The user's prompt text.
    ///   - timeRange: How far back to search for context.
    /// - Returns: The enriched result.
    @discardableResult
    func enrich(query: String, timeRange: TimeRange = .last(minutes: 30)) async -> EnrichedResult? {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Please enter a prompt to enrich."
            return nil
        }

        isProcessing = true
        lastError = nil
        lastResult = nil

        do {
            let result = try await activeStrategy.enrich(
                query: query,
                timeRange: timeRange,
                storageManager: storageManager,
                llmClient: llmClient
            )

            lastResult = result
            isProcessing = false

            logger.info("Enrichment complete: \(result.metadata.summariesSearched) summaries, \(result.metadata.capturesExamined) captures, \(String(format: "%.1f", result.metadata.processingTime))s")

            return result

        } catch {
            lastError = error.localizedDescription
            isProcessing = false
            logger.error("Enrichment failed: \(error.localizedDescription)")
            return nil
        }
    }
}
