#!/bin/zsh
# 编译出 他妈的记录器.app（Intel + Apple 芯片通用），并打包成 zip 方便发给朋友
set -e
cd "$(dirname "$0")"

APP="build/他妈的记录器.app"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos12 Sources/main.swift -o build/tmd-$arch
done
lipo -create build/tmd-arm64 build/tmd-x86_64 -output "$APP/Contents/MacOS/TMDCounter"
rm build/tmd-*

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>他妈的记录器</string>
  <key>CFBundleDisplayName</key><string>他妈的记录器</string>
  <key>CFBundleIdentifier</key><string>app.tmdcounter</string>
  <key>CFBundleExecutable</key><string>TMDCounter</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
EOF

codesign --force --deep -s - "$APP"
(cd build && ditto -c -k --keepParent "他妈的记录器.app" "他妈的记录器.zip")
echo "✅ 完成：build/他妈的记录器.app 和 build/他妈的记录器.zip"
