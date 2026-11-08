#!/bin/bash
# Свежие списки блокировщика для вложения в программу (Filters/*.txt → build.command / release.command → Resources/filters/*.lzfse).
# Каждый качается во временный файл и заменяет прежний, только если пришёл целиком
set -euo pipefail
cd "$(dirname "$0")/.."
get() { curl -fsSL --max-time 60 "$2" -o "Filters/$1.txt.new" && [ -s "Filters/$1.txt.new" ] && mv "Filters/$1.txt.new" "Filters/$1.txt"; }
get easylist https://easylist.to/easylist/easylist.txt
get easyprivacy https://easylist.to/easylist/easyprivacy.txt
get ruadlist https://easylist-downloads.adblockplus.org/ruadlist.txt
get cookies https://secure.fanboy.co.nz/fanboy-cookiemonster.txt
# YouTube: из списков uBlock Origin (uAssets, GPL-3.0) — только строки про YouTube и условия !#if (как UBOYouTube.relevant)
U=https://raw.githubusercontent.com/uBlockOrigin/uAssets/master/filters
T=$(mktemp -d)
curl -fsSL --max-time 60 "$U/quick-fixes.txt" -o "$T/q" && curl -fsSL --max-time 60 "$U/filters.txt" -o "$T/f" &&
  cat "$T/q" "$T/f" | grep -E '^!#|^[^!].*youtube' > "$T/y" && grep -q '+js(' "$T/y" && mv "$T/y" Filters/ubo-youtube.txt
rm -rf "$T"
ls -la Filters
