import Foundation

/// Two-pass LLM retrieval strategy for context enrichment.
///
/// Pass 1: Search summaries (FTS5 + recency) -> LLM judges relevance
/// Pass 2: Fetch detailed captures for relevant summaries -> LLM synthesizes footnotes
final class TwoPassLLMStrategy: EnrichmentStrategy, @unchecked Sendable {
    let name = "Two-Pass LLM"
    let strategyDescription = "Uses FTS5 search + LLM relevance judging, then detailed capture analysis"

    private let logger = DualLogger(category: "TwoPassLLM")

    /// Model for Pass 1 (cheap/fast, relevance judging).
    var pass1Model: String = "claude-haiku-4-5"

    /// Model for Pass 2 (can be more capable, context synthesis).
    var pass2Model: String = "claude-sonnet-4-6"

    /// Maximum summaries to send to Pass 1.
    var maxSummariesForPass1: Int = 30

    /// Maximum captures to send to Pass 2.
    var maxCapturesForPass2: Int = 50

    func enrich(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> EnrichedResult {
        let startTime = Date()

        // --- Pass 1: Broad retrieval over summaries ---
        let (relevantSummaryIds, allSummaries) = try await pass1RelevanceJudging(
            query: query,
            timeRange: timeRange,
            storageManager: storageManager,
            llmClient: llmClient
        )

        // --- Pass 2: Deep retrieval + synthesis ---
        var footnotes = ""
        var capturesExamined = 0

        if !relevantSummaryIds.isEmpty {
            let result = try await pass2ContextSynthesis(
                query: query,
                summaryIds: relevantSummaryIds,
                storageManager: storageManager,
                llmClient: llmClient
            )
            footnotes = result.footnotes
            capturesExamined = result.capturesExamined
        } else {
            // Fallback: if no summaries matched, try searching raw captures directly
            let fallbackResult = try await fallbackDirectCaptures(
                query: query,
                timeRange: timeRange,
                storageManager: storageManager,
                llmClient: llmClient
            )
            footnotes = fallbackResult.footnotes
            capturesExamined = fallbackResult.capturesExamined
        }

        // --- Build final result ---
        let enrichedPrompt: String
        if footnotes.isEmpty {
            enrichedPrompt = query + "\n\n_(No relevant context found from recent activity.)_"
        } else {
            enrichedPrompt = query + "\n\n---\n## Context References\n\n" + footnotes
        }

        let metadata = EnrichmentMetadata(
            strategy: name,
            timeRange: timeRange,
            summariesSearched: allSummaries.count,
            capturesExamined: capturesExamined,
            processingTime: Date().timeIntervalSince(startTime),
            pass1Model: pass1Model,
            pass2Model: pass2Model
        )

        return EnrichedResult(
            originalPrompt: query,
            enrichedPrompt: enrichedPrompt,
            references: [], // TODO: parse individual references from footnotes
            metadata: metadata
        )
    }

    // MARK: - Pass 1: Relevance Judging

    private func pass1RelevanceJudging(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> (relevantIds: [Int64], allSummaries: [SummaryRecord]) {
        // Gather summaries: FTS search + recent
        var summaries: [SummaryRecord] = []

        // FTS search
        let ftsResults = try storageManager.searchSummaries(query: query, limit: maxSummariesForPass1 / 2)
        summaries.append(contentsOf: ftsResults)

        // Recent summaries (within time range)
        let recentResults = try storageManager.summaries(
            from: timeRange.start,
            to: timeRange.end,
            limit: maxSummariesForPass1 / 2
        )
        summaries.append(contentsOf: recentResults)

        // Deduplicate by ID
        var seen = Set<Int64>()
        summaries = summaries.filter { summary in
            guard let id = summary.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }

        guard !summaries.isEmpty else {
            logger.info("Pass 1: No summaries found")
            return ([], [])
        }

        // Format summaries for the LLM
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "HH:mm:ss"

        let summariesText: String = summaries.enumerated().map { index, summary -> String in
            let apps = summary.decodedAppNames.joined(separator: ", ")
            let topics = summary.decodedKeyTopics.joined(separator: ", ")
            let id = summary.id ?? Int64(index)
            let start = dateFormatter.string(from: summary.startDate)
            let end = dateFormatter.string(from: summary.endDate)
            return "[\(id)]: \(start) - \(end)\nApps: \(apps)\nTopics: \(topics)\nSummary: \(summary.summary)"
        }.joined(separator: "\n\n")

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .enrichmentPass1User),
            values: [
                "query": query,
                "summaries": summariesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .enrichmentPass1System)

        let response = try await llmClient.complete(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass1Model,
            maxTokens: 1024,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        // Parse relevant IDs from response
        let relevantIds = parsePass1Response(response, validIds: Set(summaries.compactMap(\.id)))

        logger.info("Pass 1: \(summaries.count) summaries searched, \(relevantIds.count) relevant")
        return (relevantIds, summaries)
    }

    // MARK: - Pass 2: Context Synthesis

    private struct Pass2Result {
        let footnotes: String
        let capturesExamined: Int
    }

    private func pass2ContextSynthesis(
        query: String,
        summaryIds: [Int64],
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> Pass2Result {
        // Fetch summaries to get their capture IDs
        var allCaptureIds: [Int64] = []
        for summaryId in summaryIds {
            // Fetch the summary to get its capture IDs
            let summaries = try storageManager.summaries(
                from: Date.distantPast,
                to: Date.distantFuture,
                limit: 1000
            )
            if let summary = summaries.first(where: { $0.id == summaryId }) {
                allCaptureIds.append(contentsOf: summary.decodedCaptureIds)
            }
        }

        // Fetch the actual captures
        let captures = try storageManager.captures(ids: Array(Set(allCaptureIds)))
        let limitedCaptures = Array(captures.prefix(maxCapturesForPass2))

        guard !limitedCaptures.isEmpty else {
            return Pass2Result(footnotes: "", capturesExamined: 0)
        }

        // Format captures using hierarchical keyframe+delta format
        let capturesText = CaptureFormatter.formatHierarchical(
            captures: limitedCaptures,
            maxKeyframes: 10,
            maxDeltasPerKeyframe: 5,
            maxKeyframeTextLength: 3000,
            maxDeltaTextLength: 500
        )

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .enrichmentPass2User),
            values: [
                "query": query,
                "captures": capturesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .enrichmentPass2System)

        let footnotes = try await llmClient.complete(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass2Model,
            maxTokens: 2048,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        logger.info("Pass 2: Examined \(limitedCaptures.count) captures, generated footnotes")
        return Pass2Result(footnotes: footnotes, capturesExamined: limitedCaptures.count)
    }

    // MARK: - Fallback: Direct Capture Search

    private func fallbackDirectCaptures(
        query: String,
        timeRange: TimeRange,
        storageManager: StorageManager,
        llmClient: LLMClient
    ) async throws -> Pass2Result {
        // Search captures directly when no summaries exist yet
        var captures = try storageManager.searchCaptures(query: query, limit: 20)

        // Also get recent captures
        let recent = try storageManager.captures(
            from: timeRange.start,
            to: timeRange.end,
            limit: 20
        )

        // Merge and deduplicate
        var seen = Set<Int64>()
        captures = (captures + recent).filter { capture in
            guard let id = capture.id, !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }

        guard !captures.isEmpty else {
            return Pass2Result(footnotes: "", capturesExamined: 0)
        }

        // Use Pass 2 directly with hierarchical format
        let capturesText = CaptureFormatter.formatHierarchical(
            captures: Array(captures.prefix(maxCapturesForPass2)),
            maxKeyframes: 10,
            maxDeltasPerKeyframe: 5,
            maxKeyframeTextLength: 3000,
            maxDeltaTextLength: 500
        )

        let userPrompt = PromptTemplates.render(
            PromptTemplates.template(for: .enrichmentPass2User),
            values: [
                "query": query,
                "captures": capturesText,
            ]
        )

        let systemPrompt = PromptTemplates.template(for: .enrichmentPass2System)

        let footnotes = try await llmClient.complete(
            messages: [LLMMessage(role: "user", content: userPrompt)],
            model: pass2Model,
            maxTokens: 2048,
            systemPrompt: systemPrompt,
            temperature: 0.0
        )

        return Pass2Result(footnotes: footnotes, capturesExamined: captures.count)
    }

    // MARK: - Response Parsing

    /// Strip markdown code fences (```json ... ``` or ``` ... ```) from LLM output.
    private func stripCodeFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Remove opening fence: ```json or ```
        if s.hasPrefix("```") {
            if let endOfFirstLine = s.firstIndex(of: "\n") {
                s = String(s[s.index(after: endOfFirstLine)...])
            }
        }
        // Remove closing fence
        if s.hasSuffix("```") {
            s = String(s.dropLast(3))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse Pass 1 JSON response to extract relevant summary IDs.
    private func parsePass1Response(_ response: String, validIds: Set<Int64>) -> [Int64] {
        let cleaned = stripCodeFences(response)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            logger.warning("Failed to parse Pass 1 response as JSON array. Raw response:\n\(response)")
            return []
        }

        return json.compactMap { item -> Int64? in
            // JSONSerialization decodes JSON integers as NSNumber — try Int, Int64, Double
            if let intId = item["id"] as? Int {
                let id64 = Int64(intId)
                return validIds.contains(id64) ? id64 : nil
            }
            if let id64 = item["id"] as? Int64, validIds.contains(id64) {
                return id64
            }
            if let doubleId = item["id"] as? Double {
                let id64 = Int64(doubleId)
                return validIds.contains(id64) ? id64 : nil
            }
            return nil
        }
    }
}
