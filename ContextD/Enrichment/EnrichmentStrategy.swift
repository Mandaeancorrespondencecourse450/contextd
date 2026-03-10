import Foundation

/// How far back in time to look for context.
struct TimeRange: Sendable {
    let start: Date
    let end: Date

    /// Create a time range going back from now.
    static func last(minutes: Int) -> TimeRange {
        let end = Date()
        let start = end.addingTimeInterval(-Double(minutes * 60))
        return TimeRange(start: start, end: end)
    }

    static func last(hours: Int) -> TimeRange {
        last(minutes: hours * 60)
    }

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }

    var description: String {
        let minutes = Int(duration / 60)
        if minutes < 60 {
            return "Last \(minutes) min"
        }
        return "Last \(minutes / 60)h \(minutes % 60)m"
    }
}

/// A single context reference produced by the enrichment engine.
struct ContextReference: Sendable {
    let timestamp: Date
    let appName: String
    let windowTitle: String?
    let relevantText: String
    let relevanceExplanation: String
}

/// Metadata about the enrichment process.
struct EnrichmentMetadata: Sendable {
    let strategy: String
    let timeRange: TimeRange
    let summariesSearched: Int
    let capturesExamined: Int
    let processingTime: TimeInterval
    let pass1Model: String
    let pass2Model: String?
}

/// The result of an enrichment operation.
struct EnrichedResult: Sendable {
    /// The user's original prompt, unchanged.
    let originalPrompt: String

    /// The fully enriched prompt (original + context references).
    let enrichedPrompt: String

    /// Individual context references that were appended.
    let references: [ContextReference]

    /// Metadata about how the enrichment was performed.
    let metadata: EnrichmentMetadata
}

/// Protocol for enrichment strategies.
/// Implementations define how context is retrieved and synthesized.
protocol EnrichmentStrategy: Sendable {
    /// Human-readable name of this strategy.
    var name: String { get }

    /// Description of how this strategy works.
    var strategyDescription: String { get }

    /// Perform enrichment on a user query.
    /// - Parameters:
    ///   - query: The user's prompt to enrich.
    ///   - timeRange: How far back to search.
    ///   - storageManager: Access to the capture/summary database.
    ///   - llmClient: LLM for retrieval and synthesis.
    /// - Returns: The enriched result with context references.
    func enrich(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> EnrichedResult
}
