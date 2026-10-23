#!/bin/bash
# Сборка Raskladushka.zip для передачи на другой Mac (Apple Silicon и Intel).
# Ничего не устанавливает и не трогает запущенную копию.
# Запуск:  bash package.sh   (сначала один раз bash build.sh — оттуда берутся Info.plist и значок)
set -e
cd "$(dirname "$0")"

SRC="Раскладушка.app"
EXE="Raskladushka"
if [ ! -f "$SRC/Contents/Info.plist" ]; then
    echo "Сначала соберите приложение: bash build.sh"
    exit 1
fi

DIST="dist"
APP="$DIST/$SRC"
rm -rf "$DIST"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Компиляция для Apple Silicon и Intel…"
swiftc -O -swift-version 5 -target arm64-apple-macos13 main.swift Ngrams.swift -o "$DIST/$EXE-arm64"
swiftc -O -swift-version 5 -target x86_64-apple-macos13 main.swift Ngrams.swift -o "$DIST/$EXE-x86_64"
lipo -create "$DIST/$EXE-arm64" "$DIST/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"
rm "$DIST/$EXE-arm64" "$DIST/$EXE-x86_64"

cp "$SRC/Contents/Info.plist" "$APP/Contents/"
[ -f "$SRC/Contents/Resources/AppIcon.icns" ] && cp "$SRC/Contents/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Подпись ad-hoc: на чужом Mac ваш сертификат всё равно не доверенный, а так подпись цельная.
codesign --force --sign - "$APP"

# ditto сохраняет структуру приложения и подпись (обычный zip может их испортить).
ditto -c -k --keepParent "$APP" "$DIST/Raskladushka.zip"
rm -rf "$APP"

# Кладём архив и на сайт: кнопка «Скачать» ведёт на site/download/Raskladushka.zip.
mkdir -p site/download
cp "$DIST/Raskladushka.zip" site/download/

echo "Готово: $DIST/Raskladushka.zip (и копия в site/download/)"
