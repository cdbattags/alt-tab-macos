#!/usr/bin/env bash

set -e

# Build script for AltTab
# Usage: ./scripts/build_app.sh [Debug|Release] [--install|-i] [--launch|-l]
# Default: Debug
# Options:
#   --install, -i: Install to /Applications after build
#   --launch, -l: Launch after install (implies --install)

BUILD_CONFIG="${1:-Debug}"
DO_INSTALL=false
DO_LAUNCH=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --install|-i)
            DO_INSTALL=true
            ;;
        --launch|-l)
            DO_INSTALL=true
            DO_LAUNCH=true
            ;;
        Debug|Release)
            # Already handled
            ;;
    esac
done

echo "🔨 Building ${BUILD_CONFIG} configuration..."

# Determine scheme based on config
SCHEME="${BUILD_CONFIG}"

# Create logs directory if it doesn't exist
mkdir -p logs

# Set log file path with timestamp
LOG_FILE="logs/build_$(date +%Y%m%d_%H%M%S).log"

# Build the project
set -o pipefail && xcodebuild \
    -workspace alt-tab-macos.xcworkspace \
    -scheme "${SCHEME}" \
    -configuration "${BUILD_CONFIG}" \
    build 2>&1 | tee "${LOG_FILE}" | tail -20

echo ""
echo "📝 Full build log saved to: ${LOG_FILE}"

echo ""
echo "✅ Build succeeded!"

# Install if requested
if [ "$DO_INSTALL" = true ]; then
    echo ""
    if [ "$DO_LAUNCH" = true ]; then
        ./scripts/install_local_build.sh "${BUILD_CONFIG}" --launch
    else
        ./scripts/install_local_build.sh "${BUILD_CONFIG}"
    fi
fi
