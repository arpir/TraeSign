#!/bin/bash
# 构建并打包 TraeSign 为 macOS 菜单栏应用 (.app, LSUIElement 代理模式，无 Dock 图标)
# 产物为「通用二进制 / Universal 2」：同时内嵌 x86_64 与 arm64 两种架构，
# 在 Intel 与 Apple Silicon (M1/M2/M3...) 上均原生运行，无需 Rosetta 2。
#
# 说明：本机 SwiftPM（swift build）因环境损坏不可用，这里直接用 swiftc 编译。
set -e
cd "$(dirname "$0")"

# 两种目标架构：Intel 的 x86_64 与 Apple Silicon 的 arm64
ARCHS=("x86_64" "arm64")
MINMACOS="12.0"

mkdir -p .build_traesing

SRCS="Sources/TraeSign/*.swift Sources/TraeSign/UI/*.swift"

# 逐个架构交叉编译（arm64 可在 x86_64 宿主上交叉编译，因为 macOS SDK 自带 arm64 切片）
for ARCH in "${ARCHS[@]}"; do
  TARGET="$ARCH-apple-macosx$MINMACOS"
  OUT=".build_traesing/TraeSign_$ARCH"
  echo "==> [$ARCH] swiftc 编译 (target $TARGET)"
  swiftc -target "$TARGET" -O \
    -o "$OUT" \
    $SRCS
  if [ ! -f "$OUT" ]; then
    echo "构建失败：未找到 $OUT" >&2
    exit 1
  fi
  echo "    -> $OUT ($(file -b "$OUT" | head -1))"
done

# 用 lipo 把两个架构合并成通用二进制
COMBINED=".build_traesing/TraeSign"
rm -f "$COMBINED"
echo "==> lipo 合并为通用二进制"
lipo -create -output "$COMBINED" \
  .build_traesing/TraeSign_x86_64 \
  .build_traesing/TraeSign_arm64
echo "    -> $(lipo -info "$COMBINED")"

APP="TraeSign.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$COMBINED" "$APP/Contents/MacOS/TraeSign"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>TraeSign</string>
    <key>CFBundleDisplayName</key>     <string>TraeSign</string>
    <key>CFBundleExecutable</key>      <string>TraeSign</string>
    <key>CFBundleIdentifier</key>      <string>com.traesign.macos</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>12.0</string>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <key>NSLocalNetworkUsageDescription</key> <string>TraeSign 需要访问本地网络以完成登录授权回调轮询。</string>
</dict>
</plist>
EOF

# 对通用二进制做 ad-hoc 签名（无开发者证书也可在本地运行）
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "（codesign 跳过，非必需）"

echo "==> 已生成 $APP"
echo "    架构: $(lipo -info "$APP/Contents/MacOS/TraeSign")"
echo "    双击运行，或执行: open $APP"
echo "    数据目录: ~/Library/Application Support/TraeSign"
echo ""
echo "提示：若你的环境 SwiftPM 正常，也可改用 'swift build -c release' 后手动替换 .app 内的可执行文件。"
