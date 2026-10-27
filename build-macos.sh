#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/FocusVoice.app"
INSTALL=1
[[ "${1:-}" == "--no-install" ]] && INSTALL=0

# ---- 1. Build ----------------------------------------------------------------
# SwiftPM 的 manifest 沙箱在部分受限环境会报 sandbox_apply，降级重试一次。
if ! swift build -c release; then
  echo "swift build 失败，改用 --disable-sandbox 重试…"
  swift build -c release --disable-sandbox
fi

# ---- 2. Assemble .app --------------------------------------------------------
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/sherpa"
cp .build/release/FocusVoice "$APP/Contents/MacOS/FocusVoice"
cp Info.plist "$APP/Contents/Info.plist"
# App icon + menu bar template icons
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [[ -d Resources/en.lproj ]]; then
  cp -R Resources/en.lproj "$APP/Contents/Resources/en.lproj"
fi
if [[ -d Resources/Sounds ]]; then
  cp -R Resources/Sounds "$APP/Contents/Resources/Sounds"
fi
for icon in MenuBarIcon MenuBarIconActive; do
  [[ -f "Resources/$icon.png" ]] && cp "Resources/$icon.png" "$APP/Contents/Resources/"
  [[ -f "Resources/$icon@2x.png" ]] && cp "Resources/$icon@2x.png" "$APP/Contents/Resources/"
done
chmod +x "$APP/Contents/MacOS/FocusVoice"

# sherpa-onnx runtime (SenseVoice engine, same build DSH ships)
cp Vendor/sherpa/libsherpa-onnx-c-api.dylib "$APP/Contents/Resources/sherpa/"
cp Vendor/sherpa/libsherpa-onnx-cxx-api.dylib "$APP/Contents/Resources/sherpa/"
cp Vendor/sherpa/libonnxruntime.dylib "$APP/Contents/Resources/sherpa/"
cp Vendor/sherpa/LICENSE "$APP/Contents/Resources/sherpa/LICENSE" 2>/dev/null || true
cp Vendor/sherpa/NOTICE.md "$APP/Contents/Resources/sherpa/NOTICE.md" 2>/dev/null || true
chmod +x "$APP/Contents/Resources/sherpa/"*.dylib

# 轻量安装包：不内置 SenseVoice 模型（约 230MB）。
# 用户在「设置 → 语音模型」点「一键下载并安装模型」，
# 下载到 ~/Library/Application Support/FocusVoice/Models/sensevoice。

# ---- 3. Sign ----------------------------------------------------------------
# 先删掉开发用的绝对 Vendor rpath（只保留 @loader_path/../Resources/sherpa），必须在签名之前改。
install_name_tool -delete_rpath "$PWD/Vendor/sherpa" "$APP/Contents/MacOS/FocusVoice" 2>/dev/null || true
# 先逐个签动态库，再签 App，否则 --verify --strict 会因嵌套签名不一致失败。
for dylib in "$APP/Contents/Resources/sherpa/"*.dylib; do
  codesign --force --sign - "$dylib"
done
codesign --force --sign - -r='designated => identifier "com.focusvoice.mac"' --identifier com.focusvoice.mac "$APP"
codesign --verify --strict "$APP"

# ---- 4. Install --------------------------------------------------------------
if [[ $INSTALL -eq 1 ]]; then
  echo "安装至 /Applications/FocusVoice.app..."
  rm -rf /Applications/FocusVoice.app
  cp -R "$APP" /Applications/FocusVoice.app
  codesign --verify --strict /Applications/FocusVoice.app
  echo "已安装: /Applications/FocusVoice.app"
  echo "可运行: open /Applications/FocusVoice.app"
else
  echo "已生成（未安装）: $PWD/$APP"
fi

echo "生成 DMG: bash scripts/make-dmg.sh"
