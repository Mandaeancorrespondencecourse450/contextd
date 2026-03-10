#!/usr/bin/env bash
# benchmark.sh — Measure capture pipeline performance.
# Builds and runs a quick benchmark of the screenshot + OCR pipeline.
# Useful for profiling on different machines.
#
# Usage:
#   ./scripts/benchmark.sh

set -euo pipefail

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RESET='\033[0m'

echo -e "${CYAN}ContextD Capture Pipeline Benchmark${RESET}"
echo "──────────────────────────────────────"
echo ""

# System info
echo -e "${CYAN}System:${RESET}"
echo "  macOS $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "  $(sysctl -n machdep.cpu.brand_string)"
echo "  $(sysctl -n hw.memsize | awk '{printf "%.0f GB RAM", $1/1073741824}')"
DISPLAY_RES=$(system_profiler SPDisplaysDataType 2>/dev/null | grep Resolution | head -1 | awk '{print $2, $3, $4}' || echo "unknown")
echo "  Display: ${DISPLAY_RES}"
echo ""

# Check if screencapture works (basic test)
echo -e "${CYAN}Testing screencapture (macOS built-in)...${RESET}"
TMPFILE=$(mktemp /tmp/contextd_bench_XXXX.png)
START=$(python3 -c 'import time; print(time.time())')
screencapture -x -C "$TMPFILE" 2>/dev/null
END=$(python3 -c 'import time; print(time.time())')
ELAPSED=$(python3 -c "print(f'{($END - $START)*1000:.0f}')")
SIZE=$(ls -lh "$TMPFILE" | awk '{print $5}')
RES=$(sips -g pixelWidth -g pixelHeight "$TMPFILE" 2>/dev/null | tail -2 | awk '{print $2}' | tr '\n' 'x' | sed 's/x$//')
echo "  Time: ${ELAPSED}ms"
echo "  Size: ${SIZE}"
echo "  Resolution: ${RES}"
rm -f "$TMPFILE"
echo ""

# Quick OCR benchmark using the system screencapture + Vision CLI
echo -e "${CYAN}Testing OCR performance (10 iterations)...${RESET}"
TMPFILE=$(mktemp /tmp/contextd_bench_XXXX.png)
screencapture -x -C "$TMPFILE" 2>/dev/null

# Use swift inline to benchmark Vision OCR
swift -O - <<'SWIFT' "$TMPFILE" 2>/dev/null || echo -e "${YELLOW}  (Inline Swift OCR benchmark skipped — run 'make build' first)${RESET}"
import Vision
import Foundation

guard CommandLine.arguments.count > 1 else { exit(1) }
let path = CommandLine.arguments[1]
guard let image = NSImage(contentsOfFile: path),
      let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("  Failed to load image")
    exit(1)
}

let iterations = 10
var totalTime: Double = 0
var charCount = 0

for i in 0..<iterations {
    let start = CFAbsoluteTimeGetCurrent()

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try? handler.perform([request])

    let elapsed = CFAbsoluteTimeGetCurrent() - start
    totalTime += elapsed

    if i == 0 {
        let results = request.results ?? []
        charCount = results.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").count
    }
}

let avg = (totalTime / Double(iterations)) * 1000
print("  Average OCR time: \(String(format: "%.0f", avg))ms")
print("  Characters recognized: \(charCount)")
print("  Iterations: \(iterations)")
SWIFT

rm -f "$TMPFILE"
echo ""

# Database size check
DB_PATH="$HOME/Library/Application Support/ContextD/contextd.sqlite"
if [ -f "$DB_PATH" ]; then
    echo -e "${CYAN}Database:${RESET}"
    SIZE=$(ls -lh "$DB_PATH" | awk '{print $5}')
    ROWS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM captures;" 2>/dev/null || echo "?")
    echo "  Size: ${SIZE}"
    echo "  Rows: ${ROWS}"
    if [ "$ROWS" != "?" ] && [ "$ROWS" -gt 0 ]; then
        echo ""
        echo -e "${CYAN}Frame Types:${RESET}"
        sqlite3 "$DB_PATH" "SELECT '  Keyframes: ' || COUNT(*) || ', avg ' || CAST(AVG(length(ocrText)) AS INT) || ' chars' FROM captures WHERE frameType = 'keyframe';" 2>/dev/null
        sqlite3 "$DB_PATH" "SELECT '  Deltas: ' || COUNT(*) || ', avg ' || CAST(AVG(length(ocrText)) AS INT) || ' delta chars' FROM captures WHERE frameType = 'delta';" 2>/dev/null
        echo ""
        echo -e "${CYAN}Storage:${RESET}"
        AVG_FULL=$(sqlite3 "$DB_PATH" "SELECT CAST(AVG(length(fullOcrText)) AS INT) FROM captures;" 2>/dev/null)
        AVG_OCR=$(sqlite3 "$DB_PATH" "SELECT CAST(AVG(length(ocrText)) AS INT) FROM captures;" 2>/dev/null)
        echo "  Avg fullOcrText size: ${AVG_FULL} chars/capture"
        echo "  Avg ocrText size: ${AVG_OCR} chars/capture"
    fi
fi

echo ""
echo -e "${GREEN}Benchmark complete.${RESET}"
