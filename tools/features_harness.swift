// Выгрузка признаков решения для подбора весов (tools/tune.sh). Собирается так же, как selftest.
// Для каждого слова: как оно выглядит в набранной раскладке и в другой, словари, статистика,
// и что решает текущая логика. Печатает TSV в stdout.

tables.rebuild()

func keysFor(_ text: String, lang: String) -> [Key]? {
    var out: [Key] = []
    for ch in text {
        var found: Key?
        for code in 0...50 { for mod in 0..<2 {
            let c = lang == "ru" ? tables.ru[code*4+mod] : tables.en[code*4+mod]
            if c == ch && found == nil { found = Key(code: CGKeyCode(code), flags: mod == 1 ? .maskShift : []) }
        } }
        guard let k = found else { return nil }
        out.append(k)
    }
    return out
}

func editDistance(_ a: String, _ b: String) -> Int {
    let x = Array(a), y = Array(b)
    if x.isEmpty { return y.count }
    var prev = Array(0...y.count)
    for i in 1...x.count {
        var cur = [i] + Array(repeating: 0, count: y.count)
        for j in 1...max(y.count, 1) where !y.isEmpty {
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
        }
        prev = cur
    }
    return prev[y.count]
}

func nearestGuess(_ word: String, lang: String) -> Int {
    guard let language = spellLanguages[lang] else { return 9 }
    let g = NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length),
                                          in: word, language: language, inSpellDocumentWithTag: 0) ?? []
    return g.map { editDistance($0.lowercased(), word.lowercased()) }.min() ?? 9
}

func ruCompletions() -> [String] {
    let alphabet = Array("абвгдежзийклмнопрстуфхцчшщэюя")
    var words = Set<String>()
    for a in alphabet { for b in alphabet {
        let p = String([a, b])
        let c = NSSpellChecker.shared.completions(forPartialWordRange: NSRange(location: 0, length: 2), in: p,
                                                  language: spellLanguages["ru"]!, inSpellDocumentWithTag: 0) ?? []
        for w in c where w.count >= 3 && w.allSatisfy({ $0.isLetter && !$0.isASCII }) { words.insert(w.lowercased()) }
    } }
    return words.sorted()
}

/// cat: категория; word: как задумано; lang: на каком языке слово; typedIn: в какой раскладке набрано.
func row(_ cat: String, _ word: String, lang: String, typedIn: String) {
    guard let keys = keysFor(word, lang: lang),
          keys.allSatisfy({ tables.letterKeys.contains($0.code) }),
          let en = shownString(keys, lang: "en"), let ru = shownString(keys, lang: "ru") else { return }
    let layout = typedIn
    let shown = layout == "en" ? en : ru, target = layout == "en" ? ru : en
    let tLang = layout == "en" ? "ru" : "en"
    let enValid = isValidEnglish(en)
    let ruValid = ruAbbreviations.contains(ru.lowercased()) || ruInterjections.contains(ru.lowercased()) || isValidWord(ru, lang: "ru")
    let srcValid = layout == "en" ? enValid : ruValid
    let tgtValid = layout == "en" ? ruValid : enValid
    let m = layoutMargin(shown: shown, shownLang: layout, target: target, targetLang: tLang)
    let sScore = layout == "en" ? enModel.score(shown) : ruModel.score(shown)
    let tScore = layout == "en" ? ruModel.score(target) : enModel.score(target)
    let sw = Switcher()
    testLayout = layout
    for k in keys { sw.registerTyped(k) }
    let plan = sw.planCorrection(trigger: Key(code: kSpace))
    let finalStage = sw.lastDecision.contains("; EN: слово=") && !sw.lastDecision.contains("растянутое")
    let sTypo = finalStage ? nearestGuess(shown, lang: layout) : 9
    let tTypo = finalStage ? nearestGuess(target, lang: tLang) : 9
    print([cat, word, shown, target, layout, srcValid ? "1" : "0", tgtValid ? "1" : "0",
           String(format: "%.3f", m), String(format: "%.3f", sScore), String(format: "%.3f", tScore),
           String(keys.count), String(sTypo), String(tTypo), plan == nil ? "0" : "1", finalStage ? "1" : "0",
           isKnownEnglishAbbreviation(en) ? "1" : "0"].joined(separator: "\t"))
}

print("cat\tword\tshown\ttarget\tlayout\tsrc_valid\ttgt_valid\tmargin\tsrc_score\ttgt_score\tlen\tsrc_typo\ttgt_typo\tcur_convert\tfinal\tabbr")
var rng = SystemRandomNumberGenerator()
func sample(_ path: String, _ n: Int) -> [String] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var w = text.split(separator: "\n").map(String.init).filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    w.shuffle(using: &rng)
    return Array(w.prefix(n))
}
let n = Int(ProcessInfo.processInfo.environment["TUNE_N"] ?? "3000") ?? 3000
for w in sample("/usr/share/dict/web2", n) { row("en_web2", w, lang: "en", typedIn: "en"); row("en_web2", w, lang: "en", typedIn: "ru") }
for w in sample("/usr/share/dict/propernames", 1300) { row("en_names", w, lang: "en", typedIn: "en"); row("en_names", w, lang: "en", typedIn: "ru") }
var ru = ruCompletions(); ru.shuffle(using: &rng)
for w in ru.prefix(n) { row("ru_dict", w, lang: "ru", typedIn: "ru"); row("ru_dict", w, lang: "ru", typedIn: "en") }
for w in extraRu { row("ru_slang", w, lang: "ru", typedIn: "ru"); row("ru_slang", w, lang: "ru", typedIn: "en") }
for w in extraEn { row("en_slang", w, lang: "en", typedIn: "en"); row("en_slang", w, lang: "en", typedIn: "ru") }
