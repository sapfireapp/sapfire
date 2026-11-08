#!/bin/bash
# Иконка Sapfire из sapfire_icon.psd (камень на белом, 1024) в формате Icon Composer → в собранную программу.
# Запускается сама при сохранении PSD и из build.command, если PSD новее иконки.
# Камень вырезается на прозрачный (tools/cutout.swift) → AppIcon.icon/Assets/gem.png → actool → Assets.car + AppIcon.icns.
# Белую плашку, форму и стекло рисует система (AppIcon.icon/icon.json). Запущенный Sapfire меняет значок в Dock сам (IconWatcher).
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
cd "$(dirname "$0")/.." || exit 1
SRC="sapfire_icon.psd"
APP="build/Sapfire.app"
T="build/icon"
[ -f "$SRC" ] || exit 0
mkdir -p "$T"

# Photoshop пишет файл не мгновенно — ждём, пока размер перестанет меняться
prev=-1
for i in {1..20}; do
    size=$(stat -f %z "$SRC" 2>/dev/null || echo 0)
    [ "$size" = "$prev" ] && [ "$size" != 0 ] && break
    prev=$size; sleep 0.5
done

# Уже собрана из этого же файла — ничего не делать
stamp=$(stat -f %m-%z "$SRC")
[ -f "$T/stamp" ] && [ "$(cat "$T/stamp")" = "$stamp" ] && [ "$1" != "--force" ] && exit 0

if [ ! -x "$T/cutout" ] || [ tools/cutout.swift -nt "$T/cutout" ]; then
    xcrun swiftc -O -o "$T/cutout" tools/cutout.swift || exit 1
fi
sips -s format png "$SRC" --out "$T/src.png" > /dev/null || exit 1
"$T/cutout" "$T/src.png" AppIcon.icon/Assets/gem.png || exit 1
rm -rf "$T/out"; mkdir "$T/out"
xcrun actool "$PWD/AppIcon.icon" --compile "$PWD/$T/out" --app-icon AppIcon --enable-on-demand-resources NO \
    --development-region en --target-device mac --platform macosx --minimum-deployment-target 14.0 \
    --output-partial-info-plist "$PWD/$T/partial.plist" > /dev/null || exit 1
cp "$T/out/Assets.car" Assets.car && cp "$T/out/AppIcon.icns" AppIcon.icns || exit 1
echo "$stamp" > "$T/stamp"

# В собранную программу: подпись заново (ресурс поменялся), Finder и Dock узнают о новой иконке
if [ -d "$APP/Contents/Resources" ]; then
    cp Assets.car AppIcon.icns "$APP/Contents/Resources/"
    # Постоянная подпись «Sapfire Dev» (сертификат в Связке входа) — Связка ключей узнаёт Sapfire после пересборки; нет её — подпись без имени
    SIGN=-; security find-certificate -c "Sapfire Dev" >/dev/null 2>&1 && SIGN="Sapfire Dev"
    codesign --force --sign "$SIGN" "$APP" > /dev/null 2>&1 || codesign --force --sign - "$APP" > /dev/null 2>&1
    touch "$APP"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
fi
echo "$(date '+%H:%M:%S') icon updated"
