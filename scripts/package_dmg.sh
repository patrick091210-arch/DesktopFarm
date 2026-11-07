#!/usr/bin/env bash
# =============================================================================
# DesktopHarvest (桌面牧场) — Zero-Dependency macOS Release DMG Packager
# Usage:
#   bash scripts/package_dmg.sh
#   VERSION=1.0.0 bash scripts/package_dmg.sh
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PROJECT="DesktopFarm.xcodeproj"
SCHEME="DesktopFarm"
APP_NAME="DesktopHarvest.app"
VOLUME_NAME="DesktopHarvest"
DERIVED_DATA_DIR="$ROOT_DIR/.build/DerivedData"
STAGING_DIR="$ROOT_DIR/.build/dmg_staging"
DIST_DIR="$ROOT_DIR/dist"

if [[ -z "${DEVELOPER_DIR:-}" && -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

# 1. Resolve MARKETING_VERSION (env override > pbxproj > fallback 1.0.0)
if [[ -z "${VERSION:-}" ]]; then
  VERSION="$(grep -m1 'MARKETING_VERSION =' "$PROJECT/project.pbxproj" \
    | sed -E 's/.*MARKETING_VERSION = ([^;]+);.*/\1/' \
    | tr -d '[:space:]"')"
fi
VERSION="${VERSION#v}"
VERSION="${VERSION:-1.0.0}"

DMG_NAME="DesktopHarvest-v${VERSION}.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
SHA_PATH="${DMG_PATH}.sha256"
LATEST_DMG_NAME="DesktopHarvest.dmg"
LATEST_DMG_PATH="$DIST_DIR/$LATEST_DMG_NAME"
LATEST_SHA_PATH="${LATEST_DMG_PATH}.sha256"

echo "=================================================================="
echo "🌾 Packaging DesktopHarvest v${VERSION} (Release DMG)"
echo "=================================================================="

# 2. Clean & prepare staging and output directories
echo "👉 [1/5] Preparing build & staging directories..."
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR" "$DIST_DIR"
rm -f "$DMG_PATH" "$SHA_PATH"

# 3. Build Release binary (attempt Universal Binary arm64 + x86_64 first, fallback to host arch)
echo "👉 [2/5] Building Release configuration via xcodebuild..."
if xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  DEPLOYMENT_POSTPROCESSING=YES \
  STRIP_INSTALLED_PRODUCT=YES \
  STRIP_STYLE=all \
  COPY_PHASE_STRIP=YES \
  CODE_SIGN_IDENTITY="-" \
  clean build >/dev/null; then
  echo "   ✓ Built Universal Binary (arm64 + x86_64) Release bundle."
else
  echo "   ⚠️ Universal build unavailable on current toolchain; building host architecture Release bundle..."
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    DEPLOYMENT_POSTPROCESSING=YES \
    STRIP_INSTALLED_PRODUCT=YES \
    STRIP_STYLE=all \
    COPY_PHASE_STRIP=YES \
    CODE_SIGN_IDENTITY="-" \
    clean build >/dev/null
fi

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "❌ Error: Built app not found at $BUILT_APP" >&2
  exit 1
fi

# Verify required TCC usage descriptions exist in compiled Info.plist
BUILT_PLIST="$BUILT_APP/Contents/Info.plist"
for KEY in NSDesktopFolderUsageDescription NSAppleEventsUsageDescription; do
  if ! /usr/libexec/PlistBuddy -c "Print :$KEY" "$BUILT_PLIST" >/dev/null 2>&1; then
    echo "❌ Error: Missing $KEY in $BUILT_PLIST" >&2
    exit 1
  fi
done
echo "   ✓ Verified Info.plist permission keys (NSDesktopFolderUsageDescription & NSAppleEventsUsageDescription)."

# 4. Copy to staging, strip extended attributes, and apply deep Ad-hoc signature
echo "👉 [3/5] Signing & verifying $APP_NAME (Ad-hoc)..."
ditto "$BUILT_APP" "$STAGING_DIR/$APP_NAME"
xattr -cr "$STAGING_DIR/$APP_NAME"
codesign --force --deep --sign - "$STAGING_DIR/$APP_NAME"
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/$APP_NAME"

BINARY_PATH="$STAGING_DIR/$APP_NAME/Contents/MacOS/DesktopHarvest"
ARCH_INFO="$(lipo -info "$BINARY_PATH" 2>/dev/null || file "$BINARY_PATH")"
echo "   ✓ Binary info: $ARCH_INFO"

# 5. Populate DMG drag-to-install layout & first-launch guide
echo "👉 [4/5] Assembling DMG staging layout..."
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/首次打开说明 (必读).txt" <<EOF
====================================================================
🌾 DesktopHarvest · 桌面牧场 (v${VERSION}) — 首次安装与打开说明
====================================================================

1. 安装方法：
   将本窗口中的「DesktopHarvest.app」拖拽到「Applications（应用程序）」文件夹中。

2. 如何找到游戏入口：
   DesktopHarvest 是一款原生 macOS 状态栏应用（无 Dock 图标，不遮挡工作区）。
   启动后，请看屏幕右上角菜单栏的「🌾 120」图标：
   - 左键点击「🌾」：打开牧场控制台（商店、订单板、背包、加速与设置）。
   - 右键点击「🌾」：快捷打开桌面农场文件夹、全部浇水或收获。
   - 游戏会在您的桌面自动创建「~/Desktop/DesktopFarm」专属文件夹。

3. 首次打开提示「无法验证开发者」或「已损坏」怎么办？
   由于本开源项目采用本地 Ad-hoc 签名分发，未交纳 Apple 开发者年费公证，
   从浏览器下载后首次启动可能会被 macOS Gatekeeper 拦截。请任选以下一种方式解除：

   【方法 A（推荐，一行终端命令）】
   打开「终端 (Terminal.app)」，复制粘贴以下命令并回车：

     sudo xattr -rd com.apple.quarantine /Applications/DesktopHarvest.app

   （若无需 sudo 权限，也可直接运行：xattr -cr /Applications/DesktopHarvest.app）

   【方法 B（图形界面操作）】
   在「访达 (Finder) -> 应用程序」中按住 Control 键右键点击「DesktopHarvest.app」，
   选择「打开」；或前往「系统设置 -> 隐私与安全性」，在底部点击「仍要打开」。

4. 权限说明：
   - 桌面文件夹权限（必选）：仅用于在 ~/Desktop/DesktopFarm 内创建和更新农场文件，
     绝不触碰您桌面上的任何个人文件。
   - 自动化 -> Finder（可选）：允许后，浇水/收获悬浮按钮可精准跟随 Finder 窗口中的图标。
====================================================================
EOF

# 6. Build compressed UDZO DMG & SHA-256 checksum
echo "👉 [5/5] Creating compressed DMG archive..."
if command -v create-dmg >/dev/null 2>&1; then
  echo "   Using create-dmg..."
  if ! create-dmg \
    --volname "$VOLUME_NAME" \
    --window-pos 200 120 \
    --window-size 660 400 \
    --icon-size 110 \
    --icon "$APP_NAME" 180 190 \
    --hide-extension "$APP_NAME" \
    --app-drop-link 480 190 \
    "$DMG_PATH" \
    "$STAGING_DIR" >/dev/null 2>&1; then
    echo "   ⚠️ create-dmg UI automation skipped; falling back to native hdiutil..."
    rm -f "$DMG_PATH"
    hdiutil create \
      -volname "$VOLUME_NAME" \
      -srcfolder "$STAGING_DIR" \
      -ov \
      -format UDZO \
      -imagekey zlib-level=9 \
      "$DMG_PATH" >/dev/null
  fi
else
  hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    -imagekey zlib-level=9 \
    "$DMG_PATH" >/dev/null
fi

# Clean staging folder
rm -rf "$STAGING_DIR"

# Generate SHA-256 checksum file (relative filename for portable `shasum -a 256 -c`)
cp -f "$DMG_PATH" "$LATEST_DMG_PATH"
(
  cd "$DIST_DIR"
  shasum -a 256 "$DMG_NAME" > "$SHA_PATH"
  shasum -a 256 "$LATEST_DMG_NAME" > "$LATEST_SHA_PATH"
)

DMG_SIZE="$(du -h "$DMG_PATH" | awk '{print $1}')"
SHA_VALUE="$(awk '{print $1}' "$SHA_PATH")"

echo "=================================================================="
echo "✅ Release DMG Successfully Packaged!"
echo "   📦 DMG File (Versioned): $DMG_PATH"
echo "   📦 DMG File (Latest)   : $LATEST_DMG_PATH"
echo "   📏 File Size           : $DMG_SIZE"
echo "   🔐 SHA-256             : $SHA_VALUE"
echo "   📄 Checksum            : $SHA_PATH"
echo "=================================================================="
