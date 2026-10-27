#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
bash build-macos.sh --no-install

STAGE="dist/dmg-stage"
RW="dist/FocusVoice-rw.dmg"
DMG="dist/FocusVoice-${VERSION}.dmg"
MOUNT="/tmp/FocusVoiceDMG-$$"
rm -rf "$STAGE" "$RW" "$DMG" "$MOUNT"
mkdir -p "$STAGE" "$MOUNT"
cp -R dist/FocusVoice.app "$STAGE/FocusVoice.app"
ln -s /Applications "$STAGE/Applications"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
# 卷根目录的 custom icon 标记（在挂载卷上再设置一次，确保 Finder 识别）
SetFile -a C "$STAGE" 2>/dev/null || true

hdiutil create -volname "FocusVoice ${VERSION}" \
  -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null

hdiutil attach "$RW" -nobrowse -readwrite -mountpoint "$MOUNT" >/dev/null
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true
sync
hdiutil detach "$MOUNT" >/dev/null

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null

# 给 DMG 文件本身设置自定义图标（Finder 里直接显示 App 图标，而不是空白磁盘）
ICON_SRC="/tmp/focusvoice-icon-$$.icns"
ICON_RSRC="/tmp/focusvoice-icon-$$.rsrc"
if [[ -x /usr/bin/DeRez && -x /usr/bin/Rez ]]; then
  cp Resources/AppIcon.icns "$ICON_SRC"
  sips -i "$ICON_SRC" >/dev/null 2>&1 || true
  DeRez -only icns "$ICON_SRC" > "$ICON_RSRC" 2>/dev/null || true
  if [[ -s "$ICON_RSRC" ]]; then
    Rez -append "$ICON_RSRC" -o "$DMG" >/dev/null 2>&1 || true
    SetFile -a C "$DMG" 2>/dev/null || true
  fi
  rm -f "$ICON_SRC" "$ICON_RSRC"
fi
rm -rf "$STAGE" "$RW" "$MOUNT"
echo "已生成: $DMG"
ls -lh "$DMG"
