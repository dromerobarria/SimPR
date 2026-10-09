#!/usr/bin/env bash
# Runs the SimPRCore unit tests and builds the app (unsigned, Debug).
set -euo pipefail
cd "$(dirname "$0")/.."
# Build products live outside ~/Documents to avoid slow TCC checks when tests fail.
SCRATCH="${SCRATCH:-$HOME/Library/Developer/SimPR-build}"
swift test --package-path SimPRCore --scratch-path "$SCRATCH/core"
if command -v xcodegen >/dev/null 2>&1; then xcodegen generate --spec project.yml >/dev/null; fi
xcodebuild -project SimPR.xcodeproj -scheme SimPR -configuration Debug \
  -derivedDataPath "$HOME/Library/Developer/Xcode/DerivedData/SimPR-cli" build | tail -1
