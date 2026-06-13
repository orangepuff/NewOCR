#!/bin/zsh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_BUNDLE="$APP_DIR/NewOCR.app"
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"

mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$RESOURCES_DIR"
touch "$APP_DIR/config.txt"

if [[ ! -f "$APP_DIR/OCRInstruction" ]]; then
  cat > "$APP_DIR/OCRInstruction" <<'EOF'
AppleVision uses Apple's local Vision framework to detect text.
It writes per-page Markdown files first, then can produce combined text or EPUB later.

EOF
fi

if python3 -c "import PIL" >/dev/null 2>&1; then
  python3 "$APP_DIR/Sources/make_icon.py"
else
  echo "Pillow is not installed; using existing iconset."
fi
iconutil -c icns "$APP_DIR/Assets/NewOCR.iconset" -o "$RESOURCES_DIR/NewOCR.icns"

swiftc \
  -parse-as-library \
  "$APP_DIR/Sources/NewOCRApp.swift" \
  -o "$APP_BUNDLE/Contents/MacOS/NewOCR" \
  -framework SwiftUI \
  -framework AppKit \
  -framework PDFKit \
  -framework Vision \
  -framework WebKit

chmod +x "$APP_BUNDLE/Contents/MacOS/NewOCR"

echo "Built $APP_BUNDLE"
