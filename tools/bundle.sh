#!/usr/bin/env bash
# 把 SwiftPM 的裸可执行文件组装成 .app，ad-hoc 签名，打 zip。
#
# 为什么不用 xcodebuild：这个仓库没有 .xcodeproj，也不打算有。
# SwiftPM 的产物是 Contents/MacOS/ 里的一个可执行文件，其余（Info.plist、
# 图标、签名）手工补齐即可，比维护一套 pbxproj 便宜。
#
# 用法：
#   ./tools/bundle.sh                    # 版本取自 git describe
#   VERSION=0.1.0 ./tools/bundle.sh      # 指定版本
#   ARCHS="arm64" ./tools/bundle.sh      # 只出单架构（CI 上省一半时间）
#
# 产物：dist/mstore-db.app、dist/mstore-db-<version>-macos.zip、同名 .sha256
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="mstore-db"
BUNDLE_ID="com.migoric.mstore-db"

# 版本：优先 VERSION，否则从最近一个 tag 推。没有 tag 就退回 commit 计数，
# 保证 CFBundleVersion 单调递增（LaunchServices 靠它判断新旧）。
# 版本：优先 VERSION；否则取最近一个 tag；再没有就退到 0.1.0-dev.<sha>。
# CFBundleShortVersionString 必须是点分数字（可带 -suffix），所以不能直接用
# `git describe --always` 的裸 sha——LaunchServices 会拒收，Dock 里版本号显示为空。
if [ -z "${VERSION:-}" ]; then
    if TAG=$(git describe --tags --abbrev=0 2>/dev/null); then
        VERSION="${TAG#v}"
    else
        VERSION="0.1.0-dev.$(git rev-parse --short HEAD 2>/dev/null || echo local)"
    fi
fi
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"

# 默认出 universal：CI runner 是 arm64，而开发机可能是 Intel，
# 单架构产物在另一半机器上直接「无法打开」。
ARCHS="${ARCHS:-arm64 x86_64}"
arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

# SwiftPM 编译 manifest 时会自己套一层 sandbox-exec。在已经受限的 shell 里
# （本地评审沙箱、某些 CI 容器）这层嵌套会直接 `sandbox_apply: Operation not permitted`，
# 于是构建还没开始就报「Invalid manifest」。关掉它对产物没有任何影响。
SWIFT_FLAGS=(--disable-sandbox)

echo "==> 版本 $VERSION (build $BUILD)，架构: $ARCHS"
echo "==> swift build -c release ${arch_flags[*]}"
swift build -c release "${SWIFT_FLAGS[@]}" "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${SWIFT_FLAGS[@]}" "${arch_flags[@]}" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
test -x "$BIN" || { echo "::error::找不到可执行文件 $BIN"; exit 1; }

DIST="dist"
APP="$DIST/$APP_NAME.app"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" \
    tools/Info.plist.in > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

cp tools/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# ad-hoc 签名（-s -）。没有开发者账号也能让 Gatekeeper 走到「右键→打开」这一步；
# 完全不签名的包在 Apple Silicon 上会被直接拒绝执行。
echo "==> codesign (ad-hoc)"
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict "$APP"

ZIP_NAME="$APP_NAME-$VERSION-macos.zip"
ZIP="$DIST/$ZIP_NAME"
ditto -c -k --keepParent "$APP" "$ZIP"
# 摘要里不带 dist/ 前缀：用户把 zip 和 .sha256 放同一目录时，
# `shasum -a 256 -c xxx.zip.sha256` 才能直接过。写成 dist/xxx.zip 那一行永远找不到文件。
( cd "$DIST" && shasum -a 256 "$ZIP_NAME" > "$ZIP_NAME.sha256" )
cat "$ZIP.sha256"

echo
echo "产物："
echo "  $APP  ($(du -sh "$APP" | cut -f1))"
echo "  $ZIP  ($(du -sh "$ZIP" | cut -f1))"
lipo -archs "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/  架构: /'
