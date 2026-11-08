#!/bin/bash
# Выпуск Sapfire для сайта: две сборки — Apple silicon и Intel, подпись Developer ID с защищённой средой выполнения,
# DMG, заверение у Apple (notarytool), квитанция в DMG (stapler). Итог — build/release/Sapfire-<версия>-AppleSilicon.dmg и -Intel.dmg.
# Один раз заранее:
#   1. Xcode → Settings → Accounts → Manage Certificates → «+» → Developer ID Application
#   2. xcrun notarytool store-credentials sapfire --apple-id <Apple ID> --team-id <Team ID>   (пароль для приложений — account.apple.com)
# NOTARIZE=0 — без отправки в Apple (проверить сборку и подпись). SAPFIRE_SIGN — другая подпись, SAPFIRE_NOTARY — другой профиль notarytool
set -euo pipefail
cd "$(dirname "$0")/.."

ID="${SAPFIRE_SIGN:-$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')}"   # отпечаток: по имени codesign путается, если сертификат виден в нескольких связках
[ -n "$ID" ] || { echo "Нет сертификата Developer ID Application в связке ключей (см. шаг 1 в начале файла)"; exit 1; }
PROFILE="${SAPFIRE_NOTARY:-sapfire}"
TS=--timestamp; [ "$ID" = "-" ] && TS=--timestamp=none   # SAPFIRE_SIGN=- — проверочная подпись без сертификата
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
BUILD=$(date +%Y%m%d.%H%M)   # одна и та же у обеих сборок
OUT=build/release; LOG="$OUT/log.txt"
rm -rf "$OUT"; mkdir -p "$OUT"
[ -f sapfire_icon.psd ] && { [ ! -f Assets.car ] || [ sapfire_icon.psd -nt Assets.car ]; } && tools/icon.sh > /dev/null
tools/filters.sh > /dev/null || echo "Списки блокировщика не обновились — беру те, что в Filters/"

# Две отдельные сборки — под Apple silicon и под Intel: каждая вдвое меньше универсальной
for A in arm64 x86_64; do
  NAME=$([ $A = arm64 ] && echo AppleSilicon || echo Intel)
  DIR="$OUT/$NAME"; APP="$DIR/Sapfire.app"; DMG="$OUT/Sapfire-$VER-$NAME.dmg"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  echo "[$NAME] собираю $VER…"
  xcrun -sdk macosx swiftc -O -swift-version 5 -parse-as-library -target "$A-apple-macos14.0" \
    -o "$APP/Contents/MacOS/Sapfire" Sources/*.swift >> "$LOG" 2>&1 || { echo "Ошибка сборки $A, подробности в $LOG"; tail -30 "$LOG"; exit 1; }
  cp Info.plist "$APP/Contents/"; chmod 644 "$APP/Contents/Info.plist"
  # Публичный идентификатор — только у выпуска: рабочий Sapfire (build.command) остаётся app.sapfire.browser со своими данными
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${SAPFIRE_ID:-app.sapfire.browser}" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"   # номер сборки — дата (растёт сам; нужен и для обновлений)
  [ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"
  [ -f Assets.car ] && cp Assets.car "$APP/Contents/Resources/"
  # Списки блокировщика внутри программы — первый запуск блокирует сразу и молчит в сети (Filters/*.txt, обновить — tools/filters.sh)
  mkdir -p "$APP/Contents/Resources/filters"
  for f in Filters/*.txt; do [ -f "$f" ] && compression_tool -encode -a lzfse -i "$f" -o "$APP/Contents/Resources/filters/$(basename "$f").lzfse"; done
  ls "$APP/Contents/Resources/filters/"*.lzfse > /dev/null 2>&1 || { echo "Нет списков блокировщика в Filters/ — запусти tools/filters.sh"; exit 1; }

  echo "[$NAME] подписываю: $ID"
  codesign --force --options runtime $TS --entitlements tools/Sapfire.entitlements --sign "$ID" "$APP"
  codesign --verify --strict --verbose=2 "$APP" >> "$LOG" 2>&1

  echo "[$NAME] упаковываю DMG…"
  STAGE="$DIR/dmg"; mkdir -p "$STAGE"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Sapfire" -srcfolder "$STAGE" -ov -format UDZO "$DMG" > /dev/null; rm -rf "$STAGE"
  codesign --force $TS --sign "$ID" "$DMG"

  if [ "${NOTARIZE:-1}" = 1 ]; then
    echo "[$NAME] отправляю на заверение в Apple (обычно несколько минут)…"
    R=$(xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait 2>&1 | tee -a "$LOG")
    echo "$R" | grep -q "status: Accepted" || { echo "$R"; echo "Apple не приняла сборку. Причины: xcrun notarytool log <id> --keychain-profile $PROFILE"; exit 1; }
    xcrun stapler staple "$DMG"
    spctl -a -vv -t install "$DMG"
  fi
  echo "[$NAME] готово: $DMG ($(du -h "$DMG" | cut -f1))"
done
