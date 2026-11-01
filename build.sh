#!/bin/bash
# Сборка Раскладушка.app и установка в ~/Applications.
# Запуск:  bash build.sh
set -e
cd "$(dirname "$0")"

APP="Раскладушка.app"
EXE="Raskladushka"
BUNDLE_ID="app.raskladushka"
DEST="$HOME/Applications"

# Закрываем уже запущенную копию, если есть
pkill -x "$EXE" 2>/dev/null || true

# Раньше приложение называлось Switcher: убираем старую копию и её записи о разрешениях.
if [ -d "$DEST/Switcher.app" ] || [ -d Switcher.app ]; then
    pkill -x Switcher 2>/dev/null || true
    rm -rf "$DEST/Switcher.app" Switcher.app
    tccutil reset Accessibility local.layout-switcher >/dev/null 2>&1 || true
    tccutil reset ListenEvent local.layout-switcher >/dev/null 2>&1 || true
    echo "Старый Switcher.app удалён (настройки перенесутся при первом запуске)."
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Компиляция…"
swiftc -O -swift-version 5 main.swift Ngrams.swift -o "$APP/Contents/MacOS/$EXE"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>Раскладушка</string>
    <key>CFBundleDisplayName</key>
    <string>Раскладушка</string>
    <key>CFBundleExecutable</key>
    <string>$EXE</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>5</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.4</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
EOF

# Значок приложения: из icon_1024.png (лежит рядом) делаем AppIcon.icns
if [ -f icon_1024.png ]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        sips -z $size $size icon_1024.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
        double=$((size * 2))
        sips -z $double $double icon_1024.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    echo "Значок: добавлен."
else
    echo "Значок: файл icon_1024.png не найден, приложение будет без своего значка."
fi

# Подпись. Если в связке ключей есть свой сертификат «SwitcherDev», подписываем им:
# тогда выданные разрешения не слетают после пересборки. Иначе подпись «ad-hoc».
IDENTITY="${SWITCHER_IDENTITY:-SwitcherDev}"
SIGNED_WITH="ad-hoc"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    if codesign --force --sign "$IDENTITY" "$APP"; then
        SIGNED_WITH="$IDENTITY"
    else
        echo "Не удалось подписать сертификатом $IDENTITY, подписываю ad-hoc…"
    fi
else
    echo "Сертификат $IDENTITY в связке ключей не найден."
fi
if [ "$SIGNED_WITH" = "ad-hoc" ]; then
    codesign --force --sign - "$APP"
fi
echo "Подпись: $SIGNED_WITH"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|Authority" || true

mkdir -p "$DEST"
rm -rf "$DEST/$APP"
cp -R "$APP" "$DEST/"

touch "$DEST/$APP"   # чтобы Finder обновил значок
echo "Готово: $DEST/$APP"

# При подписи ad-hoc macOS считает каждую сборку новым приложением: старые записи о
# разрешениях надо сбросить, иначе галочки в настройках есть, а доступа нет.
if [ "$SIGNED_WITH" = "ad-hoc" ]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset ListenEvent "$BUNDLE_ID" >/dev/null 2>&1 || true
    echo "Разрешения сброшены: при запуске выдайте их заново."
fi

open "$DEST/$APP"
