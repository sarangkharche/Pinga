#!/bin/zsh
set -eu
cd "${0:A:h:h}"
swift build -c release
app="$PWD/dist/Pinga.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc Sources/PRPing/Logo.swift scripts/IconRenderer/main.swift -o .build/icon-renderer
.build/icon-renderer .build/PRPing.iconset
iconutil -c icns .build/PRPing.iconset -o "$app/Contents/Resources/PRPing.icns"
python3 scripts/compile-icon-catalog.py
xcrun actool .build/Pinga.xcassets --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 13.0 --app-icon Pinga --output-partial-info-plist .build/icon-info.plist --output-format human-readable-text
test -s "$app/Contents/Resources/Assets.car"
cp .build/release/PRPing "$app/Contents/MacOS/Pinga"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.sarang.pinga</string>
<key>CFBundleName</key><string>Pinga</string>
<key>CFBundleDisplayName</key><string>Pinga</string>
<key>CFBundleExecutable</key><string>Pinga</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.1</string>
<key>CFBundleVersion</key><string>7</string>
<key>CFBundleIconFile</key><string>PRPing.icns</string>
<key>CFBundleIconName</key><string>Pinga</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$app"
printf '%s\n' "$app"
