#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 scripts/setup-signing.py
xcodegen generate --quiet
xcodebuild -project Weft.xcodeproj -scheme Weft -derivedDataPath build/DerivedData "$@" build
python3 scripts/verify-signing.py build/DerivedData/Build/Products/Debug/Weft.app
