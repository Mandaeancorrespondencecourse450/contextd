#!/usr/bin/env bash
# db-inspect.sh — Interactive database inspection tool.
#
# Usage:
#   ./scripts/db-inspect.sh              # interactive menu
#   ./scripts/db-inspect.sh stats        # show statistics
#   ./scripts/db-inspect.sh recent [N]   # show N most recent captures (default: 10)
#   ./scripts/db-inspect.sh search TEXT  # full-text search
#   ./scripts/db-inspect.sh export       # export captures as JSON
#   ./scripts/db-inspect.sh tail         # continuously show new captures

set -euo pipefail

DB_PATH="$HOME/Library/Application Support/ContextD/contextd.sqlite"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
DIM='\033[2m'
RESET='\033[0m'

check_db() {
    if [ ! -f "$DB_PATH" ]; then
        echo -e "${RED}Database not found at: ${DB_PATH}${RESET}"
        echo "Run ContextD first to create the database."
        exit 1
    fi
}

cmd_stats() {
    check_db
    echo -e "${CYAN}Database Statistics${RESET}"
    echo "──────────────────────────────────"
    SIZE=$(ls -lh "$DB_PATH" | awk '{print $5}')
    echo -e "  File size:       ${GREEN}${SIZE}${RESET}"
    echo ""

    sqlite3 "$DB_PATH" <<'SQL'
.mode list
SELECT '  Captures:        ' || COUNT(*) FROM captures;
SELECT '  Keyframes:       ' || COUNT(*) FROM captures WHERE frameType = 'keyframe';
SELECT '  Deltas:          ' || COUNT(*) FROM captures WHERE frameType = 'delta';
SELECT '  Summarized:      ' || COUNT(*) FROM captures WHERE isSummarized = 1;
SELECT '  Unsummarized:    ' || COUNT(*) FROM captures WHERE isSummarized = 0;
SELECT '  Summaries:       ' || COUNT(*) FROM summaries;
SQL

    echo ""
    echo -e "${CYAN}Time Range${RESET}"
    sqlite3 "$DB_PATH" <<'SQL'
.mode list
SELECT '  Oldest capture:  ' || COALESCE(datetime(MIN(timestamp), 'unixepoch', 'localtime'), 'none') FROM captures;
SELECT '  Newest capture:  ' || COALESCE(datetime(MAX(timestamp), 'unixepoch', 'localtime'), 'none') FROM captures;
SQL

    echo ""
    echo -e "${CYAN}Top Applications${RESET}"
    sqlite3 "$DB_PATH" <<'SQL'
.mode list
SELECT '  ' || appName || ': ' || COUNT(*) || ' captures'
FROM captures
GROUP BY appName
ORDER BY COUNT(*) DESC
LIMIT 10;
SQL

    echo ""
    echo -e "${CYAN}Captures per Hour (last 24h)${RESET}"
    sqlite3 "$DB_PATH" <<'SQL'
.mode list
SELECT '  ' || strftime('%Y-%m-%d %H:00', timestamp, 'unixepoch', 'localtime') || '  ' || COUNT(*) || ' captures'
FROM captures
WHERE timestamp > strftime('%s', 'now', '-24 hours')
GROUP BY strftime('%Y-%m-%d %H', timestamp, 'unixepoch', 'localtime')
ORDER BY 1;
SQL
}

cmd_recent() {
    check_db
    local limit="${1:-10}"
    echo -e "${CYAN}Last ${limit} captures${RESET}"
    echo ""
    sqlite3 -header -column "$DB_PATH" \
        "SELECT id,
            datetime(timestamp, 'unixepoch', 'localtime') AS time,
            frameType AS type,
            appName AS app,
            length(fullOcrText) AS full_chars,
            length(ocrText) AS ocr_chars,
            CASE WHEN isSummarized THEN 'yes' ELSE 'no' END AS summ
        FROM captures
        ORDER BY timestamp DESC
        LIMIT ${limit};"
}

cmd_search() {
    check_db
    local query="$1"
    echo -e "${CYAN}Searching captures for: ${query}${RESET}"
    echo ""
    sqlite3 -header -column "$DB_PATH" \
        "SELECT captures.id,
            datetime(captures.timestamp, 'unixepoch', 'localtime') AS time,
            captures.frameType AS type,
            captures.appName AS app,
            substr(captures.fullOcrText, 1, 120) AS text_preview
        FROM captures
        JOIN captures_fts ON captures.id = captures_fts.rowid
        WHERE captures_fts MATCH '\"${query}\"'
        ORDER BY rank
        LIMIT 20;"
}

cmd_export() {
    check_db
    echo -e "${CYAN}Exporting captures as JSON...${RESET}" >&2
    sqlite3 "$DB_PATH" <<'SQL'
.mode json
SELECT id, datetime(timestamp, 'unixepoch', 'localtime') AS time,
    appName, appBundleID, windowTitle, frameType, keyframeId,
    changePercentage, ocrText, fullOcrText, visibleWindows, isSummarized
FROM captures
ORDER BY timestamp DESC;
SQL
}

cmd_tail() {
    check_db
    echo -e "${CYAN}Tailing new captures (Ctrl+C to stop)...${RESET}"
    echo ""

    local last_id
    last_id=$(sqlite3 "$DB_PATH" "SELECT COALESCE(MAX(id), 0) FROM captures;")

    while true; do
        local new_rows
        new_rows=$(sqlite3 -header -column "$DB_PATH" \
            "SELECT id,
                datetime(timestamp, 'unixepoch', 'localtime') AS time,
                frameType AS type,
                appName AS app,
                COALESCE(windowTitle, '') AS window,
                length(fullOcrText) AS chars
            FROM captures
            WHERE id > ${last_id}
            ORDER BY id ASC;")

        if [ -n "$new_rows" ]; then
            echo "$new_rows"
            last_id=$(sqlite3 "$DB_PATH" "SELECT MAX(id) FROM captures;")
        fi

        sleep 2
    done
}

cmd_capture_detail() {
    check_db
    local capture_id="$1"
    echo -e "${CYAN}Capture #${capture_id}${RESET}"
    echo ""
    sqlite3 "$DB_PATH" <<SQL
.mode line
SELECT id, datetime(timestamp, 'unixepoch', 'localtime') AS time,
    appName, appBundleID, windowTitle,
    frameType, keyframeId,
    printf('%.1f%%', changePercentage * 100) AS changePercent,
    length(fullOcrText) AS fullOcrTextLength,
    length(ocrText) AS ocrTextLength,
    isSummarized, textHash
FROM captures WHERE id = ${capture_id};
SQL
    echo ""
    echo -e "${CYAN}Full OCR Text:${RESET}"
    echo "──────────────────────────────────"
    sqlite3 "$DB_PATH" "SELECT fullOcrText FROM captures WHERE id = ${capture_id};"

    # Show delta text separately for delta frames
    local frame_type
    frame_type=$(sqlite3 "$DB_PATH" "SELECT frameType FROM captures WHERE id = ${capture_id};")
    if [ "$frame_type" = "delta" ]; then
        echo ""
        echo -e "${YELLOW}Delta Text (changed regions only):${RESET}"
        echo "──────────────────────────────────"
        sqlite3 "$DB_PATH" "SELECT ocrText FROM captures WHERE id = ${capture_id};"
    fi
}

cmd_interactive() {
    echo -e "${CYAN}ContextD Database Inspector${RESET}"
    echo ""
    echo "  1) Statistics"
    echo "  2) Recent captures"
    echo "  3) Search captures"
    echo "  4) View capture detail"
    echo "  5) Recent summaries"
    echo "  6) Export JSON"
    echo "  7) Tail (live)"
    echo "  q) Quit"
    echo ""

    while true; do
        echo -n -e "${GREEN}> ${RESET}"
        read -r choice
        case "$choice" in
            1) cmd_stats ;;
            2)
                echo -n "How many? [10] "
                read -r n
                cmd_recent "${n:-10}"
                ;;
            3)
                echo -n "Search query: "
                read -r q
                cmd_search "$q"
                ;;
            4)
                echo -n "Capture ID: "
                read -r cid
                cmd_capture_detail "$cid"
                ;;
            5)
                check_db
                sqlite3 -header -column "$DB_PATH" \
                    "SELECT id,
                        datetime(startTimestamp, 'unixepoch', 'localtime') AS start,
                        datetime(endTimestamp, 'unixepoch', 'localtime') AS end,
                        appNames AS apps,
                        substr(summary, 1, 100) AS summary_preview
                    FROM summaries ORDER BY endTimestamp DESC LIMIT 10;"
                ;;
            6) cmd_export ;;
            7) cmd_tail ;;
            q|Q|exit) break ;;
            *) echo "Unknown option: $choice" ;;
        esac
        echo ""
    done
}

# ── Main ──

case "${1:-}" in
    stats)    cmd_stats ;;
    recent)   cmd_recent "${2:-10}" ;;
    search)   shift; cmd_search "$*" ;;
    export)   cmd_export ;;
    tail)     cmd_tail ;;
    detail)   cmd_capture_detail "${2:?Usage: db-inspect.sh detail <id>}" ;;
    *)        cmd_interactive ;;
esac
