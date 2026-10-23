#!/bin/bash
# Выгрузка признаков решения в TSV для подбора весов: bash tools/tune.sh > features.tsv
# Собирается как tools/selftest.sh, но с tools/features_harness.swift. TUNE_N — размер выборок (по умолчанию 3000).
set -e
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)"
python3 - "$OUT" <<'PY'
import sys
out = sys.argv[1]
src = open("main.swift").read()
s = src[:src.index("// MARK: - Меню в строке состояния")]
s = s.replace("private func", "func").replace("private var", "var").replace("private enum", "enum")
s = s.replace("guard let layout = currentLayoutLanguage(), layout", "guard let layout = Optional(testLayout), layout")
s = s.replace("if let id = focusedAppBundleID(), isAutoDisabled(for: id)", "if false, let id = Optional(\"\"), isAutoDisabled(for: id)")
s = "var testLayout = \"en\"\n" + s + open("tools/tune_words.swift").read() + open("tools/features_harness.swift").read()
open(out + "/main.swift", "w").write(s)
PY
swiftc -O "$OUT/main.swift" Ngrams.swift -o "$OUT/tune" 2>&1 | grep -E "error" >&2 || true
"$OUT/tune"
