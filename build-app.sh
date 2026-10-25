#!/bin/zsh
# Compila en release y empaqueta build/DJ Library.app
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product DJLibrary

APP="build/DJ Library.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DJLibrary "$APP/Contents/MacOS/DJLibrary"

# Icono: Icon/make-icon.swift → .iconset → AppIcon.icns
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
swift Icon/make-icon.swift build/icon-1024.png >/dev/null
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DJ Library</string>
    <key>CFBundleDisplayName</key><string>DJ Library</string>
    <key>CFBundleIdentifier</key><string>com.bazookon.djlibrary</string>
    <key>CFBundleExecutable</key><string>DJLibrary</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Listo: $APP"
