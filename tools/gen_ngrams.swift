// Генератор статистики буквосочетаний для Switcher.
// Собирает частые слова из системных словарей macOS (подсказки проверки орфографии)
// и считает тройки букв. Результат — Ngrams.swift рядом с main.swift.
//
// Запуск (нужен только если хочется пересобрать статистику):
//   swiftc -O tools/gen_ngrams.swift -o /tmp/gen_ngrams && /tmp/gen_ngrams > Ngrams.swift

import Cocoa

let sc = NSSpellChecker.shared

func completions(_ prefix: String, _ lang: String) -> [String] {
    sc.completions(forPartialWordRange: NSRange(location: 0, length: (prefix as NSString).length),
                   in: prefix, language: lang, inSpellDocumentWithTag: 0) ?? []
}

func collect(lang: String, alphabet: [Character], extra: Set<Character>) -> [String] {
    var words = Set<String>()
    var productive: [String] = []
    func add(_ list: [String]) {
        for w in list {
            let l = w.lowercased()
            guard l.count >= 2, l.allSatisfy({ alphabet.contains($0) || extra.contains($0) }) else { continue }
            words.insert(l)
        }
    }
    for a in alphabet {
        add(completions(String(a), lang))
        for b in alphabet {
            let p = String([a, b])
            let c = completions(p, lang)
            add(c)
            if c.count >= 20 { productive.append(p) }
        }
    }
    for p in productive {
        for c in alphabet { add(completions(p + String(c), lang)) }
    }
    return words.sorted()
}

/// Тройки с границами слова: «^» — начало, «$» — конец.
func trigrams(_ words: [String]) -> [String: Int] {
    var t: [String: Int] = [:]
    for w in words {
        let s = Array("^^" + w + "$")
        for i in 0..<(s.count - 2) { t[String(s[i...(i + 2)]), default: 0] += 1 }
    }
    return t
}

let ru = collect(lang: "ru", alphabet: Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюя"), extra: ["-"])
let en = collect(lang: "en", alphabet: Array("abcdefghijklmnopqrstuvwxyz"), extra: ["'", "-"])
FileHandle.standardError.write("ru: \(ru.count) слов, en: \(en.count) слов\n".data(using: .utf8)!)

func dump(_ name: String, _ t: [String: Int]) {
    let body = t.sorted { $0.key < $1.key }.map { "\($0.key)\($0.value)" }.joined(separator: " ")
    print("let \(name) = \"\"\"")
    var line = ""
    for item in body.split(separator: " ") {
        if line.count > 100 { print(line); line = "" }
        line += (line.isEmpty ? "" : " ") + item
    }
    if !line.isEmpty { print(line) }
    print("\"\"\"\n")
}

print("// Сгенерировано tools/gen_ngrams.swift из системных словарей macOS. Не редактировать вручную.")
print("// Формат: тройка букв (^ — начало слова, $ — конец) и сразу за ней число слов, где она встречается.\n")
dump("ruTrigramData", trigrams(ru))
dump("enTrigramData", trigrams(en))
