#!/usr/bin/env bash
# dev.sh — Build and run ContextD with live log streaming in a split view.
#
# Usage:
#   ./scripts/dev.sh          # build + run + stream logs
#   ./scripts/dev.sh --release # build release + run
#   ./scripts/dev.sh --logs-only # just stream logs (app already running)

set -euo pipefail

PRODUCT="ContextD"
SUBSYSTEM="com.contextd.app"
BUILD_DIR=".build"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
RESET='\033[0m'

cleanup() {
    echo ""
    echo -e "${YELLOW}Shutting down...${RESET}"
    # Kill background jobs
    jobs -p | xargs -r kill 2>/dev/null || true
    wait 2>/dev/null || true
    echo -e "${GREEN}Done.${RESET}"
}
trap cleanup EXIT INT TERM

case "${1:-}" in
    --logs-only)
        echo -e "${CYAN}Streaming logs for ${SUBSYSTEM}...${RESET}"
        log stream --predicate "subsystem == \"${SUBSYSTEM}\"" --style compact
        exit 0
        ;;
    --release)
        CONFIG="release"
        BIN="${BUILD_DIR}/release/${PRODUCT}"
        ;;
    *)
        CONFIG="debug"
        BIN="${BUILD_DIR}/debug/${PRODUCT}"
        ;;
esac

# Build
echo -e "${CYAN}Building (${CONFIG})...${RESET}"
if ! swift build -c "${CONFIG}" 2>&1; then
    echo -e "${RED}Build failed!${RESET}"
    exit 1
fi
echo -e "${GREEN}Build succeeded.${RESET}"
echo ""

# Check if the app is already running
if pgrep -f "${BIN}" > /dev/null 2>&1; then
    echo -e "${YELLOW}ContextD is already running. Killing previous instance...${RESET}"
    pkill -f "${BIN}" 2>/dev/null || true
    sleep 1
fi

# Start log streaming in background
echo -e "${CYAN}Starting log stream...${RESET}"
log stream --predicate "subsystem == \"${SUBSYSTEM}\"" --style compact &
LOG_PID=$!
sleep 0.5

# Run the app
echo -e "${CYAN}Starting ${PRODUCT}...${RESET}"
echo -e "${YELLOW}Press Ctrl+C to stop both the app and log stream${RESET}"
echo "────────────────────────────────────────"
"${BIN}"
