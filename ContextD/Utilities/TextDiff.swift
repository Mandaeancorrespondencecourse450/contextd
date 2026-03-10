import Foundation

/// Utilities for text comparison and deduplication.
enum TextDiff {

    /// Compute Jaccard similarity between two strings based on word sets.
    /// Returns a value between 0.0 (completely different) and 1.0 (identical).
    static func jaccardSimilarity(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.normalizedForDedup.split(separator: " ").map(String.init))
        let wordsB = Set(b.normalizedForDedup.split(separator: " ").map(String.init))

        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        guard union > 0 else { return 1.0 }
        return Double(intersection) / Double(union)
    }

    /// Check if two OCR text outputs are similar enough to be considered duplicates.
    /// Default threshold is 0.9 (90% word overlap).
    static func isDuplicate(_ a: String, _ b: String, threshold: Double = 0.9) -> Bool {
        // Fast path: exact hash match
        if a.normalizedForDedup.sha256Hash == b.normalizedForDedup.sha256Hash {
            return true
        }
        return jaccardSimilarity(a, b) >= threshold
    }
}
