#!/bin/bash
# Прогон тестов логики: bash tools/selftest.sh
# Берёт логику из main.swift (всё до меню), подменяет текущую раскладку и проверку приложения
# на тестовые значения и добавляет tools/selftest_harness.swift. Перехват клавиатуры не запускается.
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
python3 - "$OUT" <<'PY'
import sys
out = sys.argv[1]
src = open("main.swift").read()
s = src[:src.index("// MARK: - Меню в строке состояния")]
s = s.replace("private func", "func").replace("private var", "var").replace("private enum", "enum")
s = s.replace("guard let layout = currentLayoutLanguage(), layout", "guard let layout = Optional(testLayout), layout")
s = s.replace("if let id = focusedAppBundleID(), isAutoDisabled(for: id)", "if false, let id = Optional(\"\"), isAutoDisabled(for: id)")
s = s.replace("IsSecureEventInputEnabled()", "false")
s = "var testLayout = \"en\"\n" + s + open("tools/selftest_harness.swift").read()
open(out + "/main.swift", "w").write(s)
PY
swiftc -O "$OUT/main.swift" Ngrams.swift -o "$OUT/selftest"
"$OUT/selftest"
