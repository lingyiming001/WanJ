#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/压缩助手.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx12.0" Sources/main.swift Sources/ArchiveEngine.swift -o "$APP/Contents/MacOS/ArchiveAssistant" -framework Cocoa -framework UniformTypeIdentifiers
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ArchiveAssistant</string>
<key>CFBundleIdentifier</key><string>local.heart.archive-assistant</string>
<key>CFBundleName</key><string>压缩助手</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>2.0</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
print "已生成：$APP"
