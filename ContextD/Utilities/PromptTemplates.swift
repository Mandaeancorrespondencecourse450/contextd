import Foundation

/// Default and configurable prompt templates for summarization and enrichment.
/// All templates use simple {placeholder} substitution.
enum PromptTemplates {

    // MARK: - Summarization

    static let summarizationSystem = """
        You are a computer activity summarizer. Your job is to summarize what a user \
        was doing on their computer during a time window, based on OCR text extracted \
        from their screen.

        The screen data is organized as keyframes (full screen snapshots) and deltas \
        (only the text that changed between snapshots). Use keyframes to understand \
        the overall context and deltas to track specific changes.

        Focus on:
        - What the user was doing (reading, coding, browsing, chatting, etc.)
        - What specific content they were looking at
        - Any key information visible (names, code, URLs, errors, data, etc.)

        Extract key topics and entities that would help find this activity later.

        Respond ONLY in this JSON format (no markdown, no explanation):
        {"summary": "...", "key_topics": ["topic1", "topic2", ...]}
        """

    static let summarizationUser = """
        Summarize this computer activity segment:

        Time: {start_time} to {end_time}
        Duration: {duration}
        Application: {app_name}
        Window: {window_title}

        Screen activity (keyframes show full screen, deltas show only what changed):
        {ocr_samples}
        """

    // MARK: - Enrichment Pass 1: Relevance Judging

    static let enrichmentPass1System = """
        You are a relevance judge for a context enrichment system. The user has written \
        a prompt they want to send to an AI, and you need to identify which of their recent \
        computer activities are relevant to that prompt.

        The user's prompt likely references things they recently saw on their screen. Your job \
        is to find those references.

        Respond ONLY in this JSON format (no markdown, no explanation):
        [{"id": <summary_id>, "reason": "brief explanation of relevance"}, ...]

        If nothing is relevant, respond with an empty array: []
        """

    static let enrichmentPass1User = """
        ## User's Prompt
        {query}

        ## Recent Activity Summaries
        {summaries}

        Which summaries contain information the user might be referring to or that would \
        provide useful context for their prompt?
        """

    // MARK: - Enrichment Pass 2: Context Synthesis

    static let enrichmentPass2System = """
        You are a context enrichment assistant. Given a user's prompt and detailed screen \
        captures from their recent computer activity, produce contextual references that \
        should be appended to the user's prompt to give an AI full context.

        Rules:
        - Only include genuinely relevant information
        - Be concise but specific — include exact names, values, code snippets, etc.
        - Format as markdown footnotes: [^1]: (time, app) description
        - Order by relevance (most relevant first)
        - Maximum 10 references

        Respond ONLY with the footnotes, nothing else. Example:
        [^1]: (2 min ago, VS Code) The parseConfig function in src/config/parser.ts was modified...
        [^2]: (5 min ago, Terminal) npm test showed 3 failing tests...
        """

    static let enrichmentPass2User = """
        ## User's Prompt
        {query}

        ## Detailed Screen Activity
        {captures}

        Produce markdown footnotes with relevant context for the user's prompt.
        """

    // MARK: - Template Rendering

    /// Render a template by replacing {placeholder} tokens with values.
    static func render(_ template: String, values: [String: String]) -> String {
        var result = template
        for (key, value) in values {
            result = result.replacingOccurrences(of: "{\(key)}", with: value)
        }
        return result
    }
}

// MARK: - UserDefaults Keys for Custom Templates

extension PromptTemplates {
    /// UserDefaults keys for user-customized prompt templates.
    enum SettingsKey: String {
        case summarizationSystem = "prompt_summarization_system"
        case summarizationUser = "prompt_summarization_user"
        case enrichmentPass1System = "prompt_enrichment_pass1_system"
        case enrichmentPass1User = "prompt_enrichment_pass1_user"
        case enrichmentPass2System = "prompt_enrichment_pass2_system"
        case enrichmentPass2User = "prompt_enrichment_pass2_user"
    }

    /// Get a template, preferring the user's custom version from UserDefaults.
    static func template(for key: SettingsKey) -> String {
        if let custom = UserDefaults.standard.string(forKey: key.rawValue), !custom.isEmpty {
            return custom
        }
        switch key {
        case .summarizationSystem: return summarizationSystem
        case .summarizationUser: return summarizationUser
        case .enrichmentPass1System: return enrichmentPass1System
        case .enrichmentPass1User: return enrichmentPass1User
        case .enrichmentPass2System: return enrichmentPass2System
        case .enrichmentPass2User: return enrichmentPass2User
        }
    }
}
