#!/bin/zsh
# Build CortexX.app — a double-clickable macOS bundle with the ENGINE INSIDE:
# launching the app boots cortexd automatically if none is running.
# Output: cortex-x/CortexX.app (one level up, easy to find and double-click).
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
(cd ../engine && cargo build --release -p cortexd)

APP=../CortexX.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CortexX "$APP/Contents/MacOS/CortexX"
cp ../engine/target/release/cortexd "$APP/Contents/Resources/cortexd"
cp Assets/CortexX.icns "$APP/Contents/Resources/CortexX.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>CortexX</string>
    <key>CFBundleDisplayName</key><string>CORTEX</string>
    <key>CFBundleIdentifier</key><string>com.mtxlabs.cortexx</string>
    <key>CFBundleVersion</key><string>0.1.0</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>CortexX</string>
    <key>CFBundleIconFile</key><string>CortexX</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>(c) 2026 MTX Labs. All rights reserved.</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP"

# Deploy copies where the operator double-clicks: cortex folder root + /Applications.
for DEST in ../../CortexX.app /Applications/CortexX.app; do
  rm -rf "$DEST" && ditto "$APP" "$DEST" && echo "deployed $DEST" || echo "deploy skipped: $DEST"
done
