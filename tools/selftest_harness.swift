// Тесты логики Switcher: имитирует набор фраз клавишами и печатает, что получилось бы на экране.
// Собирается скриптом tools/selftest.sh вместе с логикой из main.swift (без меню и перехвата клавиатуры).
// Нужны включённые раскладки EN и RU и словари macOS.

tables.rebuild()
print("tables:", tables.note)
/// «⇪» в тексте — нажатие Caps Lock: дальше заглавные набираются с ним, без Shift.
func keysFor(_ text: String, lang: String) -> [Key] {
    var out: [Key] = []
    var capsOn = false
    for ch in text {
        if ch == "⇪" { capsOn.toggle(); continue }
        if ch == " " { out.append(Key(code: kSpace)); continue }
        if ch == "\n" { out.append(Key(code: kReturn)); continue }
        if ch == "\t" { out.append(Key(code: kTab)); continue }
        var found: Key?
        for code in 0...50 { for mod in 0..<2 {
            let c = lang == "ru" ? tables.ru[code*4+mod] : tables.en[code*4+mod]
            if c == ch && found == nil { found = Key(code: CGKeyCode(code), flags: mod == 1 ? .maskShift : []) }
        } }
        guard var k = found else { fatalError("no key for \(ch) in \(lang)") }
        if capsOn && ch.isLetter { k = Key(code: k.code, flags: .maskAlphaShift) }
        out.append(k)
    }
    return out
}
/// Печатает клавиши фразы `typed` (как они выглядят в раскладке lang) и возвращает текст на экране.
func simulate(_ typed: String, lang: String, idleAtEnd: Bool = false) -> String {
    let sw = Switcher()
    testLayout = lang
    var screen: [Key] = []   // клавиши на экране и в какой раскладке каждая
    var screenLang: [String] = []
    func apply(_ plan: Plan) {
        let n = plan.keys.count
        let to = plan.toRussian ? "ru" : "en"
        for (j, i) in ((screen.count - n)..<screen.count).enumerated() {
            screen[i] = plan.typed[j]
            screenLang[i] = to
        }
        testLayout = to
        if !plan.caseOnly {  // как в perform: исправление регистра не делает следующее слово «осторожным»
            sw.lastAuto = ([], plan.shownLower, ProcessInfo.processInfo.systemUptime)
            sw.lastAutoLang = to
        }
    }
    for k in keysFor(typed, lang: lang) {
        if sw.isTrigger(k) || k.code == kTab {
            if let plan = sw.planCorrection(trigger: k) {
                apply(plan)
                let ends = k.code == kReturn || k.code == kTab
                sw.prevWords = []
                sw.buffer = ends ? [] : plan.typed + [k]
            } else if k.code == kTab { sw.reset() } else { sw.registerBoundary(k) }
            screen.append(k); screenLang.append(testLayout)
        } else {
            sw.registerTyped(k)
            screen.append(k); screenLang.append(testLayout)
        }
    }
    if idleAtEnd, let plan = sw.planCorrection(trigger: nil) { apply(plan) }
    var out = ""
    for (i, k) in screen.enumerated() {
        if k.code == kReturn { out += "⏎"; continue }
        if k.code == kTab { out += "⇥"; continue }
        out.append(shownChar(k, lang: screenLang[i]) ?? "?")
    }
    return out + "   [" + sw.lastDecision.prefix(90) + "]"
}
let cases: [(String, String)] = [
    // EN-раскладка, а писали по-русски
    ("ghbdtn rfr ltkf ", "en"), ("gj-heccrb ", "en"), ("bp-pf ", "en"), ("rjt-xnj ", "en"),
    ("lf\n", "en"), ("lf? rjytxyj ", "en"), ("yt pyf. ", "en"), ("z ljvf ", "en"), ("lf ", "en"),
    ("jr\n", "en"), ("ntktuhfv ", "en"), ("rhby; ", "en"), ("gfcb, ", "en"), (".ne, ", "en"),
    ("ghbdtn\t", "en"), ("'nj ", "en"), ("Dfkthbq ", "en"), ("ds ult ", "en"), ("vs ghbdtn ", "en"),
    ("ghbdtn ", "en"), ("Cfyrn-Gtnth,ehu ", "en"), ("ytn\n", "en"),
    // RU-раскладка, а писали по-английски
    ("руддщ цщкдв ", "ru"), ("у-ьфшд ", "ru"), ("ща сщгкыу ", "ru"), ("шы ше ", "ru"), ("ыфафкш", "ru"),
    ("лгиуктуеуы ", "ru"), ("вщтэе ", "ru"), ("ш фь ", "ru"), ("рш\n", "ru"), ("шву ", "ru"), ("ШВУ ", "ru"), ("фал ", "ru"), ("сущ ", "ru"),
    // Должно остаться как есть
    ("hello world ", "en"), ("e-mail ", "en"), ("afk brb ", "en"), ("kubernetes nginx ", "en"), ("in ", "en"),
    ("to ", "en"), ("DJ ", "en"), ("c ", "en"), ("airbnb ", "en"), ("lgtm ", "en"), ("ok ", "en"),
    ("привет мир ", "ru"), ("кое-что ", "ru"), ("из-за ", "ru"), ("ща ", "ru"), ("шт ", "ru"),
    ("кринж ", "ru"), ("щас ", "ru"), ("ваще ", "ru"), ("пздц ", "ru"), ("мы ", "ru"), ("рук ", "ru"), ("еды ", "ru"), ("азы ", "ru"), ("шов ", "ru"),
    ("go in ghbdtn ", "en"),
    // Растянутые слова и строчные аббревиатуры: «lfff» -> «дааа», «нууу»/«ыыы»/«ндфл»/«zzz» — как есть
    ("lfff ", "en"), ("yeee ", "en"), ("нууу ", "ru"), ("ыыы ", "ru"), ("гыыы ", "ru"), ("ндфл ", "ru"),
    ("мчс ", "ru"), ("zzz ", "en"), ("sooo ", "en"), ("JJJ ", "en"),
]
for (t, l) in cases { print("\(l): \(t.replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "\t", with: "⇥"))  →  \(simulate(t, lang: l))") }
print("idle: ыфафкш → \(simulate("ыфафкш", lang: "ru", idleAtEnd: true))")
print("idle: ntktuhfv → \(simulate("ntktuhfv", lang: "en", idleAtEnd: true))")

// Проверки с ожидаемым результатом: регистр и взвешенное решение. (набрано, раскладка, должно получиться)
let expectations: [(String, String, String)] = [
    // «ДВойные заглавные» в верной раскладке
    ("THe ", "en", "The "), ("HEllo world ", "en", "Hello world "), ("ПРивет ", "ru", "Привет "),
    ("ПРИвет ", "ru", "ПРИвет "),
    // и не в той: раскладку и регистр — вместе
    ("GHbdtn ", "en", "Привет "), ("РУддщ ", "ru", "Hello "), ("Ghbdtn ", "en", "Привет "),
    // так и пишутся
    ("IDs ", "en", "IDs "), ("PCs ", "en", "PCs "), ("MHz ", "en", "MHz "), ("GHz ", "en", "GHz "),
    ("OAuth ", "en", "OAuth "), ("iOS ", "en", "iOS "), ("MBps ", "en", "MBps "), ("DJ ", "en", "DJ "),
    ("THE ", "en", "THE "), ("HTTPs ", "en", "HTTPs "), ("СПб ", "ru", "СПб "), ("ВКонтакте ", "ru", "ВКонтакте "),
    ("McDonald ", "en", "McDonald "), ("iPhone ", "en", "iPhone "),
    // Caps Lock задели посреди слова (⇪ — нажатие Caps Lock)
    ("п⇪ривет ", "ru", "привет "), ("при⇪вет ", "ru", "привет "), ("h⇪ello ", "en", "hello "),
    ("g⇪hbdtn ", "en", "привет "), ("П⇪ривет ", "ru", "ПРИВЕТ "), ("⇪привет ", "ru", "ПРИВЕТ "),
    // взвешенное решение: больше не исправляем «sus», зато исправляем слова вне словаря у порога
    // («ytha» = «нерф» стоит ровно на границе: +0,01 против −0,01 у верно набранного «нерф» — не проверяем)
    ("sus ", "en", "sus "), ("кфиишеьй ", "ru", "rabbitmq "), ("ьслутяшу ", "ru", "mckenzie "), ("оце ", "ru", "jwt "),
    ("index.html ", "en", "index.html "), ("github.io ", "en", "github.io "),
]
var expectFail: [String] = []
for (typed, lang, want) in expectations {
    let r = simulate(typed, lang: lang)
    let got = String(r.prefix(want.count))
    if got != want { expectFail.append("\(typed)(\(lang)) → «\(got)», ждали «\(want)»  \(r.dropFirst(want.count))") }
}
print("Ожидания: \(expectations.count - expectFail.count)/\(expectations.count) верно"); expectFail.forEach { print("  ✗", $0) }

// Ложные срабатывания: английские имена и редкие слова, набранные правильно.
func falsePositives(_ path: String, limit: Int, lang: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
    var words = text.split(separator: "\n").map(String.init).filter { $0.count >= 3 && $0.allSatisfy { $0.isASCII && $0.isLetter } }
    var rng = SystemRandomNumberGenerator()
    words.shuffle(using: &rng)
    words = Array(words.prefix(limit))
    var bad: [String] = []
    for w in words {
        let r = simulate(w + " ", lang: lang)
        if !r.hasPrefix(w) { bad.append(w + "→" + String(r.prefix(w.count))) }
    }
    print("\(path): \(bad.count) из \(words.count) исправлены зря: \(bad.prefix(40))")
}
falsePositives("/usr/share/dict/propernames", limit: 1300, lang: "en")
falsePositives("/usr/share/dict/web2", limit: 3000, lang: "en")

var miss: [String] = []
for w in ["vps","aws","jwt","utm","gcp","rdp","dhcp","csrf","mqtt","uefi","zfs","cms","ttl","xss","VPS","Aws"] {
    let ru = String(keysFor(w, lang: "en").map { shownChar($0, lang: "ru")! })
    let r = simulate(ru + " ", lang: "ru"); if !r.hasPrefix(w) { miss.append(ru + "→" + r) }
    let k = simulate(w + " ", lang: "en"); if !k.hasPrefix(w) { miss.append(w + "(EN)→" + k) }
}
print("Сокращения, ошибки: \(miss)")

var bad: [String] = []
for w in ["МГУ","США","СНГ","МВД","ООО","ЖКХ","НДС","ВУЗ","РЖД","ГОСТ","СРОЧНО","ПРИВЕТ","ВНИМАНИЕ","ВАЖНО","МЧС","ГИБДД","ТЦ","ИП","СПБ","МСК","ДР","ЛС"] {
    let en = String(keysFor(w, lang: "ru").map { shownChar($0, lang: "en")! })
    let k = simulate(w + " ", lang: "ru"); if !k.hasPrefix(w) { bad.append("испорчено " + w + "→" + k) }
    let f = simulate(en + " ", lang: "en"); if !f.hasPrefix(w) { bad.append("не исправлено " + en + "→" + f) }
}
for w in ["VPS","AWS","NASA","USB","HTTP","API","JSON","SQL","CEO","FAQ","OK","USA","EU","UK","IBM","PDF","IMHO","ASAP","FYI"] {
    let ru = String(keysFor(w, lang: "en").map { shownChar($0, lang: "ru")! })
    let k = simulate(w + " ", lang: "en"); if !k.hasPrefix(w) { bad.append("испорчено " + w + "→" + k) }
    let f = simulate(ru + " ", lang: "ru"); if !f.hasPrefix(w) { bad.append("не исправлено " + ru + "→" + f) }
}
print("ЗАГЛАВНЫЕ: \(bad.count) проблем"); bad.forEach { print("  ", $0) }

// Коллизии: русская аббревиатура, чей EN-набор — известное английское сокращение/слово.
var coll: [String] = []
for a in ruAbbreviations {
    guard let ks = Optional(keysFor(a, lang: "ru")), let e = shownString(ks, lang: "en") else { continue }
    if techWords.contains(e) || (e.count >= 3 && isValidWord(e, lang: "en") && e.contains(where: { "aeiouy".contains($0) })) { coll.append(a + "=" + e) }
}
print("Коллизии RU-аббревиатур: \(coll)")

let ruWords = ["кринж","кринжово","зашквар","годнота","шаурма","имхо","гуглить","пофиг","гитхаб","айфон","сбербанк","ржака","жиза","пжлст","норм","инфа","мессенджер","ваще","щас","ахаха","хаха","лол","кек","збс","пасиб","кста","прив","дарова","здарова","изи","рофл","лайк","скинь","глянь","созвон","дедлайн","фича","баг","пулл","мерж","коммит","деплой","прод","тестить","юзать","фронт","бэк","Валерий","Серёжа","Тимур","Ксюша","Наташка","Димон","Колян","Жека","Шурик","Иваныч","Петрович","Кузнецов","Шевчук","Зеленоградск","Химки","Мытищи","Балашиха","Подольск","Люберцы","Тинькофф","Яндекс","Озон","Вайлдберриз","Авито","Госуслуги","ютуб","телега","инста","вотсап","тиктокер","блогерша","стримить","донатить","лутать","нубас","катка","скилл","рандом","имба","нерф","апнуть","задонатил","хайпануть","флексить","чилить","вайб","краш","токсик","агриться","душнила","кринжатина"]
var keepBad: [String] = [], fixMiss: [String] = []
for w in ruWords {
    let r = simulate(w + " ", lang: "ru")
    if !r.hasPrefix(w) { keepBad.append(w + "→" + String(r.prefix(w.count))) }
    let typedEn = String(keysFor(w, lang: "ru").map { shownChar($0, lang: "en")! })
    let f = simulate(typedEn + " ", lang: "en")
    if !f.hasPrefix(w) { fixMiss.append(typedEn + "→" + String(f.prefix(w.count))) }
}
print("RU в правильной раскладке, испорчено: \(keepBad.count)/\(ruWords.count) \(keepBad)")
print("RU в EN-раскладке, НЕ исправлено: \(fixMiss.count)/\(ruWords.count) \(fixMiss)")
let enWords = ["kubernetes","nginx","github","spotify","photoshop","figma","notion","valeriy","serezha","yeah","gonna","wanna","dunno","asap","repo","config","backend","frontend","refactor","webhook","localhost","emoji","nope","kinda","macbook","zsh","Tesla","Nvidia","Huawei","Xiaomi","Samsung","Lenovo","Bitcoin","Ethereum","Solana","Kotlin","Swift","Rust","Golang","Postgres","MongoDB","Redis","Elastic","Jenkins","Terraform","Ansible","Kubernetes","Prometheus","Grafana","Datadog","Sentry","Vercel","Netlify","Heroku","Supabase","Firebase","Prisma","Nextjs","Svelte","Tailwind","Bootstrap","Figma","Canva","Midjourney","Anthropic","Claude","Gemini","Copilot","Cursor","Zed","Obsidian","Notion","Todoist","Trello","Asana","ClickUp","Linear","Slack","Teams","Webex","Telegram","Viber","Signal","WhatsApp"]
var enKeepBad: [String] = [], enFixMiss: [String] = []
for w in enWords {
    let r = simulate(w + " ", lang: "en")
    if !r.hasPrefix(w) { enKeepBad.append(w + "→" + String(r.prefix(w.count))) }
    let typedRu = String(keysFor(w, lang: "en").map { shownChar($0, lang: "ru")! })
    let f = simulate(typedRu + " ", lang: "ru")
    if !f.hasPrefix(w) { enFixMiss.append(typedRu + "→" + String(f.prefix(w.count))) }
}
print("EN в правильной раскладке, испорчено: \(enKeepBad.count)/\(enWords.count) \(enKeepBad)")
print("EN в RU-раскладке, НЕ исправлено: \(enFixMiss.count)/\(enWords.count) \(enFixMiss)")

// Имена файлов и домены, набранные в RU-раскладке («РФТВЩААюЬВ» = HANDOFF.MD), и русские слова с «ю», которые трогать нельзя.
var fileBad: [String] = []
for w in ["HANDOFF.MD", "README.md", "main.swift", "google.com", "index.html", "notes.txt", "build.sh", "package.json", "github.io", "selftest.sh", "config.yaml", "photo.jpg", "example.org", "yandex.ru"] {
    let ru = String(keysFor(w, lang: "en").map { shownChar($0, lang: "ru")! })
    let f = simulate(ru + " ", lang: "ru"); if !f.hasPrefix(w) { fileBad.append("не исправлено " + ru + "→" + f) }
    let k = simulate(w + " ", lang: "en"); if !k.hasPrefix(w) { fileBad.append("испорчено " + w + "→" + k) }
}
for w in ["люблю", "Тюмень", "Рюрик", "компьютер", "брюки", "вьюга", "крюк", "бюро", "сюрприз", "Варюша", "Танюха", "Илюха", "Костюша", "Анютка", "клюква", "плюшка", "тюлень", "крюшон"] {
    let k = simulate(w + " ", lang: "ru"); if !k.hasPrefix(w) { fileBad.append("испорчено " + w + "→" + k) }
}
print("Файлы/домены: \(fileBad.count) проблем"); fileBad.forEach { print("  ", $0) }

// Сверка с чужой базой правил (только локально, файлы в проект не кладём):
// PUNTO_BENCH=<папка> с punto_switch.tsv / punto_keep.tsv, строки «язык<TAB>слово как набрано».
if let dir = ProcessInfo.processInfo.environment["PUNTO_BENCH"] {
    for (file, mustSwitch) in [("punto_switch.tsv", true), ("punto_keep.tsv", false)] {
        guard let text = try? String(contentsOfFile: dir + "/" + file, encoding: .utf8) else { continue }
        var wrong: [String] = [], total = 0
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "\t").map(String.init)
            guard p.count == 2 else { continue }
            total += 1
            let r = simulate(p[1] + " ", lang: p[0])
            if r.hasPrefix(p[1]) == mustSwitch { wrong.append(p[1] + "→" + String(r.prefix(p[1].count))) }
        }
        print("Punto \(file): не совпало \(wrong.count)/\(total): \(wrong.prefix(60))")
    }
}
