#!/usr/bin/env bash
# reset-all.sh — Reset ContextD to a clean state for testing.
# Kills the running app, resets permissions, and optionally deletes the database.
#
# Usage:
#   ./scripts/reset-all.sh           # reset permissions only
#   ./scripts/reset-all.sh --db      # also delete the database
#   ./scripts/reset-all.sh --full    # reset everything + clean build

set -euo pipefail

BUNDLE_ID="com.contextd.app"
PRODUCT="ContextD"
DB_PATH="$HOME/Library/Application Support/ContextD/contextd.sqlite"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

echo -e "${CYAN}ContextD Reset${RESET}"
echo "──────────────────────────────────"

# Kill running instances
if pgrep -f "${PRODUCT}" > /dev/null 2>&1; then
    echo -e "${YELLOW}Killing running ContextD processes...${RESET}"
    pkill -f "${PRODUCT}" 2>/dev/null || true
    sleep 1
    echo -e "${GREEN}  Done.${RESET}"
else
    echo -e "  No running instances found."
fi

# Reset permissions
echo -e "${YELLOW}Resetting macOS permissions...${RESET}"
tccutil reset ScreenCapture "${BUNDLE_ID}" 2>/dev/null || echo "  (ScreenCapture reset skipped)"
tccutil reset Accessibility "${BUNDLE_ID}" 2>/dev/null || echo "  (Accessibility reset skipped)"
echo -e "${GREEN}  Permissions reset. You'll be prompted again on next launch.${RESET}"

# Reset UserDefaults
echo -e "${YELLOW}Resetting UserDefaults...${RESET}"
defaults delete "${BUNDLE_ID}" 2>/dev/null || echo "  (No defaults to delete)"
echo -e "${GREEN}  Done.${RESET}"

# Delete database
case "${1:-}" in
    --db|--full)
        echo ""
        echo -e "${RED}Deleting database...${RESET}"
        rm -f "$DB_PATH" "${DB_PATH}-wal" "${DB_PATH}-shm"
        echo -e "${GREEN}  Database deleted.${RESET}"
        ;;
esac

# Clean build
case "${1:-}" in
    --full)
        echo ""
        echo -e "${YELLOW}Cleaning build artifacts...${RESET}"
        swift package clean 2>/dev/null || true
        rm -rf .build
        echo -e "${GREEN}  Build cleaned.${RESET}"
        ;;
esac

echo ""
echo -e "${GREEN}Reset complete.${RESET}"
echo "Run 'make run' or './scripts/dev.sh' to start fresh."
