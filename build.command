#!/bin/bash
# Сборка Sapfire. Можно запустить двойным кликом в Finder.
cd "$(dirname "$0")"
APP="build/Sapfire.app"
LOG="build/log.txt"
TMP="build/.next"
mkdir -p build
# Иконка: sapfire_icon.psd новее собранной — пересобрать (tools/icon.sh)
[ -f sapfire_icon.psd ] && { [ ! -f Assets.car ] || [ sapfire_icon.psd -nt Assets.car ]; } && tools/icon.sh > /dev/null

echo "Собираю Sapfire…"
ARCH=$(uname -m)
# Сначала собираем во временную папку: пока идёт сборка, прежний Sapfire цел и запускается
rm -rf "$TMP"
mkdir -p "$TMP"
if xcrun -sdk macosx swiftc -O -swift-version 5 -parse-as-library \
    -target "$ARCH-apple-macos14.0" \
    -o "$TMP/Sapfire" Sources/*.swift > "$LOG" 2>&1; then
    # Закрываем уже запущенный Sapfire (с сохранением вкладок), иначе откроется старая версия
    if pgrep -x Sapfire > /dev/null; then
        osascript -e 'tell application id "app.sapfire.browser" to quit' > /dev/null 2>&1
        for i in {1..30}; do pgrep -x Sapfire > /dev/null || break; sleep 0.1; done
        pkill -x Sapfire 2> /dev/null
        sleep 0.2
    fi
    # Подмена — за долю секунды. Саму папку программы не пересоздаём (только содержимое):
    # иначе Dock теряет ссылку на неё и пишет «повреждена»
    rm -rf "$APP/Contents"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
    mv "$TMP/Sapfire" "$APP/Contents/MacOS/Sapfire"
    cp Info.plist "$APP/Contents/"
    chmod 644 "$APP/Contents/Info.plist"
    # Номер сборки — дата и время сборки (ГГГГММДД.ЧЧММ): в About — «0.1 (20261106.1432)»
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$APP/Contents/Info.plist"
    [ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
    [ -f Assets.car ] && cp Assets.car "$APP/Contents/Resources/"     # иконка Icon Composer (tools/icon.command)
    # Списки блокировщика внутри программы (Filters/*.txt, обновить — tools/filters.sh): первый запуск блокирует сразу, без сети
    mkdir -p "$APP/Contents/Resources/filters"
    for f in Filters/*.txt; do [ -f "$f" ] && compression_tool -encode -a lzfse -i "$f" -o "$APP/Contents/Resources/filters/$(basename "$f").lzfse"; done
    # Постоянная подпись «Sapfire Dev» (сертификат в Связке входа) — Связка ключей узнаёт Sapfire после пересборки; нет её — подпись без имени
    SIGN=-; security find-certificate -c "Sapfire Dev" >/dev/null 2>&1 && SIGN="Sapfire Dev"
    codesign --force --sign "$SIGN" "$APP" >> "$LOG" 2>&1 || codesign --force --sign - "$APP" >> "$LOG" 2>&1
    rm -rf "$TMP"
    echo "OK" >> "$LOG"
    echo "Готово: $APP"
    open "$APP"
else
    rm -rf "$TMP"
    echo "Ошибка сборки, подробности в $LOG"
    tail -40 "$LOG"
    exit 1
fi
