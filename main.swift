// Раскладушка: исправление текста, набранного не в той раскладке, для macOS (RU <-> EN)
//
//   Двойной Shift   — исправить последнее набранное слово (повторно — вернуть обратно)
//   Option + Shift  — исправить выделенный текст
//   Автоисправление — слово исправляется само на пробеле, знаке препинания, Enter или Tab
//                     (в Spotlight и полях поиска — ещё и по паузе в наборе), если оно
//                     «не слово» в текущей раскладке, а в другой — слово. Слова не из словаря
//                     (имена, сленг, бренды) оцениваются по статистике буквосочетаний (Ngrams.swift).
//                     Отмена двойным Shift возвращает слово; постоянное исключение добавляется отдельно через меню.
//   Регистр         — «ПРивет» -> «Привет», «пРИВЕТ» (задели Caps Lock) -> «привет» с выключением Caps Lock.
//
// Сборка и установка: bash build.sh
// Пересобрать статистику буквосочетаний (обычно не нужно): см. tools/gen_ngrams.swift

import Cocoa
import Carbon.HIToolbox
import ServiceManagement
import CryptoKit
import IOKit.hidsystem

// MARK: - Константы

/// Метка на наших синтетических событиях, чтобы не реагировать на самих себя.
let magic: Int64 = 0x53574954

let kReturn: CGKeyCode = 36
let kKeypadEnter: CGKeyCode = 76
let kTab: CGKeyCode = 48
let kSpace: CGKeyCode = 49
let kBackspace: CGKeyCode = 51
let kC: CGKeyCode = 8
let kV: CGKeyCode = 9

let shiftMask: UInt64 = CGEventFlags.maskShift.rawValue
let capsMask: UInt64 = CGEventFlags.maskAlphaShift.rawValue

// MARK: - Нажатие клавиши (код + Shift/CapsLock)

struct Key: Equatable {
    let code: CGKeyCode
    let flags: UInt64  // только Shift и CapsLock

    init(code: CGKeyCode, flags: CGEventFlags = []) {
        self.code = code
        self.flags = flags.rawValue & (shiftMask | capsMask)
    }
    var shift: Bool { flags & shiftMask != 0 }
    var caps: Bool { flags & capsMask != 0 }
    var cgFlags: CGEventFlags { CGEventFlags(rawValue: flags) }
}

// MARK: - Раскладки (Text Input Sources)

func inputSources() -> [TISInputSource] {
    let filter = [
        kTISPropertyInputSourceIsSelectCapable: true,
        kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource as Any,
    ] as CFDictionary
    guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource]
    else { return [] }
    return list
}

func primaryLanguage(of source: TISInputSource) -> String? {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
    let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
    return langs?.first
}

func currentLayoutLanguage() -> String? {
    primaryLanguage(of: TISCopyCurrentKeyboardInputSource().takeRetainedValue())
}

var lastOwnLayoutSwitch: TimeInterval = 0

func switchLayout(toRussian: Bool) {
    lastOwnLayoutSwitch = ProcessInfo.processInfo.systemUptime
    let wanted = toRussian ? "ru" : "en"
    if let src = inputSources().first(where: { primaryLanguage(of: $0) == wanted }) {
        TISSelectInputSource(src)
    }
}

func layoutData(_ source: TISInputSource) -> UnsafePointer<UCKeyboardLayout>? {
    guard let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue()
    guard let bytes = CFDataGetBytePtr(data) else { return nil }
    return UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
}

/// Какой символ даёт клавиша `code` в раскладке `layout` (mod: бит 0 — Shift, бит 1 — CapsLock).
func translateKey(_ layout: UnsafePointer<UCKeyboardLayout>, code: Int, mod: Int) -> Character? {
    var dead: UInt32 = 0
    var length = 0
    var buf = [UniChar](repeating: 0, count: 4)
    var modifiers: UInt32 = 0
    if mod & 1 != 0 { modifiers |= UInt32((shiftKey >> 8) & 0xFF) }
    if mod & 2 != 0 { modifiers |= UInt32((alphaLock >> 8) & 0xFF) }
    let status = UCKeyTranslate(
        layout, UInt16(code), UInt16(kUCKeyActionDown), modifiers,
        UInt32(LMGetKbdType()), 1, &dead, 4, &length, &buf)
    guard status == noErr, length > 0 else { return nil }
    let s = String(utf16CodeUnits: buf, count: length)
    guard let c = s.first, let scalar = c.unicodeScalars.first, scalar.value >= 32 else { return nil }
    return c
}

/// Таблицы клавиш, прочитанные из реальных раскладок EN и RU (работают и на ISO-клавиатурах).
final class LayoutTables {
    var en = [Character?](repeating: nil, count: 128 * 4)
    var ru = [Character?](repeating: nil, count: 128 * 4)
    var letterKeys = Set<CGKeyCode>()       // буква и в EN, и в RU
    var punctLetterKeys = Set<CGKeyCode>()  // в EN знак, в RU буква ( [ ] ; ' , . ` )
    var wordKeys = Set<CGKeyCode>()         // всё, что может быть частью слова
    var toRu: [Character: Character] = [:]
    var toEn: [Character: Character] = [:]
    var ready = false
    var note = "не построено"

    func rebuild() {
        let sources = inputSources()
        guard let enSource = sources.first(where: { primaryLanguage(of: $0) == "en" }),
              let ruSource = sources.first(where: { primaryLanguage(of: $0) == "ru" })
        else {
            ready = false
            note = "среди включённых раскладок нет EN или RU"
            return
        }
        guard let enLayout = layoutData(enSource), let ruLayout = layoutData(ruSource) else {
            ready = false
            note = "у раскладок нет Unicode-данных"
            return
        }

        var newEn = [Character?](repeating: nil, count: 128 * 4)
        var newRu = [Character?](repeating: nil, count: 128 * 4)
        for code in 0...50 {
            for mod in 0..<4 {
                newEn[code * 4 + mod] = translateKey(enLayout, code: code, mod: mod)
                newRu[code * 4 + mod] = translateKey(ruLayout, code: code, mod: mod)
            }
        }

        var letters = Set<CGKeyCode>(), puncts = Set<CGKeyCode>(), words = Set<CGKeyCode>()
        var tRu: [Character: Character] = [:], tEn: [Character: Character] = [:]
        for code in 0...50 {
            if CGKeyCode(code) == kReturn || CGKeyCode(code) == kTab || CGKeyCode(code) == kSpace { continue }
            guard let e0 = newEn[code * 4], let r0 = newRu[code * 4] else { continue }
            let k = CGKeyCode(code)
            words.insert(k)
            if e0.isLetter && r0.isLetter {
                letters.insert(k)
            } else if !e0.isLetter && !e0.isNumber && r0.isLetter {
                puncts.insert(k)
            }
            for mod in 0..<2 {
                if let e = newEn[code * 4 + mod], let r = newRu[code * 4 + mod], e != r {
                    if tRu[e] == nil { tRu[e] = r }
                    if tEn[r] == nil { tEn[r] = e }
                }
            }
        }

        en = newEn
        ru = newRu
        letterKeys = letters
        punctLetterKeys = puncts
        wordKeys = words
        toRu = tRu
        toEn = tEn
        ready = !letters.isEmpty
        note = ready ? "ок (букв: \(letters.count), знаков-букв: \(puncts.count))" : "буквенных клавиш не найдено"
    }
}

let tables = LayoutTables()

func shownChar(_ key: Key, lang: String) -> Character? {
    let idx = Int(key.code) * 4 + ((key.shift ? 1 : 0) | (key.caps ? 2 : 0))
    guard idx >= 0, idx < 128 * 4 else { return nil }
    return lang == "ru" ? tables.ru[idx] : tables.en[idx]
}

/// Как эти клавиши выглядят в раскладке `lang` ("en" / "ru"). Пробел — пробел.
func shownString(_ keys: [Key], lang: String) -> String? {
    var out = ""
    for k in keys {
        if k.code == kSpace { out.append(" "); continue }
        guard let c = shownChar(k, lang: lang) else { return nil }
        out.append(c)
    }
    return out
}

/// Конвертирует текст в «противоположную» раскладку.
/// Возвращает результат и признак «в русскую» (true) / «в английскую» (false).
func convertText(_ text: String) -> (String, Bool) {
    let cyr = text.filter { tables.toEn[$0] != nil }.count
    let lat = text.filter { $0.isASCII && $0.isLetter }.count
    let intoEnglish = cyr > lat
    let map = intoEnglish ? tables.toEn : tables.toRu
    // В английский переводим только буквы: русские «.», «,», «?» и т.п. остаются знаками
    // (иначе «Как дела?» превратилось бы в «Rfr ltkf&»).
    let out = String(text.map { c -> Character in
        if intoEnglish && !c.isLetter { return c }
        return map[c] ?? c
    })
    return (out, !intoEnglish)
}

// MARK: - Настройки

let defaults = UserDefaults.standard

/// Раньше приложение называлось Switcher (local.layout-switcher): один раз переносим его настройки.
func migrateOldSettings() {
    guard !defaults.bool(forKey: "migratedFromSwitcher") else { return }
    defaults.set(true, forKey: "migratedFromSwitcher")
    guard let old = UserDefaults(suiteName: "local.layout-switcher") else { return }
    for key in ["userExcludedApps", "autoEnabled", "verifyEnabled", "ignoredWordHashes", "onboardingDone"] {
        if defaults.object(forKey: key) == nil, let value = old.object(forKey: key) { defaults.set(value, forKey: key) }
    }
}

/// Приложения, где автоисправление выключено всегда. Терминалы и IDE сюда не входят
/// (там тоже пишут по-русски, например запросы к ИИ) — их можно исключить через меню.
let excludedPrefixes: [String] = [
    // Виртуальные машины и удалённый рабочий стол: там своя раскладка на той стороне,
    // а смена раскладки на Mac на набор не влияет.
    "com.parallels.",
    "com.vmware.",
    "org.virtualbox.",
    "com.utmapp.",
    "com.microsoft.rdc",
    "com.apple.ScreenSharing",
    "com.citrix.",
    "com.teamviewer.",
    "com.philandro.anydesk",
    "com.realvnc.",
]

/// Приложения, которые пользователь добавил сам через меню.
var userExcludedApps: Set<String> {
    get { Set(defaults.stringArray(forKey: "userExcludedApps") ?? []) }
    set { defaults.set(Array(newValue), forKey: "userExcludedApps") }
}

func isBuiltinExcluded(_ id: String) -> Bool {
    excludedPrefixes.contains { id.hasPrefix($0) }
}

func isAutoDisabled(for id: String) -> Bool {
    id == "app.raskladushka" || isBuiltinExcluded(id) || userExcludedApps.contains(id)
}

var autoEnabled: Bool {
    get { defaults.object(forKey: "autoEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "autoEnabled") }
}

/// Проверять текст перед курсором через Accessibility, прежде чем стирать слово.
var verifyEnabled: Bool {
    get { defaults.object(forKey: "verifyEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "verifyEnabled") }
}

/// Исправлять «ДВойные заглавные» и перевёрнутый регистр от Caps Lock.
var caseFixEnabled: Bool {
    get { defaults.object(forKey: "caseFixEnabled") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "caseFixEnabled") }
}

/// Исключения добавляются явно через меню. Старые хэши остаются действующими;
/// подписи новых исключений сохраняются локально для поиска и просмотра.
var ignoredWords = Set(defaults.stringArray(forKey: "ignoredWordHashes") ?? [])
var ignoredWordLabels = defaults.dictionary(forKey: "ignoredWordLabels") as? [String: String] ?? [:]

func wordKey(_ word: String) -> String {
    SHA256.hash(data: Data(word.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
}
func isIgnoredWord(_ word: String) -> Bool { ignoredWords.contains(wordKey(word)) }
var lastIgnoredWord: String?

func saveIgnoredWords() {
    ignoredWordLabels = ignoredWordLabels.filter { ignoredWords.contains($0.key) }
    defaults.set(Array(ignoredWords), forKey: "ignoredWordHashes")
    defaults.set(ignoredWordLabels, forKey: "ignoredWordLabels")
}
func addIgnoredWord(_ word: String) {
    lastIgnoredWord = word
    ignoredWords.insert(wordKey(word))
    ignoredWordLabels[wordKey(word)] = word
    saveIgnoredWords()
}
func removeIgnoredHash(_ hash: String) {
    ignoredWords.remove(hash)
    ignoredWordLabels.removeValue(forKey: hash)
    if let word = lastIgnoredWord, wordKey(word) == hash { lastIgnoredWord = nil }
    saveIgnoredWords()
}
func removeIgnoredWord(_ word: String) { removeIgnoredHash(wordKey(word)) }
func clearIgnoredWords() {
    ignoredWords.removeAll()
    lastIgnoredWord = nil
    saveIgnoredWords()
}

struct WordExceptionRow {
    let hash: String
    let word: String?
    var title: String { word ?? "Старое исключение · " + String(hash.prefix(10)) }
}
func wordExceptionRows(query: String, hashes: Set<String>, labels: [String: String]) -> [WordExceptionRow] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return hashes.compactMap { hash -> WordExceptionRow? in
        let word = labels[hash]
        if needle.isEmpty { return WordExceptionRow(hash: hash, word: word) }
        if word?.lowercased().contains(needle) == true { return WordExceptionRow(hash: hash, word: word) }
        // Старое слово нельзя восстановить из хэша, но можно найти по точному вводу.
        if wordKey(needle) == hash { return WordExceptionRow(hash: hash, word: word ?? query) }
        return nil
    }.sorted {
        let a = $0.title.lowercased(), b = $1.title.lowercased()
        return a == b ? $0.hash < $1.hash : a < b
    }
}

/// Приложение, которое включило защищённый ввод (Secure Input): пока он включён, клавиши не видны никому.
func secureInputOwner() -> String? {
    guard IsSecureEventInputEnabled() else { return nil }
    if let dict = CGSessionCopyCurrentDictionary() as? [String: Any],
       let pid = dict["kCGSSessionSecureInputPID"] as? Int, pid > 0,
       let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
        return app.localizedName ?? app.bundleIdentifier ?? "pid \(pid)"
    }
    return "неизвестное приложение"
}

func appName(_ id: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
        return FileManager.default.displayName(atPath: url.path)
    }
    return id
}

// MARK: - Словари (системная проверка орфографии)

let spellLanguages: [String: String] = {
    var found: [String: String] = [:]
    let all = NSSpellChecker.shared.availableLanguages
    for prefix in ["en", "ru"] {
        if let lang = all.first(where: { $0.hasPrefix(prefix) }) { found[prefix] = lang }
    }
    return found
}()
let autoAvailable = spellLanguages.count == 2

var spellCache: [String: Bool] = [:]

func isValidWord(_ word: String, lang: String) -> Bool {
    guard let language = spellLanguages[lang] else { return false }
    // Проверка орфографии делит текст по знакам («[f[f» — это «f» и «f») и пропускает
    // слова чужого алфавита (кириллицу считает «верным» английским). Проверяем только буквы своего языка.
    let latin = lang == "en"
    guard let first = word.first, first.isLetter, let lastChar = word.last, lastChar.isLetter,
          word.allSatisfy({ c in
              if c == "-" || c == "'" { return true }
              guard c.isLetter else { return false }
              return latin ? c.isASCII : !c.isASCII
          })
    else { return false }
    let cacheKey = lang + "|" + word
    if let cached = spellCache[cacheKey] { return cached }
    func check(_ w: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(
            of: w, startingAt: 0, language: language, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
    }
    // Слово целиком из заглавных проверка орфографии принимает всегда (считает аббревиатурой),
    // поэтому «ПРИВЕТ» / «МЗЫ» проверяем строчными.
    let allCaps = word.count > 1 && word == word.uppercased() && word != word.lowercased()
    // Так же любым она принимает «пРИВЕТ», «gHBDTN» (Caps Lock включился посреди слова).
    var capsTail = false
    if !allCaps, let i = word.firstIndex(where: { $0.isUppercase }), i != word.startIndex,
       word[i...].allSatisfy({ $0.isUppercase }), word[i...].count >= 2 { capsTail = true }
    let result = allCaps || capsTail ? check(word.lowercased()) : (check(word) || check(word.lowercased()))
    if spellCache.count > 4000 { spellCache.removeAll() }
    spellCache[cacheKey] = result
    return result
}

/// Английские сокращения без апострофа.
let looseContractions: Set<String> = [
    "dont", "cant", "wont", "isnt", "arent", "wasnt", "werent", "doesnt", "didnt",
    "couldnt", "wouldnt", "shouldnt", "hasnt", "havent", "hadnt", "youre", "youve",
    "thats", "whats", "theres", "im", "ive", "ill", "id", "hes", "shes", "theyre",
]

/// Известные технические сокращения и аббревиатуры (считаются английскими словами).
let techWords: Set<String> = [
    "ide", "api", "cli", "gui", "sdk", "jdk", "jvm", "json", "http", "https", "url", "uri",
    "usb", "ssd", "hdd", "cpu", "gpu", "rtx", "wifi", "ios", "macos", "git", "ssh", "css",
    "html", "php", "sql", "svg", "pdf", "xml", "yml", "yaml", "npm", "tmp", "src", "cmd",
    "vpn", "dns", "cdn", "tsx", "jsx", "pls", "plz", "hmm", "wtf", "wth", "btw", "brb",
    "idk", "imo", "tbh", "nvm", "thx", "smh", "ppl", "nth", "bks",
    "tcp", "udp", "ssl", "tls", "ftp", "smtp", "imap", "ldap", "sudo", "chmod", "grep", "pip",
    "venv", "repo", "docker", "nginx", "kubectl", "regex", "localhost", "stdout", "stdin",
    "async", "await", "pkg", "lib", "bin", "usr", "env", "std", "dev", "prod",
    "iphone", "ipad", "ipod", "macbook", "imac", "airpods", "youtube", "github", "gitlab",
    "telegram", "whatsapp", "instagram", "facebook", "twitter", "linkedin", "chatgpt", "openai",
    "claude", "google", "gmail", "android", "windows", "linux", "ubuntu", "python", "kotlin",
    "javascript", "typescript", "nodejs", "wikipedia", "spotify", "netflix", "tiktok", "discord",
    "slack", "zoom", "figma", "notion", "safari", "chrome", "firefox", "xcode", "pycharm",
    "gpt", "llm", "nlp", "ocr", "gtx", "fps", "dpi", "gps", "sms", "mms", "nfc", "rgb",
    "ctrl", "cvv", "pwd", "nvme", "hdmi", "wasm", "grpc", "rpc", "orm", "mvp", "ceo", "cto",
    // Сокращения из переписки и прочее, что статистически похоже на русский набор.
    "afk", "jfc", "ctx", "gtg", "xd", "nft", "btc", "eth", "usdt", "utf", "ikr", "lmk", "lgtm",
    "rsvp", "ftw", "tbd", "faq", "fyi", "eta", "wip", "tldr", "imho", "lmao", "rofl", "smth",
    "sth", "ngl", "kpi", "okr", "crm", "erp", "saas", "airbnb", "bybit", "csgo", "pnpm", "kafka",
    "idc", "omw", "irl", "diy", "ttyl", "args", "kwargs", "enum", "impl", "func", "regexp",
    "swiftui", "vscode", "webpack", "grafana", "jira", "yandex", "avito", "sber", "tinkoff",
    "vercel", "netlify", "nextjs", "nuxt", "vuejs", "reactjs", "mongodb", "postgres", "redis",
    "supabase", "firebase", "heroku", "whatsapp", "clickup", "macbook", "airdrop", "icloud", "usa",
    // Аббревиатуры (серверы, сети, форматы файлов, бренды): ни словарь, ни статистика их не узнают.
    // Не добавлять те, что в английской раскладке совпадают с русскими словами: eps=узы, exe=учу,
    // ghz=пря, jre=оку, led=дув — иначе эти русские слова перестанут исправляться.
    "acer", "acl", "aks", "alexa", "amd", "amqp", "apk", "apt", "arpu", "arr", "asp", "asus",
    "audi", "aux", "avi", "aws", "bios", "blizzard", "bluetooth", "bmw", "bps", "brew", "cam",
    "cia", "cms", "cname", "cors", "covid", "cpa", "cpc", "cpm", "crud", "csrf", "csv", "cta",
    "cuda", "dau", "ddos", "dell", "dhcp", "displayport", "dkim", "dmarc", "dmg", "dnf", "docx",
    "dvi", "eks", "epic", "esxi", "etl", "eula", "fbi", "fhd", "gbps", "gcp", "gdpr", "gif", "gke",
    "grub", "hbo", "hdr", "heic", "hipaa", "homekit", "iaas", "iam", "ibm", "ikea", "img", "intel",
    "ipa", "ipados", "ips", "iso", "jack", "jpeg", "jpg", "jsp", "jwt", "kms", "kvm", "lan", "lcd",
    "lenovo", "ltv", "lxc", "mau", "mbps", "mediatek", "mhz", "mic", "mkv", "mov", "mqtt", "mrr",
    "msi", "mvc", "mvvm", "nas", "nasa", "nat", "nato", "nintendo", "nosql", "nvidia", "oauth",
    "oled", "otf", "paas", "pci", "pcie", "playstation", "png", "poc", "ppc", "pptx", "proxy",
    "psd", "pwa", "qhd", "qualcomm", "raid", "ram", "rar", "rbac", "rdp", "rds", "repl", "rest",
    "roi", "rom", "rpm", "saml", "sata", "scp", "seo", "sftp", "siri", "sla", "smm", "socks",
    "sony", "sox", "spa", "spf", "ssg", "sso", "ssr", "steam", "svn", "thunderbolt", "tiff",
    "torrent", "tos", "tpu", "ttf", "ttl", "tui", "tvos", "uat", "ubisoft", "uefi", "uhd", "unesco",
    "usbc", "utm", "valve", "vds", "vga", "visionos", "vms", "vnc", "vps", "waf", "wan", "watchos",
    "webp", "woff", "xbox", "xls", "xlsx", "xss", "yum", "zfs", "zip",
]

/// Частые слова из 1–2 букв. Для них словарь ненадёжен (он принимает любые аббревиатуры),
/// поэтому короткие слова исправляются только по этим спискам.
let commonShort: [String: Set<String>] = [
    "ru": ["я", "в", "к", "с", "у", "и", "а", "о", "да", "не", "ну", "но", "на", "за", "по", "от",
           "до", "из", "ко", "во", "об", "он", "мы", "вы", "их", "её", "ее", "ей", "им", "ты", "то",
           "же", "ли", "бы", "уж", "ок", "ой", "ах", "эх", "ох", "ха", "ща", "хз", "мб", "го", "чё",
           "чо", "шо", "лс", "шт", "тг", "вк", "кг", "км", "см", "мм", "гб", "мл", "рф", "сб", "вс",
           "пн", "вт", "ср", "чт", "пт", "ул", "эт", "те"],
    "en": ["a", "i", "of", "to", "in", "it", "is", "be", "as", "at", "so", "we", "he", "by", "or",
           "on", "do", "if", "me", "my", "up", "an", "go", "no", "us", "am", "hi", "ok", "oh", "vs",
           "tv", "pc", "id", "ex", "ah", "uh", "ha", "yo", "ya", "ux", "ui", "ai", "js", "ts", "db",
           "io", "os", "pr", "qa", "ip", "hr", "fr", "np", "ty", "gg", "jk", "dm", "pm", "mr", "ms",
           "eu", "uk", "la", "ny", "re", "cc", "bc", "rn", "wp", "gl", "hf"],
]

/// Во что короткое слово можно исправить. «мы» -> «vs» не делаем: «vs» почти всегда набрано нарочно.
let shortTargets: [String: Set<String>] = [
    "ru": ["я", "в", "к", "с", "у", "и", "а", "о", "да", "не", "ну", "но", "на", "за", "по", "от",
           "до", "из", "ко", "во", "об", "он", "мы", "вы", "их", "её", "ее", "ей", "им", "ты", "то",
           "же", "ли", "бы", "уж", "ок", "ой", "ах", "эх", "ох", "ха", "ща", "хз", "мб", "го", "чё",
           "чо", "шо", "те"],
    "en": ["a", "i", "of", "to", "in", "it", "is", "be", "as", "at", "so", "we", "he", "by", "or",
           "on", "do", "if", "me", "my", "up", "an", "go", "no", "us", "am", "hi", "ok", "oh"],
]

/// Частые русские аббревиатуры: словарь их не знает, а набранные капсом они похожи на мусор.
let ruAbbreviations: Set<String> = [
    "мгу", "сша", "снг", "мвд", "ооо", "зао", "оао", "пао", "нко", "жкх", "ндс", "ндфл", "вуз", "ржд",
    "гост", "мчс", "гибдд", "гаи", "дпс", "фсб", "фнс", "пфр", "фсс", "дтп", "егэ", "огэ", "сми",
    "мфц", "цб", "трц", "азс", "сто", "кпп", "инн", "снилс", "огрн", "бик", "кбк", "окпо", "ип",
    "рф", "спб", "мск", "нск", "екб", "ссср", "оон", "ес", "вкс", "рпц", "мид", "минфин", "росстат",
    "ржач", "пмж", "внж", "рвп", "загс", "бти", "жк", "тц", "тт", "чп", "зп", "пк", "ос", "лс", "др",
    "вс", "тв", "мтс", "мгтс", "втб", "сбер", "мкад", "ттк", "вднх", "цска", "спартак", "кхл", "рпл",
    "вшэ", "мфти", "мгту", "фгуп", "гкб",
]

/// Междометия, которых нет в словаре, а статистика считает английским набором («ыгы» = sus).
let ruInterjections: Set<String> = ["гыы", "ыгы", "гыгы"]

/// Расширения файлов и домены верхнего уровня: по ним «РФТВЩААюЬВ» узнаётся как HANDOFF.MD.
let fileExtensions: Set<String> = [
    "md", "txt", "rtf", "log", "csv", "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "xml",
    "html", "htm", "css", "scss", "js", "ts", "jsx", "tsx", "mjs", "vue", "py", "rb", "go", "rs", "java",
    "kt", "swift", "sh", "zsh", "c", "h", "cpp", "hpp", "cs", "php", "sql", "lock", "plist",
    "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers",
    "jpg", "jpeg", "png", "gif", "svg", "webp", "heic", "mp3", "mp4", "mov", "avi", "mkv", "wav",
    "zip", "rar", "gz", "tar", "dmg", "pkg", "app", "exe", "apk", "ipa", "iso",
    "com", "org", "net", "io", "ru", "su", "dev", "ai", "me", "co", "info", "edu", "gov", "uk", "de",
    "us", "tv", "by", "kz", "ua", "eu", "fm", "cc", "xyz", "site", "online", "pro", "store", "tech",
]

/// Редкие русские слова, совпадающие с техническими сокращениями в другой раскладке:
/// «шву» почти всегда — набранное не в той раскладке «ide». Частые («еды», «азы») сюда не добавлять.
let rareRuCollisions: Set<String> = ["шву", "сеч", "илы", "фал", "сущ"]

func isKnownEnglishAbbreviation(_ word: String) -> Bool {
    techWords.contains(word.lowercased())
}

func isValidEnglish(_ word: String) -> Bool {
    let l = word.lowercased()
    return techWords.contains(l) || looseContractions.contains(l) || isValidWord(word, lang: "en")
}

/// Слово (любой длины) есть в языке: короткие — по спискам, длинные — по словарю.
func isWordIn(_ word: String, lang: String) -> Bool {
    let l = word.lowercased()
    if l.count <= 2 { return commonShort[lang]?.contains(l) ?? false }
    return lang == "en" ? isValidEnglish(word) : isValidWord(word, lang: lang)
}

// MARK: - Статистика буквосочетаний: «насколько слово похоже на язык»

/// Модель троек букв, построенная по частым словам системных словарей (см. Ngrams.swift).
/// Помогает со словами, которых нет в словаре: имена, сленг, бренды, новые слова.
final class TrigramModel {
    private var tri: [String: Double] = [:]
    private var ctx2: [String: Double] = [:]
    private var bi: [String: Double] = [:]
    private var ctx1: [Character: Double] = [:]
    private var uni: [Character: Double] = [:]
    private var total = 0.0

    init(_ data: String) {
        for item in data.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            let chars = Array(item)
            guard chars.count > 3, let n = Double(String(chars[3...])) else { continue }
            tri[String(chars[0..<3]), default: 0] += n
            ctx2[String(chars[0..<2]), default: 0] += n
            bi[String(chars[1..<3]), default: 0] += n
            ctx1[chars[1], default: 0] += n
            uni[chars[2], default: 0] += n
            total += n
        }
    }

    /// Средний логарифм вероятности на символ: чем выше, тем естественнее слово для языка.
    func score(_ word: String) -> Double {
        let s = Array("^^" + word.lowercased() + "$")
        var sum = 0.0
        for i in 2..<s.count {
            let a = s[i - 2], b = s[i - 1], c = s[i]
            var p = 1e-6
            if let n = tri[String([a, b, c])], let d = ctx2[String([a, b])], d > 0 { p += 0.6 * n / d }
            if let n = bi[String([b, c])], let d = ctx1[b], d > 0 { p += 0.3 * n / d }
            if let n = uni[c] { p += 0.1 * n / total }
            sum += log(p)
        }
        return sum / Double(s.count - 2)
    }
}

let ruModel = TrigramModel(ruTrigramData)
let enModel = TrigramModel(enTrigramData)

/// На сколько `target` (в языке targetLang) естественнее, чем `shown` (в языке shownLang).
/// > 0 — набор больше похож на слово другого языка.
func layoutMargin(shown: String, shownLang: String, target: String, targetLang: String) -> Double {
    let t = targetLang == "ru" ? ruModel.score(target) : enModel.score(target)
    let s = shownLang == "ru" ? ruModel.score(shown) : enModel.score(shown)
    return t - s
}

// MARK: - Взвешенное решение «менять раскладку?»

/// Признаки решения и их веса (по образцу KbmFeature у Caramba: у признака есть вес, решает сумма).
/// Подобраны по выгрузке `bash tools/tune.sh` (≈13 тыс. слов: словари, имена, сленг, бренды — в обеих раскладках):
/// - разница естественности (`layoutMargin`) — основной признак, вес 1;
/// - слово есть в словаре другой раскладки — сильный довод «за», но очень «английский» вид набора
///   его перевешивает: «sus» -> «ыгы» больше не исправляется;
/// - слово есть в словаре текущей раскладки — решающий довод «против»: слова, верные в обеих
///   раскладках («руки»/herb, «The»/«Еру»), по одному слову не различить — их оставляем двойному Shift;
/// - длина: чем короче слово, тем меньше доверия статистике. Верно набранные слова вне словаря
///   (≈5700 на двух выборках) поднимались до: 4–5 букв +0,54, 6–7 букв +0,32, 8+ букв −0,07;
///   пороги стоят выше с запасом ≥0,28. Для 4–5 букв прежний порог 0,65 и был лучшим.
/// - известное сокращение из списков (techWords) — решающий довод: статистика у «jwt», «vps» бессильна;
/// - знаки внутри английского вида слова («index.html», «github.io») — довод «против»: веса подбирались
///   по словам из одних букв, а такие слова чаще имена файлов и код.
enum DecisionWeight {
    static let targetWord = 3.0
    static let targetListed = 10.0
    static let sourceWord = -10.0
    static let innerPunctuation = -0.4
    static let cautious = -0.5

    static func length(_ n: Int) -> Double {
        switch n {
        case ...3: return -1.5
        case 4...5: return -0.65
        case 6...7: return -0.6
        default: return -0.35
        }
    }
}

struct SwitchScore {
    let total: Double
    let explanation: String
    var convert: Bool { total >= 0 }
}

/// Сумма доводов за смену раскладки: ≥ 0 — менять.
func switchScore(margin: Double, sourceWord: Bool, targetWord: Bool, targetListed: Bool = false,
                 innerPunctuation: Bool = false, length: Int, cautious: Bool) -> SwitchScore {
    var total = margin + DecisionWeight.length(length)
    var parts = [String(format: "модель %+.2f", margin), String(format: "длина %+.2f", DecisionWeight.length(length))]
    func add(_ on: Bool, _ weight: Double, _ name: String) {
        guard on else { return }
        total += weight
        parts.append(name + String(format: " %+.1f", weight))
    }
    add(targetListed, DecisionWeight.targetListed, "сокращение там")
    add(targetWord && !targetListed, DecisionWeight.targetWord, "слово там")
    add(sourceWord, DecisionWeight.sourceWord, "слово тут")
    add(innerPunctuation, DecisionWeight.innerPunctuation, "знаки внутри")
    add(cautious, DecisionWeight.cautious, "после автоисправления")
    return SwitchScore(total: total, explanation: parts.joined(separator: ", ") + String(format: " = %+.2f", total))
}

/// Порог для одной статистики (без словарей): слова через дефис и т. п.
func marginThreshold(length: Int, cautious: Bool) -> Double {
    -DecisionWeight.length(length) - (cautious ? DecisionWeight.cautious : 0)
}

// MARK: - Ошибки регистра («ДВойные заглавные», забытый Caps Lock)

enum CaseSlip {
    /// «ПРивет», «THe»: Shift отпустили на букву позже.
    case twoInitialCaps
    /// «пРИВЕТ», «приВЕТ»: посреди слова задели Caps Lock (он рядом с A/Ф).
    /// В macOS Shift при включённом Caps Lock даёт ЗАГЛАВНЫЕ (не как в Windows), поэтому
    /// «hELLO» от Shift не бывает — узнаём ошибку по самим нажатиям: Caps Lock включился внутри слова.
    case capsLockMidWord
}

/// Сочетания вида «ДВойных заглавных», которые так и пишутся: единицы измерения, бренды.
let caseSlipExceptions: Set<String> = ["mhz", "ghz", "khz", "thz", "mbps", "kbps", "gbps", "tbps", "вконтакте"]

/// Ошибка регистра в слове из букв (от 3 символов), как оно выглядит в раскладке `lang`.
/// Возвращает вид ошибки и клавиши с исправленным регистром; nil — регистр выглядит нарочным.
func caseSlip(_ keys: [Key], lang: String) -> (slip: CaseSlip, fixed: [Key])? {
    guard keys.count >= 3, let word = shownString(keys, lang: lang), word.allSatisfy({ $0.isLetter })
    else { return nil }
    let lower = word.lowercased()
    // OAuth, iOS — так пишутся; IDs, PCs, URLs — множественное число аббревиатур.
    if techWords.contains(lower) || caseSlipExceptions.contains(lower) { return nil }

    // Caps Lock включился внутри слова: до него без Caps Lock, после — с ним и без Shift.
    // Слово целиком ЗАГЛАВНЫМИ («ПРИВЕТ» = Shift+П, потом Caps Lock) выглядит нарочным — не трогаем.
    if let first = keys.firstIndex(where: { $0.caps }), first > 0, word != word.uppercased(),
       keys[first...].allSatisfy({ $0.caps && !$0.shift }) {
        return (.capsLockMidWord, keys.map { Key(code: $0.code, flags: $0.cgFlags.subtracting(.maskAlphaShift)) })
    }
    let chars = Array(word)
    let upper = chars.map { $0.isUppercase }
    if upper[0] && upper[1] && !upper[2...].contains(true) {
        let rest = String(chars[2...])
        if rest == "s" || rest == "es" { return nil }
        let fixed = keys.enumerated().map { i, k in Key(code: k.code, flags: i == 0 ? .maskShift : []) }
        return (.twoInitialCaps, fixed)
    }
    return nil
}

/// Выключает Caps Lock (после исправления «пРИВЕТ» -> «Привет», как это делает Word).
func turnOffCapsLock() {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    var connect: io_connect_t = 0
    guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS
    else { return }
    defer { IOServiceClose(connect) }
    IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
}

// MARK: - Синтетические нажатия

/// `text` — готовый символ: приложение получает его, не переводя клавишу через свою раскладку.
/// Нужно потому, что смена раскладки доходит до приложения с задержкой (Spotlight, лаунчеры),
/// и первая клавиша после переключения иначе напечаталась бы ещё в старой раскладке.
func tapKey(_ code: CGKeyCode, flags: CGEventFlags = [], text: String? = nil) {
    let source = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
        // Флаги задаём явно, чтобы физически зажатые Shift/Option не влияли на результат.
        e.flags = flags
        if let text = text {
            let units = Array(text.utf16)
            e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        }
        e.setIntegerValueField(.eventSourceUserData, value: magic)
        e.post(tap: .cghidEventTap)
    }
}

/// Печатает клавиши символами раскладки `lang` (с небольшой паузой: поля поиска не теряют нажатия).
func typeKeys(_ keys: [Key], lang: String) {
    for k in keys {
        tapKey(k.code, flags: k.cgFlags, text: shownChar(k, lang: lang).map { String($0) })
        usleep(1000)
    }
}

func tapBackspaces(_ count: Int) {
    for _ in 0..<max(count, 0) {
        tapKey(kBackspace)
        usleep(1000)
    }
}

// MARK: - Проверка текста перед курсором (Accessibility)

/// Приложение, в чьём поле сейчас курсор. Spotlight и лаунчеры не становятся «активным» приложением,
/// поэтому frontmostApplication показал бы то, что под ними (например, терминал из исключений).
func focusedAppBundleID() -> String? {
    let system = AXUIElementCreateSystemWide()
    var ref: CFTypeRef?
    if AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &ref) == .success,
       let r = ref {
        var pid: pid_t = 0
        if AXUIElementGetPid(r as! AXUIElement, &pid) == .success,
           let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            return id
        }
    }
    return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}

/// Electron по умолчанию может не публиковать дерево доступности.
/// Запрашиваем его один раз для активного Electron-процесса, до обработки клавиш.
var accessibilityPrepared = Set<pid_t>()
var accessibilityPreparationNote = "не требовалась"
func prepareAccessibility(for app: NSRunningApplication) {
    guard let url = app.bundleURL,
          FileManager.default.fileExists(atPath: url.appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path),
          accessibilityPrepared.insert(app.processIdentifier).inserted else { return }
    let result = AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
        "AXManualAccessibility" as CFString, kCFBooleanTrue)
    accessibilityPreparationNote = "\(app.bundleIdentifier ?? "Electron"): AXManualAccessibility = \(result.rawValue)"
}

func readFocusedElement(from scope: AXUIElement) -> AXUIElement? {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(scope, kAXFocusedUIElementAttribute as CFString, &ref) == .success,
          let ref = ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return (ref as! AXUIElement)
}

func focusedInputElement(
    systemRead: () -> AXUIElement? = { readFocusedElement(from: AXUIElementCreateSystemWide()) },
    applicationRead: () -> AXUIElement? = {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return readFocusedElement(from: AXUIElementCreateApplication(app.processIdentifier))
    }
) -> AXUIElement? {
    systemRead() ?? applicationRead()
}

/// Идентичность поля, в котором началась операция. Текст и положение курсора могут меняться,
/// но отложенный ввод не должен переходить в другое поле или защищённый ввод.
struct InputTarget {
    let element: AXUIElement
    static func capture() -> InputTarget? {
        guard !IsSecureEventInputEnabled() else { return nil }
        guard let element = focusedInputElement() else { return nil }
        return InputTarget(element: element)
    }
    func isCurrent() -> Bool {
        guard let now = InputTarget.capture() else { return false }
        return CFEqual(element, now.element)
    }
    func mismatchDescription() -> String {
        if IsSecureEventInputEnabled() { return "включился защищённый ввод" }
        guard let now = InputTarget.capture() else { return "активное поле недоступно через Accessibility" }
        var oldPID: pid_t = 0, newPID: pid_t = 0
        AXUIElementGetPid(element, &oldPID)
        AXUIElementGetPid(now.element, &newPID)
        if oldPID != newPID { return "изменился процесс активного поля" }
        return "изменился AX-элемент поля в том же процессе"
    }
}

/// Текст поля до курсора (до начала выделения) и выделение после него.
struct CaretContext: Equatable {
    let before: String
    let selection: Int
    let tail: Int  // сколько символов после выделения
    /// Выделение до конца поля — это автодополнение (Spotlight, адресная строка):
    /// настоящее выделение мышью или Shift+стрелками и так сбрасывает буфер.
    var completion: Bool { selection > 0 && tail == 0 }
}

/// nil — приложение не отдаёт текст через Accessibility.
func caretContext() -> CaretContext? {
    guard let element = focusedInputElement() else { return nil }

    var valueRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
          let value = valueRef as? String else { return nil }

    var rangeRef: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
          let rangeValue = rangeRef else { return nil }
    var range = CFRange(location: 0, length: 0)
    guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else { return nil }

    let ns = value as NSString
    guard range.location >= 0, range.length >= 0, range.location + range.length <= ns.length else { return nil }
    return CaretContext(before: ns.substring(to: range.location), selection: range.length,
                        tail: ns.length - range.location - range.length)
}

/// «Умные» кавычки и тире, которые приложения подставляют сами, сравниваем как обычные.
func normalizedForCompare(_ s: String) -> String {
    String(s.map { c -> Character in
        switch c {
        case "‘", "’", "‚", "‛", "′": return "'"
        case "“", "”", "„", "″": return "\""
        case "\u{00A0}": return " "
        default: return c
        }
    })
}

enum CaretCheck {
    case match(CaretContext)
    case mismatch
    case unknown  // приложение не отдаёт текст, проверить нельзя
}

/// Совпадает ли текст перед курсором (перед автодополнением) с `expected`.
func checkBeforeCaret(_ expected: String, context: CaretContext? = caretContext()) -> CaretCheck {
    guard let ctx = context else { return .unknown }
    if ctx.selection > 0 && !ctx.completion { return .mismatch }
    let ns = ctx.before as NSString
    let count = expected.utf16.count
    guard ns.length >= count else { return .mismatch }
    let actual = ns.substring(from: ns.length - count)
    // Регистр не важен: приложения сами делают заглавной первую букву предложения.
    return normalizedForCompare(actual).lowercased() == normalizedForCompare(expected).lowercased()
        ? .match(ctx) : .mismatch
}

// MARK: - Буфер обмена (полная копия содержимого)

func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
    (pb.pasteboardItems ?? []).map { item in
        var d: [NSPasteboard.PasteboardType: Data] = [:]
        for t in item.types {
            if let data = item.data(forType: t) { d[t] = data }
        }
        return d
    }
}

func restorePasteboard(_ pb: NSPasteboard, _ snapshot: [[NSPasteboard.PasteboardType: Data]]) {
    pb.clearContents()
    let items = snapshot.map { dict -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in dict { item.setData(data, forType: type) }
        return item
    }
    if !items.isEmpty { pb.writeObjects(items) }
}

// MARK: - Логика

struct Plan {
    let keys: [Key]          // что стереть и напечатать заново (без «придержанной» клавиши-триггера)
    let toRussian: Bool
    let fromLang: String
    let shownLower: String   // как слово выглядело до исправления (для личных исключений)
    var retype: [Key]? = nil // что напечатать вместо keys (исправленный регистр); nil — те же клавиши
    var capsOff = false      // выключить Caps Lock («пРИВЕТ» набран с включённым Caps Lock)

    var typed: [Key] { retype ?? keys }
    /// Только регистр, раскладка та же.
    var caseOnly: Bool { (toRussian ? "ru" : "en") == fromLang }
}

enum Verdict {
    case convert(Bool, String, String)  // в русскую?, как выглядело слово, пояснение
    case keep(String)                   // причина, почему не трогаем
}

/// Слово, набранное перед текущим, и что стояло между ними (пробел, дефис или «знак + пробел»).
struct PrevWord {
    let keys: [Key]
    let sep: [Key]
}

/// Лаунчеры и поиск: там слово часто не заканчивают пробелом, поэтому исправляем и по паузе.
let searchApps = ["com.apple.Spotlight", "com.raycast.macos", "com.runningwithcrayons.Alfred", "at.obdev.LaunchBar"]

/// Проверяем только известное поле Safari, а не все текстовые поля браузера.
func supportsIdleCorrection(appID: String?, subrole: String?, identifier: String?) -> Bool {
    if let id = appID, searchApps.contains(where: { id.hasPrefix($0) }) { return true }
    if subrole == (kAXSearchFieldSubrole as String) { return true }
    return appID == "com.apple.Safari" && identifier == "WEB_BROWSER_ADDRESS_AND_SEARCH_FIELD"
}

func isSearchFieldFocused() -> Bool {
    let appID = focusedAppBundleID()
    if supportsIdleCorrection(appID: appID, subrole: nil, identifier: nil) { return true }
    guard let element = focusedInputElement() else { return false }
    func attribute(_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? String
    }
    return supportsIdleCorrection(appID: appID, subrole: attribute(kAXSubroleAttribute as String),
        identifier: attribute(kAXIdentifierAttribute as String))
}

final class Switcher {
    var buffer: [Key] = []
    /// Слова перед текущим: «Ш вщте» -> «I dont», «gj-heccrb» -> «по-русски».
    var prevWords: [PrevWord] = []
    /// Почему последнее слово было исправлено или пропущено (без самих букв — для диагностики).
    var lastDecision = "после знака/пробела ещё не было слов"
    /// Как прошла последняя замена слова в поле (для диагностики).
    var lastReplaceNote = "замен ещё не было"

    var lastShiftPress: TimeInterval = 0
    var shiftWasDown = false
    var comboWasDown = false

    /// Идёт исправление: нажатия пользователя откладываются и повторяются после него.
    var busy = false { didSet { if busy { operationGeneration += 1; busySince = ProcessInfo.processInfo.systemUptime } } }
    var operationGeneration = 0
    var busySince: TimeInterval = 0
    var pending: [Key] = []
    /// Отменённый ввод хранится только в памяти, до явного копирования или удаления.
    var recoveredInputs: [String] = []
    var deletedText: String?
    var heldBoundary: String?
    var recoveryChanged: (() -> Void)?
    var lastUndoCandidate: String?

    func recoverPending() {
        let lang = currentLayoutLanguage() ?? "en"
        var text = (deletedText ?? "") + (heldBoundary ?? "")
        for key in pending {
            if key.code == kBackspace { if !text.isEmpty { text.removeLast() } }
            else if key.code == kReturn || key.code == kKeypadEnter { text += "\n" }
            else if key.code == kTab { text += "\t" }
            else if let char = shownChar(key, lang: lang) { text.append(char) }
        }
        if !text.isEmpty { recoveredInputs.append(text); recoveryChanged?() }
    }
    var swallowedUps: Set<CGKeyCode> = []

    /// Последнее автоисправление — чтобы распознать отмену.
    var lastAuto: (buffer: [Key], shown: String, time: TimeInterval)?
    /// Раскладка, в которую только что переключило автоисправление.
    var lastAutoLang: String?
    /// Последнее исправление регистра: двойной Shift сразу после него возвращает как было.
    var lastCaseFix: (buffer: [Key], original: [Key], lang: String, shown: String, time: TimeInterval)?

    /// Проверка слова по паузе (только в полях поиска).
    private var idleWork: DispatchWorkItem?
    private var keyGeneration = 0

    func reset(reason: String = "сброшен буфер ввода") {
        if busy { cancelOperation(reason: reason) }
        buffer.removeAll()
        prevWords.removeAll()
        idleWork?.cancel()
    }

    func cancelOperation(reason: String = "поле ввода или действие пользователя изменилось") {
        operationGeneration += 1
        busy = false
        recoverPending()
        deletedText = nil
        heldBoundary = nil
        pending.removeAll()
        buffer.removeAll()
        prevWords.removeAll()
        lastAuto = nil
        lastCaseFix = nil
        idleWork?.cancel()
        lastReplaceNote = "замена отменена: " + reason
    }

    func operationIsCurrent(_ generation: Int, target: InputTarget) -> Bool {
        guard generation == operationGeneration else { return false }
        guard target.isCurrent() else { cancelOperation(reason: target.mismatchDescription()); return false }
        return true
    }

    /// Возвращает true, если событие нужно «проглотить» (не пускать в приложение).
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if event.getIntegerValueField(.eventSourceUserData) == magic { return false }
        let now = ProcessInfo.processInfo.systemUptime
        if busy && now - busySince > 1.0 {  // страховка от зависания
            cancelOperation(reason: "операция длится больше секунды")
        }
        switch type {
        case .keyDown:
            return onKeyDown(event)
        case .keyUp:
            let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            return swallowedUps.remove(code) != nil
        case .flagsChanged:
            onFlagsChanged(event)
            return false
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            reset(reason: "нажата кнопка мыши")
            return false
        default:
            return false
        }
    }

    // MARK: Клавиши

    /// Пробел, Enter и знаки, которые в обеих раскладках остаются знаками («?» ↔ «,», «-», «!» …).
    private func isTrigger(_ key: Key) -> Bool {
        if key.code == kSpace || key.code == kReturn || key.code == kKeypadEnter { return true }
        guard tables.wordKeys.contains(key.code),
              let e = shownChar(key, lang: "en"), let r = shownChar(key, lang: "ru") else { return false }
        return !e.isLetter && !e.isNumber && !r.isLetter && !r.isNumber
    }

    private func isHyphen(_ key: Key) -> Bool {
        shownChar(key, lang: "en") == "-" && shownChar(key, lang: "ru") == "-"
    }

    private func isEndKey(_ key: Key?) -> Bool {
        guard let key = key else { return true }  // пауза в поиске
        return key.code == kReturn || key.code == kKeypadEnter || key.code == kTab
    }

    /// Что может стоять между словами одной фразы: пробел, дефис, знак и пробел («lf? rjytxyj»).
    private func isChainSeparator(_ sep: [Key]) -> Bool {
        if sep.count == 1 { return sep[0].code == kSpace || isHyphen(sep[0]) }
        if sep.count == 2 { return sep[1].code == kSpace && sep[0].code != kSpace && !isHyphen(sep[0]) }
        return false
    }

    private func onKeyDown(_ event: CGEvent) -> Bool {
        lastShiftPress = 0  // любая клавиша прерывает «двойной Shift»
        keyGeneration += 1
        idleWork?.cancel()
        let flags = event.flags
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let commandLike = flags.contains(.maskCommand) || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)

        if busy {
            if commandLike { reset(reason: "нажато сочетание Command/Control/Option"); return false }
            // Пока идёт исправление, откладываем набор и повторим его после.
            pending.append(Key(code: code, flags: flags))
            swallowedUps.insert(code)
            return true
        }
        // Cmd+Enter (отправка в Slack, Telegram и т.п.) обрабатываем как обычный Enter.
        let isCmdReturn = (code == kReturn || code == kKeypadEnter) && flags.contains(.maskCommand)
            && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
        if commandLike && !isCmdReturn {
            reset()
            return false
        }

        let key = Key(code: code, flags: flags)

        if code == kBackspace {
            if !buffer.isEmpty { buffer.removeLast() }
            if buffer.isEmpty { prevWords.removeAll() }
            return false
        }

        // Пробел, Enter, знаки и Tab (переход к следующему полю) завершают слово.
        if isTrigger(key) || code == kTab {
            if let plan = planCorrection(trigger: key) {
                // Придерживаем клавишу, исправляем слово и вводим клавишу уже после.
                swallowedUps.insert(code)
                busy = true
                let replayFlags = flags.intersection([.maskShift, .maskAlphaShift, .maskCommand])
                let generation = operationGeneration
                guard let target = InputTarget.capture() else { cancelOperation(reason: "исходное поле недоступно через Accessibility"); return false }
                DispatchQueue.main.async {
                    guard self.operationIsCurrent(generation, target: target) else { return }
                    self.perform(plan, trigger: key, triggerFlags: replayFlags)
                }
                return true
            }
            if code == kTab { reset() } else { registerBoundary(key) }
            return false
        }

        if tables.wordKeys.contains(code) {
            registerTyped(key)
            scheduleIdleCheck()
        } else {
            reset()  // стрелки, Esc и т.п.
        }
        return false
    }

    private func registerBoundary(_ key: Key) {
        if key.code == kReturn || key.code == kKeypadEnter {
            reset()
            return
        }
        // Граница остаётся в буфере: слово можно исправить и после неё (двойной Shift).
        if !buffer.isEmpty { buffer.append(key) }
    }

    private func registerTyped(_ key: Key) {
        if let last = buffer.last, isTrigger(last) {  // началось новое слово
            var word = buffer
            var sep: [Key] = []
            while let l = word.last, isTrigger(l) { sep.insert(word.removeLast(), at: 0) }
            // Запоминаем предыдущее слово, только если между словами пробел, дефис или «знак + пробел».
            if !word.isEmpty && isChainSeparator(sep) {
                prevWords.append(PrevWord(keys: word, sep: sep))
                if prevWords.count > 4 { prevWords.removeFirst() }
            } else {
                prevWords.removeAll()
            }
            buffer.removeAll()
        }
        buffer.append(key)
        if buffer.count > 64 { buffer.removeFirst() }
    }

    /// В поиске (Spotlight, Raycast, Alfred, поля поиска) пробел обычно не нажимают —
    /// проверяем слово, когда набор замер.
    private func scheduleIdleCheck() {
        guard autoEnabled else { return }
        let generation = keyGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.busy, generation == self.keyGeneration,
                  let last = self.buffer.last, !self.isTrigger(last), isSearchFieldFocused(),
                  let plan = self.planCorrection(trigger: nil) else { return }
            self.busy = true
            self.perform(plan, trigger: nil, triggerFlags: [])
        }
        idleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func onFlagsChanged(_ event: CGEvent) {
        let f = event.flags
        let shift = f.contains(.maskShift)
        let option = f.contains(.maskAlternate)
        if f.contains(.maskCommand) || f.contains(.maskControl) {
            lastShiftPress = 0
            shiftWasDown = shift
            comboWasDown = false
            return
        }

        // Option + Shift -> исправить выделенный текст
        let combo = shift && option
        if combo && !comboWasDown {
            comboWasDown = true
            lastShiftPress = 0
            shiftWasDown = shift
            let generation = operationGeneration
            let target = InputTarget.capture()
            DispatchQueue.main.async {
                guard generation == self.operationGeneration, target?.isCurrent() == true else { return }
                self.convertSelection()
            }
            return
        }
        if !combo { comboWasDown = false }

        // Двойной Shift -> исправить последнее слово
        if shift && !shiftWasDown && !option {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShiftPress < 0.35 {
                lastShiftPress = 0
                let generation = operationGeneration
                let target = InputTarget.capture()
                DispatchQueue.main.async {
                    guard generation == self.operationGeneration, target?.isCurrent() == true else { return }
                    self.convertWord()
                }
            } else {
                lastShiftPress = now
            }
        }
        shiftWasDown = shift
    }

    // MARK: Автоопределение

    /// Решает, нужно ли исправлять слово перед знаком/пробелом/Enter/Tab (nil — пауза в поиске).
    private func planCorrection(trigger: Key?) -> Plan? {
        func skip(_ reason: String) -> Plan? {
            lastDecision = "пропущено: " + reason
            return nil
        }
        guard autoEnabled else { return skip("автоопределение выключено в меню") }
        if IsSecureEventInputEnabled() {
            reset()
            return skip("включён защищённый ввод (поле пароля)")
        }
        guard tables.ready else { return skip("не удалось прочитать раскладки EN/RU") }
        guard let last = buffer.last, !isTrigger(last) else { return skip("перед знаком нет слова") }
        if let id = focusedAppBundleID(), isAutoDisabled(for: id) {
            return skip("приложение в исключениях (\(id))")
        }
        guard let layout = currentLayoutLanguage(), layout == "en" || layout == "ru" else {
            return skip("текущая раскладка не RU/EN")
        }
        // Сразу после автоисправления вы печатаете уже в «правильной» раскладке («chat gpt»):
        // следующее слово возвращаем обратно, только если уверенность высокая.
        var cautious = false
        if let auto = lastAuto, lastAutoLang == layout,
           ProcessInfo.processInfo.systemUptime - auto.time < 10 { cautious = true }

        // Слово через дефис целиком: «gj-heccrb» -> «по-русски», «у-ьфшд» -> «e-mail».
        switch planCompound(layout: layout, cautious: cautious) {
        case .convert(let plan): return plan
        case .keep(let reason): return skip(reason)
        case .none: break
        }

        // Варианты слова: целиком и без 1–2 знаков-букв в начале/в конце
        // (кавычки, и клавиши `,` `.` `;` `'`, которые в RU дают буквы).
        var variants: [Range<Int>] = []
        for lead in 0...2 {
            for trail in 0...2 {
                guard buffer.count > lead + trail else { continue }
                let leadOK = buffer[0..<lead].allSatisfy { tables.punctLetterKeys.contains($0.code) }
                let trailOK = buffer[(buffer.count - trail)...].allSatisfy { tables.punctLetterKeys.contains($0.code) }
                guard leadOK && trailOK else { continue }
                let range = lead..<(buffer.count - trail)
                if !variants.contains(where: { buffer[$0] == buffer[range] }) { variants.append(range) }
            }
        }

        var reason = ""
        for range in variants {
            switch evaluate(Array(buffer[range]), layout: layout, cautious: cautious) {
            case .convert(let toRussian, let shown, let info):
                let prefix = chainedPrefix(toRussian: toRussian, skip: 0)
                var plan = Plan(keys: prefix + buffer, toRussian: toRussian, fromLang: layout, shownLower: shown.lowercased())
                // «GHbdtn» -> «Привет», а не «ПРивет»: регистр правим заодно.
                let recased = recase(range, toLang: toRussian ? "ru" : "en")
                if let fixed = recased {
                    plan.retype = prefix + fixed.keys
                    plan.capsOff = fixed.capsOff
                }
                lastDecision = "исправлено (" + info + (prefix.isEmpty ? "" : ", вместе с предыдущими короткими словами")
                    + (recased == nil ? "" : ", и регистр") + ")"
                return plan
            case .keep(let r):
                if reason.isEmpty { reason = r }
            }
        }
        // Слово из 1–2 букв («lf» -> «да», «jr» -> «ок»).
        if let plan = planShortWord(layout: layout, atEnd: isEndKey(trigger)) { return plan }
        // Раскладка верная, но регистр сбит: «ПРивет», «THe», «пРИВЕТ».
        if let plan = planCaseFix(layout: layout, ranges: variants) { return plan }
        return skip(reason.isEmpty ? "нет оснований" : reason)
    }

    /// Буфер с исправленным регистром слова на месте `range`, если в раскладке `toLang` оно выглядит как
    /// «ДВойные заглавные» или перевёрнутый регистр. nil — регистр в порядке или правка выключена.
    private func recase(_ range: Range<Int>, toLang: String) -> (keys: [Key], capsOff: Bool, slip: CaseSlip)? {
        guard caseFixEnabled, let found = caseSlip(Array(buffer[range]), lang: toLang) else { return nil }
        var keys = buffer
        keys.replaceSubrange(range, with: found.fixed)
        // Caps Lock выключаем, только если он всё ещё включён (последняя клавиша набрана с ним).
        return (keys, found.slip == .capsLockMidWord && buffer.last?.caps == true, found.slip)
    }

    /// Исправление только регистра, без смены раскладки. Нужна уверенность, что это обычное слово:
    /// оно есть в словаре («ПРивет» -> «привет»), а с ошибкой регистра — в личных исключениях нет.
    private func planCaseFix(layout: String, ranges: [Range<Int>]) -> Plan? {
        for range in ranges {
            guard let shown = shownString(Array(buffer[range]), lang: layout),
                  !isIgnoredWord(shown), isValidWord(shown.lowercased(), lang: layout),
                  let fixed = recase(range, toLang: layout) else { continue }
            let what = fixed.slip == .twoInitialCaps ? "ДВойные заглавные" : "Caps Lock посреди слова"
            lastDecision = "исправлен регистр (\(what), раскладка=\(layout))"
            return Plan(keys: buffer, toRussian: layout == "ru", fromLang: layout, shownLower: shown,
                        retype: fixed.keys, capsOff: fixed.capsOff)
        }
        return nil
    }

    private enum CompoundResult {
        case none
        case keep(String)
        case convert(Plan)
    }

    /// Слово из частей через дефис («по-русски», «из-за», «кое-что», «e-mail»).
    private func planCompound(layout: String, cautious: Bool) -> CompoundResult {
        var parts: [[Key]] = [buffer]
        var seps: [[Key]] = []
        for pw in prevWords.reversed() {
            guard pw.sep.count == 1, isHyphen(pw.sep[0]) else { break }
            parts.insert(pw.keys, at: 0)
            seps.insert(pw.sep, at: 0)
        }
        guard parts.count >= 2 else { return .none }
        guard parts.allSatisfy({ part in
            part.allSatisfy { tables.letterKeys.contains($0.code) || tables.punctLetterKeys.contains($0.code) }
        }) else { return .none }

        let targetLang = layout == "en" ? "ru" : "en"
        let srcParts = parts.compactMap { shownString($0, lang: layout) }
        let tgtParts = parts.compactMap { shownString($0, lang: targetLang) }
        guard srcParts.count == parts.count, tgtParts.count == parts.count else { return .none }
        let srcWhole = srcParts.joined(separator: "-")
        if isIgnoredWord(srcWhole) { return .keep("слово в личных исключениях") }

        func valid(_ ps: [String], _ lang: String) -> Bool {
            if ps.allSatisfy({ isWordIn($0, lang: lang) }) { return true }
            // Словарь принимает слово через дефис, если принимает части, а двухбуквенные
            // он принимает почти любые (bp, pf) — такие части должны быть частыми словами.
            let whole = ps.joined(separator: "-")
            let wholeOK = lang == "en" ? isValidEnglish(whole) : isValidWord(whole, lang: lang)
            return wholeOK && ps.allSatisfy { $0.count != 2 || isWordIn($0, lang: lang) }
        }
        if valid(srcParts, layout) { return .keep("слово через дефис есть в текущей раскладке") }

        var convert = valid(tgtParts, targetLang)
        var info = "слово через дефис, раскладка=\(layout)"
        if !convert {
            let src = srcParts.joined(), tgt = tgtParts.joined()
            let m = layoutMargin(shown: src, shownLang: layout, target: tgt, targetLang: targetLang)
            convert = m >= marginThreshold(length: src.count, cautious: cautious)
            info += String(format: ", модель %+.2f", m)
        }
        guard convert else { return .none }

        var keys: [Key] = []
        for i in 0..<parts.count {
            keys += parts[i]
            if i < seps.count { keys += seps[i] }
        }
        let toRussian = layout == "en"
        let prefix = chainedPrefix(toRussian: toRussian, skip: parts.count - 1)
        lastDecision = "исправлено (\(info))"
        return .convert(Plan(keys: prefix + keys, toRussian: toRussian, fromLang: layout,
                             shownLower: srcWhole.lowercased()))
    }

    /// Слово из 1–2 букв. Исправляем только в частые слова («lf» -> «да», «ytn» уже не сюда).
    /// Одну букву — только в конце ввода (Enter/Tab/пауза): «c», «r», «b» слишком часто набирают нарочно.
    private func planShortWord(layout: String, atEnd: Bool) -> Plan? {
        guard buffer.count <= 2, buffer.allSatisfy({ tables.letterKeys.contains($0.code) }) else { return nil }
        if buffer.count == 1 && !atEnd { return nil }
        let targetLang = layout == "en" ? "ru" : "en"
        guard let shown = shownString(buffer, lang: layout),
              let target = shownString(buffer, lang: targetLang),
              !isIgnoredWord(shown) else { return nil }
        let s = shown.lowercased(), t = target.lowercased()
        let toRussian = layout == "en"
        // Две заглавные — аббревиатура (ИП, ТЦ, OK, EU): исправляем, только если с другой стороны
        // известное сокращение, а с этой — нет (DJ, BP так и останутся).
        if buffer.count == 2 && buffer.allSatisfy({ $0.shift || $0.caps }) {
            func known(_ w: String, _ lang: String) -> Bool {
                commonShort[lang]?.contains(w) == true
                    || (lang == "ru" ? ruAbbreviations.contains(w) : techWords.contains(w))
            }
            // Русская цель — только аббревиатура: «ВО», «НА» капсом не пишут, а DJ, BP пишут.
            let targetOK = targetLang == "ru" ? ruAbbreviations.contains(t) : known(t, "en")
            guard !known(s, layout), targetOK else { return nil }
            let prefix = chainedPrefix(toRussian: toRussian, skip: 0)
            lastDecision = "исправлено (аббревиатура из 2 букв, раскладка=\(layout))"
            return Plan(keys: prefix + buffer, toRussian: toRussian, fromLang: layout, shownLower: s)
        }
        guard shortTargets[targetLang]?.contains(t) == true,
              commonShort[layout]?.contains(s) != true else { return nil }
        // Посреди фразы — только если и словарь не знает такого сочетания (Jr, KB…).
        if !atEnd && buffer.count == 2 {
            if layout == "en" ? isValidEnglish(shown) : isValidWord(shown, lang: layout) { return nil }
        }
        let prefix = chainedPrefix(toRussian: toRussian, skip: 0)
        lastDecision = "исправлено (короткое слово, раскладка=\(layout))"
        return Plan(keys: prefix + buffer, toRussian: toRussian, fromLang: layout, shownLower: s)
    }

    private func evaluate(_ core: [Key], layout: String, cautious: Bool) -> Verdict {
        guard core.count >= 3 else { return .keep("слово короче 3 символов") }
        guard core.allSatisfy({ tables.letterKeys.contains($0.code) || tables.punctLetterKeys.contains($0.code) })
        else { return .keep("в слове цифры или знаки") }
        // Последняя клавиша может быть и знаком (`.` в EN), и буквой (`ю` в RU): «pyf.» = «знаю».
        let endsWithPunct = tables.punctLetterKeys.contains(core.last!.code)

        guard let en = shownString(core, lang: "en"), let ru = shownString(core, lang: "ru")
        else { return .keep("не удалось сопоставить клавиши") }
        let shown = layout == "en" ? en : ru
        if isIgnoredWord(shown) { return .keep("слово в личных исключениях") }

        // CamelCase в английской раскладке — скорее имя переменной, не трогаем.
        // В русском таких слов не бывает: «ЬщтпщВИ» — это «MongoDB», набранное не в той раскладке.
        let shifts = core.filter { $0.shift }.count
        if layout == "en" && shifts >= 2 && shifts != core.count {
            // Кроме «ДВойных заглавных» не в той раскладке: «GHbdtn» = «ПРивет». Короткие («GHz» = «ПРя»)
            // и не из словаря не трогаем — там это скорее единицы измерения и имена.
            if caseFixEnabled, core.count >= 5, caseSlip(core, lang: "en")?.slip == .twoInitialCaps,
               !isValidEnglish(en.lowercased()), isValidWord(ru.lowercased(), lang: "ru") {
                return .convert(true, shown, "ДВойные заглавные, раскладка=en; RU: слово=true")
            }
            return .keep("несколько заглавных (CamelCase)")
        }

        // Имя файла или домен в RU-раскладке: точка стала «ю» («РФТВЩААюЬВ» = HANDOFF.MD).
        if layout == "ru" && isDottedName(en) && !isValidWord(ru, lang: "ru") {
            return .convert(false, shown, "имя файла/домен, раскладка=ru")
        }

        // Слово целиком ЗАГЛАВНЫМИ — чаще всего аббревиатура: словарь их принимает любые («МЗЫ», «VDL»),
        // а статистика по ним бессмысленна. Исправляем, только если с другой стороны заведомо известное.
        if shown == shown.uppercased() && shown != shown.lowercased() {
            let enCore = endsWithPunct ? String(en.dropLast()) : en
            let srcKnown = layout == "en" ? isKnownUpper(enCore, lang: "en") : isKnownUpper(ru, lang: "ru")
            let tgtKnown = layout == "en" ? isKnownUpper(ru, lang: "ru") : isKnownUpper(enCore, lang: "en")
            let info = "заглавными, раскладка=\(layout); известно: тут=\(srcKnown), там=\(tgtKnown)"
            if !srcKnown && tgtKnown { return .convert(layout == "en", shown, info) }
            return .keep(info)
        }

        // Растянутое слово («нууу», «дааа», «ыыы», «sooo»): решаем по слову без повторов.
        // После проверки капса: «ООО», «WWW» — аббревиатуры, а не растянутые слова.
        if let collapsed = collapseRuns(core) {
            return evaluateStretched(core, collapsed, shown: shown, layout: layout, cautious: cautious)
        }

        // Если слово кончается такой клавишей, английскую часть оцениваем без последнего знака.
        let enForCheck = endsWithPunct ? String(en.dropLast()) : en
        let enValid = isValidEnglish(enForCheck)
        // Строчные аббревиатуры и междометия («ндфл», «мчс», «гыы») в RU-раскладке не трогаем.
        let ruKnownExtra = layout == "ru"
            && (ruAbbreviations.contains(ru.lowercased()) || ruInterjections.contains(ru.lowercased()))
        let ruValid = ruKnownExtra || isValidWord(ru, lang: "ru")
        let info = "раскладка=\(layout); EN: слово=\(enValid); RU: слово=\(ruValid)"

        if layout == "en" && isKnownEnglishAbbreviation(enForCheck) { return .keep("известное английское сокращение") }
        // Редкое русское слово = известное сокращение («шву» = ide): побеждает сокращение.
        if layout == "ru" && ruValid && rareRuCollisions.contains(ru.lowercased()) && isKnownEnglishAbbreviation(enForCheck) {
            return .convert(false, shown, info + "; редкое слово = сокращение")
        }

        // Остальное решает сумма взвешенных доводов: словари и статистика буквосочетаний.
        let m = layout == "en"
            ? layoutMargin(shown: enForCheck, shownLang: "en", target: ru, targetLang: "ru")
            : layoutMargin(shown: ru, shownLang: "ru", target: enForCheck, targetLang: "en")
        let score = switchScore(margin: m, sourceWord: layout == "en" ? enValid : ruValid,
                                targetWord: layout == "en" ? ruValid : enValid,
                                targetListed: layout == "ru" && isKnownEnglishAbbreviation(enForCheck),
                                innerPunctuation: !enForCheck.allSatisfy { $0.isLetter },
                                length: core.count, cautious: cautious)
        let full = info + "; " + score.explanation
        return score.convert ? .convert(layout == "en", shown, full) : .keep(full)
    }

    /// Слово, где одна клавиша повторена 3+ раза подряд, без повторов; nil — повторов нет.
    private func collapseRuns(_ core: [Key]) -> [Key]? {
        var out: [Key] = [], collapsed = false, i = 0
        while i < core.count {
            var j = i
            while j < core.count && core[j].code == core[i].code { j += 1 }
            if j - i >= 3 {
                out.append(core[i])
                collapsed = true
            } else {
                out += core[i..<j]
            }
            i = j
        }
        return collapsed ? out : nil
    }

    /// Растянутое слово: короткий остаток решаем по спискам коротких слов, длинный — как обычно.
    private func evaluateStretched(_ core: [Key], _ collapsed: [Key], shown: String, layout: String,
                                   cautious: Bool) -> Verdict {
        if collapsed.count >= 3 {
            switch evaluate(collapsed, layout: layout, cautious: cautious) {
            case .convert(let toRussian, _, let info): return .convert(toRussian, shown, "растянутое, " + info)
            case .keep(let r): return .keep("растянутое, " + r)
            }
        }
        let targetLang = layout == "en" ? "ru" : "en"
        guard collapsed.allSatisfy({ tables.letterKeys.contains($0.code) }),
              let s = shownString(collapsed, lang: layout)?.lowercased(),
              let t = shownString(collapsed, lang: targetLang)?.lowercased()
        else { return .keep("растянутое, не буквы") }
        let info = "растянутое «\(s)», раскладка=\(layout)"
        if commonShort[layout]?.contains(s) == true { return .keep(info) }
        // Тянут гласные («нууу», «дааа»), а не «usss»; одна буква («zzz», «ыыы») — не слово.
        let vowels = targetLang == "ru" ? "аеёиоуыэюя" : "aeiouy"
        let repeated = core.indices.filter { i in
            i >= 2 && core[i].code == core[i - 1].code && core[i].code == core[i - 2].code
        }.map { core[$0] }
        guard collapsed.count == 2, shortTargets[targetLang]?.contains(t) == true,
              let stretched = shownString(repeated, lang: targetLang)?.lowercased(),
              stretched.allSatisfy({ vowels.contains($0) })
        else { return .keep(info) }
        return .convert(layout == "en", shown, info)
    }

    /// «HANDOFF.MD», «google.com»: части через точку, последняя — известное расширение/домен,
    /// остальные — английские слова (по словарю или хотя бы по статистике букв).
    private func isDottedName(_ en: String) -> Bool {
        let parts = en.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, let ext = parts.last, fileExtensions.contains(ext.lowercased()),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLetter } })
        else { return false }
        return parts.dropLast().allSatisfy { p in
            if isWordIn(p, lang: "en") { return true }
            let ruPart = String(p.compactMap { tables.toRu[$0] })
            return p.count >= 3 && layoutMargin(shown: ruPart, shownLang: "ru", target: p, targetLang: "en") >= 0
        }
    }

    /// Слово капсом заведомо есть в языке: из списка сокращений или обычное слово с гласной
    /// (3-буквенные сочетания согласных словарь принимает почти любые: vdl, vxc).
    private func isKnownUpper(_ word: String, lang: String) -> Bool {
        let l = word.lowercased()
        if lang == "en" {
            if techWords.contains(l) || looseContractions.contains(l) { return true }
            return l.contains(where: { "aeiouy".contains($0) }) && isValidWord(l, lang: "en")
        }
        if ruAbbreviations.contains(l) { return true }
        if rareRuCollisions.contains(l) { return false }
        return l.contains(where: { "аеёиоуыэюя".contains($0) }) && isValidWord(l, lang: "ru")
    }

    /// Короткие слова (1–2 буквы) прямо перед исправляемым, которые тоже набраны не в той раскладке:
    /// «z yt pyf.» -> «я не знаю», «lf? rjytxyj» -> «да, конечно». Раз следующее слово набрано
    /// не в той раскладке, а раскладку между ними не меняли, — и они тоже.
    /// `skip` — сколько последних слов уже входят в исправляемое (части слова через дефис).
    private func chainedPrefix(toRussian: Bool, skip: Int) -> [Key] {
        let targetLang = toRussian ? "ru" : "en"
        var prefix: [Key] = []
        for pw in prevWords.dropLast(skip).reversed() {
            guard pw.keys.count <= 2,
                  pw.keys.allSatisfy({ tables.letterKeys.contains($0.code) }),
                  let target = shownString(pw.keys, lang: targetLang),
                  shortTargets[targetLang]?.contains(target.lowercased()) == true
            else { break }
            prefix = pw.keys + pw.sep + prefix
        }
        return prefix
    }

    // MARK: Исправление

    /// Стирает `keys` (как они выглядят в `fromLang`), переключает раскладку и печатает их заново
    /// (или `typed` вместо них — например, с исправленным регистром).
    /// false — текст перед курсором не совпал с буфером, ничего не сделано.
    private func replaceWord(_ keys: [Key], typed: [Key]? = nil, fromLang: String, toRussian: Bool,
                             then done: @escaping () -> Void) -> Bool {
        guard let targetField = InputTarget.capture() else { return false }
        let generation = operationGeneration
        let toLang = toRussian ? "ru" : "en"
        let expected = shownString(keys, lang: fromLang)
        var ctx: CaretContext?
        if let expected = expected {
            switch checkBeforeCaret(expected) {
            case .mismatch:
                if verifyEnabled { return false }
            case .match(let c):
                ctx = c
            case .unknown:
                break
            }
        }

        // Если за словом висит автодополнение (Spotlight), первый Backspace сотрёт его, а не букву.
        let extra = ctx?.completion == true ? 1 : 0
        deletedText = expected
        tapBackspaces(keys.count + extra)
        // Только регистр — раскладку не трогаем (иначе «Русская – ПК» могла бы смениться на другую русскую).
        if toLang != fromLang { switchLayout(toRussian: toRussian) }

        // Чего ждём после стирания: текст до курсора без нашего слова.
        var target: String?
        if let ctx = ctx, let expected = expected {
            let ns = ctx.before as NSString
            target = ns.substring(to: ns.length - expected.utf16.count)
        }
        lastReplaceNote = ctx == nil
            ? "поле не отдаёт текст (Accessibility)"
            : "поле читается, автодополнение=\(extra > 0)"

        waitForStableCaret(enabled: target != nil) { now in
            guard self.operationIsCurrent(generation, target: targetField) else { return }
            // Поле могло подставить автодополнение уже после проверки и «съесть» Backspace —
            // тогда в начале остались буквы старого слова: дотираем их.
            var fix = 0
            if let target = target, let now = now, now.before.utf16.starts(with: target.utf16) {
                let left = now.before.utf16.count - target.utf16.count
                if (1...2).contains(left) { fix = left + (now.completion ? 1 : 0) }
            }
            if fix > 0 {
                tapBackspaces(fix)
                self.lastReplaceNote += ", дотёрто лишних символов: \(fix)"
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + (fix > 0 ? 0.03 : 0)) {
                guard self.operationIsCurrent(generation, target: targetField) else { return }
                typeKeys(typed ?? keys, lang: toLang)
                self.deletedText = nil
                done()
            }
        }
        return true
    }

    /// Ждёт, пока приложение обработает наши Backspace (текст поля перестанет меняться).
    private func waitForStableCaret(enabled: Bool, attempt: Int = 0, previous: CaretContext? = nil,
                                    _ body: @escaping (CaretContext?) -> Void) {
        guard enabled else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { body(nil) }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.04 : 0.03)) {
            let now = caretContext()
            if now == nil || (attempt > 0 && now == previous) || attempt >= 6 {
                body(now)
            } else {
                self.waitForStableCaret(enabled: true, attempt: attempt + 1, previous: now, body)
            }
        }
    }

    /// Клавиша-триггер в раскладке `lang` (Enter — как есть).
    private func tapTrigger(_ trigger: Key, flags: CGEventFlags, lang: String) {
        if trigger.code == kReturn || trigger.code == kKeypadEnter || trigger.code == kTab {
            tapKey(trigger.code, flags: flags)
        } else {
            tapKey(trigger.code, flags: flags, text: shownChar(trigger, lang: lang).map { String($0) })
        }
    }

    /// Автоисправление: клавиша-триггер была придержана, поэтому стираем ровно plan.keys.
    /// trigger == nil — исправление по паузе в поиске.
    private func perform(_ plan: Plan, trigger: Key?, triggerFlags: CGEventFlags) {
        let toLang = plan.toRussian ? "ru" : "en"
        let ends = trigger.map { $0.code == kReturn || $0.code == kKeypadEnter || $0.code == kTab } ?? false
        let isEnter = trigger.map { $0.code == kReturn || $0.code == kKeypadEnter } ?? false
        let original = buffer
        heldBoundary = trigger.flatMap { key in
            if key.code == kReturn || key.code == kKeypadEnter { return "\n" }
            if key.code == kTab { return "\t" }
            return shownChar(key, lang: plan.fromLang).map(String.init)
        }
        let generation = operationGeneration
        let targetField = InputTarget.capture()
        let started = replaceWord(plan.keys, typed: plan.retype, fromLang: plan.fromLang, toRussian: plan.toRussian) {
            // Перед Enter — пауза: поиску (Spotlight, лаунчеры) нужно обновить результаты,
            // иначе откроется то, что нашлось по неправильному слову.
            DispatchQueue.main.asyncAfter(deadline: .now() + (isEnter ? 0.15 : 0)) {
                guard let targetField = targetField, self.operationIsCurrent(generation, target: targetField) else { return }
                if let trigger = trigger { self.tapTrigger(trigger, flags: triggerFlags, lang: toLang) }
                self.heldBoundary = nil

                let tail = trigger.map { [$0] } ?? []
                self.prevWords = []
                self.buffer = ends ? [] : plan.typed + tail
                let now = ProcessInfo.processInfo.systemUptime
                if plan.caseOnly {
                    // Раскладку не меняли: двойной Shift вернёт прежний регистр, а не сменит раскладку.
                    self.lastCaseFix = (self.buffer, original + tail, toLang, plan.shownLower, now)
                    self.lastAuto = nil
                } else {
                    self.lastAuto = (self.buffer, plan.shownLower, now)
                    self.lastAutoLang = toLang
                    self.lastCaseFix = nil
                }
                self.finish()
            }
        }
        if started && plan.capsOff {
            turnOffCapsLock()
            // То, что успели набрать во время исправления, повторим уже без Caps Lock.
            pending = pending.map { Key(code: $0.code, flags: $0.cgFlags.subtracting(.maskAlphaShift)) }
        }
        if !started {
            // Страховка от рассинхронизации: текст перед курсором не совпал с нашим буфером.
            lastDecision = "пропущено: текст перед курсором не совпал с буфером"
            heldBoundary = nil
            reset()
            if let trigger = trigger { tapKey(trigger.code, flags: triggerFlags) }
            finish()
        }
    }

    /// Двойной Shift: стираем слово (вместе с пробелом/знаком после него), меняем раскладку, печатаем заново.
    private func convertWord() {
        guard !busy, !buffer.isEmpty else { return }
        let keys = buffer
        let lang = currentLayoutLanguage() ?? "en"

        // Сразу после исправления регистра двойной Shift возвращает как было; запоминание доступно отдельно в меню.
        if let fix = lastCaseFix, fix.buffer == keys, fix.lang == lang,
           ProcessInfo.processInfo.systemUptime - fix.time < 20 {
            busy = true
            lastCaseFix = nil
            let started = replaceWord(keys, typed: fix.original, fromLang: lang, toRussian: lang == "ru") {
                self.buffer = fix.original
                self.lastUndoCandidate = fix.shown
                self.lastDecision = "регистр возвращён; запоминание — отдельно в меню"
                self.finish()
            }
            if started {
                lastDecision = "возвращаем прежний регистр"
            } else {
                reset()
                finish()
            }
            return
        }

        let undone = lastAuto.flatMap { last in
            last.buffer == keys && ProcessInfo.processInfo.systemUptime - last.time < 20 ? last.shown : nil
        }
        busy = true
        let started = replaceWord(keys, fromLang: lang, toRussian: lang != "ru") {
            if let word = undone {
                self.lastUndoCandidate = word
                self.lastAuto = nil
                self.lastDecision = "исправление отменено; запоминание — отдельно в меню"
            }
            self.finish()
        }
        guard started else {
            lastDecision = "ручное исправление пропущено: текст перед курсором не совпал с буфером"
            reset()
            finish()
            return
        }


    }

    /// Option + Shift: Cmd+C -> конвертируем -> Cmd+V -> возвращаем прежний буфер обмена целиком.
    private func convertSelection() {
        guard !busy, let targetField = InputTarget.capture() else { return }
        busy = true
        let generation = operationGeneration
        let pb = NSPasteboard.general
        let saved = snapshotPasteboard(pb)
        let changeCount = pb.changeCount

        tapKey(kC, flags: .maskCommand)

        // Ждём копирования до 0,5 с: Electron-приложения отвечают не сразу.
        func waitForCopy(_ attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard self.operationIsCurrent(generation, target: targetField) else { return }
                guard pb.changeCount != changeCount, let text = pb.string(forType: .string) else {
                    if attempt < 10 { waitForCopy(attempt + 1) } else { self.finish() }  // ничего не выделено
                    return
                }
                let (converted, intoRussian) = convertText(text)
                pb.clearContents()
                pb.setString(converted, forType: .string)
                let ours = pb.changeCount
                switchLayout(toRussian: intoRussian)
                tapKey(kV, flags: .maskCommand)
                self.finish()

                // Вставка в некоторых приложениях асинхронная — возвращаем буфер обмена с запасом
                // и только если за это время в него не скопировали что-то новое.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if pb.changeCount == ours { restorePasteboard(pb, saved) }
                }
            }
        }
        waitForCopy(0)
    }

    /// Исправление закончено: повторяем нажатия, которые пользователь успел сделать за это время.
    private func finish() {
        busy = false
        let queued = pending
        pending.removeAll()
        let lang = currentLayoutLanguage() ?? "en"
        for k in queued {
            if k.code == kReturn || k.code == kKeypadEnter || k.code == kBackspace
                || !tables.wordKeys.contains(k.code) {
                tapKey(k.code, flags: k.cgFlags)
            } else {
                tapKey(k.code, flags: k.cgFlags, text: shownChar(k, lang: lang).map { String($0) })
            }
            if isTrigger(k) {
                registerBoundary(k)
            } else if tables.wordKeys.contains(k.code) {
                registerTyped(k)
            } else if k.code == kBackspace {
                if !buffer.isEmpty { buffer.removeLast() }
            } else {
                reset()
            }
        }
    }
}

let switcher = Switcher()
var eventTap: CFMachPort?

// MARK: - Меню в строке состояния

final class AppController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let autoItem: NSMenuItem
    let appItem: NSMenuItem
    let excludedItem: NSMenuItem
    let excludedMenu = NSMenu()
    let verifyItem: NSMenuItem
    let caseItem: NSMenuItem
    let rememberItem: NSMenuItem
    let recoveryItem: NSMenuItem
    let ignoredItem: NSMenuItem
    let unignoreItem: NSMenuItem
    let loginItem: NSMenuItem
    let setupItem: NSMenuItem
    let diagItem: NSMenuItem
    var lastApp: NSRunningApplication?

    override init() {
        autoItem = NSMenuItem(title: "Автоопределение раскладки",
                              action: #selector(AppController.toggleAuto), keyEquivalent: "")
        appItem = NSMenuItem(title: "", action: #selector(AppController.toggleApp), keyEquivalent: "")
        excludedItem = NSMenuItem(title: "Исключённые приложения", action: nil, keyEquivalent: "")
        verifyItem = NSMenuItem(title: "Проверять текст перед курсором",
                                action: #selector(AppController.toggleVerify), keyEquivalent: "")
        caseItem = NSMenuItem(title: "Исправлять ДВойные заглавные и cAPS lOCK",
                              action: #selector(AppController.toggleCaseFix), keyEquivalent: "")
        rememberItem = NSMenuItem(title: "", action: #selector(AppController.rememberUndo), keyEquivalent: "")
        recoveryItem = NSMenuItem(title: "", action: #selector(AppController.showRecovery), keyEquivalent: "")
        ignoredItem = NSMenuItem(title: "", action: #selector(AppController.showWordExceptions), keyEquivalent: "")
        unignoreItem = NSMenuItem(title: "", action: #selector(AppController.unignoreLast), keyEquivalent: "")
        loginItem = NSMenuItem(title: "Запускать при входе",
                               action: #selector(AppController.toggleLogin), keyEquivalent: "")
        setupItem = NSMenuItem(title: "Настройка и разрешения…",
                               action: #selector(AppController.showSetup), keyEquivalent: "")
        diagItem = NSMenuItem(title: "Диагностика…",
                              action: #selector(AppController.showDiagnostics), keyEquivalent: "")
        super.init()

        if let img = AppController.statusIcon(ok: true) {
            statusItem.button?.image = img
        } else {
            statusItem.button?.title = "⇄"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        for item in [autoItem, appItem, verifyItem, caseItem, rememberItem, recoveryItem, unignoreItem, ignoredItem, loginItem, setupItem, diagItem] { item.target = self }
        excludedItem.submenu = excludedMenu

        menu.addItem(autoItem)
        menu.addItem(appItem)
        menu.addItem(excludedItem)
        menu.addItem(.separator())
        menu.addItem(verifyItem)
        menu.addItem(caseItem)
        menu.addItem(rememberItem)
        menu.addItem(recoveryItem)
        menu.addItem(unignoreItem)
        menu.addItem(ignoredItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(setupItem)
        menu.addItem(diagItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выход", action: #selector(AppController.quit), keyEquivalent: "q")
        statusItem.menu = menu
        menu.items.last?.target = self
        switcher.recoveryChanged = { [weak self] in
            self?.statusItem.button?.title = "!"
            self?.statusItem.button?.toolTip = "Есть набранный текст для восстановления — откройте меню Раскладушки"
        }

        // Запоминаем последнее активное приложение (не наше), чтобы добавлять его в исключения.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(AppController.appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastApp = front
            prepareAccessibility(for: front)
        }

        // Если меняются включённые раскладки — перечитываем таблицы клавиш.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil, queue: .main) { _ in tables.rebuild() }
    }

    /// Значок в строке меню: стрелки туда-обратно, при проблемах — треугольник с «!».
    static func statusIcon(ok: Bool) -> NSImage? {
        let name = ok ? "arrow.left.arrow.right" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Раскладушка")
        image?.isTemplate = true
        return image
    }

    @objc func appActivated(_ note: Notification) {
        switcher.reset(reason: "уведомление о смене активного приложения")  // сменилось приложение — буфер набранного слова больше не актуален
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        lastApp = app
        prepareAccessibility(for: app)
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu !== statusItem.menu { return }
        tables.rebuild()

        autoItem.state = autoEnabled ? .on : .off
        autoItem.title = autoAvailable
            ? "Автоопределение раскладки"
            : "Автоопределение (нет словарей — только правила)"

        if let app = lastApp, let id = app.bundleIdentifier {
            let name = app.localizedName ?? id
            if isBuiltinExcluded(id) {
                appItem.title = "\(name): исключено всегда (виртуальная машина / удалённый доступ)"
                appItem.state = .on
                appItem.isEnabled = false
            } else {
                appItem.title = "Не исправлять автоматически в: \(name)"
                appItem.state = userExcludedApps.contains(id) ? .on : .off
                appItem.isEnabled = true
            }
        } else {
            appItem.title = "Не исправлять автоматически в этом приложении"
            appItem.state = .off
            appItem.isEnabled = false
        }

        // Подменю со списком исключений
        excludedMenu.removeAllItems()
        let info = NSMenuItem(title: "Всегда исключены: виртуальные машины и удалённый рабочий стол",
                              action: nil, keyEquivalent: "")
        info.isEnabled = false
        excludedMenu.addItem(info)
        excludedMenu.addItem(.separator())
        let list = userExcludedApps.sorted()
        if list.isEmpty {
            let empty = NSMenuItem(title: "Ваших исключений пока нет", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            excludedMenu.addItem(empty)
        } else {
            let hint = NSMenuItem(title: "Нажмите на приложение, чтобы убрать его из списка",
                                  action: nil, keyEquivalent: "")
            hint.isEnabled = false
            excludedMenu.addItem(hint)
            for id in list {
                let item = NSMenuItem(title: appName(id),
                                      action: #selector(AppController.removeExcluded(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = id
                excludedMenu.addItem(item)
            }
        }

        verifyItem.state = verifyEnabled ? .on : .off
        caseItem.state = caseFixEnabled ? .on : .off
        if let word = switcher.lastUndoCandidate, !isIgnoredWord(word) {
            rememberItem.title = "Больше не исправлять «\(word)»"
            rememberItem.isHidden = false
        } else { rememberItem.isHidden = true }
        recoveryItem.title = "Восстановить набранный текст (\(switcher.recoveredInputs.count))…"
        recoveryItem.isHidden = switcher.recoveredInputs.isEmpty
        ignoredItem.title = "Исключения слов… (\(ignoredWords.count))"
        ignoredItem.isEnabled = true
        // Отмена двойным Shift могла быть случайной — последнее исключение можно снять.
        if let w = lastIgnoredWord {
            unignoreItem.title = "Снова исправлять «\(w)»"
            unignoreItem.isHidden = false
        } else {
            unignoreItem.isHidden = true
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc func toggleAuto() {
        autoEnabled.toggle()
    }

    @objc func toggleVerify() {
        verifyEnabled.toggle()
    }

    @objc func toggleCaseFix() {
        caseFixEnabled.toggle()
    }

    @objc func rememberUndo() {
        guard let word = switcher.lastUndoCandidate else { return }
        addIgnoredWord(word)
        switcher.lastUndoCandidate = nil
    }

    @objc func showRecovery() {
        guard !switcher.recoveredInputs.isEmpty else { return }
        let text = switcher.recoveredInputs.joined(separator: "\n")
        let count = switcher.recoveredInputs.count
        let alert = NSAlert()
        alert.messageText = "Набранный текст сохранён"
        alert.informativeText = "Замена была отменена. Этот текст не отправлялся в другое поле. Скопируйте и вставьте его в нужное место. До закрытия приложения он хранится только в памяти."
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 130))
        view.isEditable = false
        view.string = text
        let scroll = NSScrollView(frame: view.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Скопировать")
        alert.addButton(withTitle: "Оставить на потом")
        alert.addButton(withTitle: "Удалить")
        NSApp.activate(ignoringOtherApps: true)
        let result = alert.runModal()
        if result == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        if result == .alertFirstButtonReturn || result == .alertThirdButtonReturn {
            switcher.recoveredInputs.removeFirst(min(count, switcher.recoveredInputs.count))
            updateStatusTitle()
        }
    }

    @objc func quit() {
        if !switcher.recoveredInputs.isEmpty {
            showRecovery()
            if !switcher.recoveredInputs.isEmpty { return }
        }
        NSApp.terminate(nil)
    }

    @objc func unignoreLast() {
        if let w = lastIgnoredWord { removeIgnoredWord(w) }
    }

    let wordExceptions = WordExceptionsController()

    @objc func showWordExceptions() {
        wordExceptions.show()
    }

    @objc func toggleApp() {
        guard let id = lastApp?.bundleIdentifier, !isBuiltinExcluded(id) else { return }
        var set = userExcludedApps
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        userExcludedApps = set
    }

    @objc func removeExcluded(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        var set = userExcludedApps
        set.remove(id)
        userExcludedApps = set
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Raskladushka: не удалось изменить автозапуск: \(error)")
        }
    }

    @objc func showSetup() {
        onboarding.show()
    }

    @objc func showDiagnostics() {
        tables.rebuild()
        var excluded = false
        if let id = lastApp?.bundleIdentifier { excluded = isAutoDisabled(for: id) }
        let trusted = AXIsProcessTrusted()
        let tapOn = eventTap != nil
        let layout = currentLayoutLanguage() ?? "?"
        let appID = lastApp?.bundleIdentifier ?? "?"
        let ruHello = isValidWord("привет", lang: "ru")
        let ruBad = isValidWord("вщте", lang: "ru")
        let enHello = isValidWord("hello", lang: "en")
        let enBad = isValidWord("ghbdtn", lang: "en")
        let ide = isValidEnglish("ide")

        var lines: [String] = []
        lines.append("Универсальный доступ: " + (trusted ? "выдан" : "НЕ выдан"))
        lines.append("Перехват клавиатуры: " + (tapOn ? "работает" : "НЕ запущен"))
        lines.append("Таблицы раскладок EN/RU: \(tables.note)")
        lines.append("Найденные словари: \(spellLanguages)")
        lines.append("Автоопределение: включено=\(autoEnabled), словари=\(autoAvailable)")
        lines.append("Проверка текста перед курсором: \(verifyEnabled)")
        lines.append("Исправление регистра: \(caseFixEnabled)")
        lines.append("Текущая раскладка: \(layout)")
        lines.append("Последнее приложение: \(appID), автоисправление выключено=\(excluded)")
        lines.append("Тест словарей: привет(RU)=\(ruHello), вщте(RU)=\(ruBad)")
        lines.append("hello(EN)=\(enHello), ghbdtn(EN)=\(enBad), ide(EN)=\(ide)")
        lines.append("Личных исключений слов: \(ignoredWords.count), своих исключённых приложений: \(userExcludedApps.count)")
        lines.append("Последнее решение: \(switcher.lastDecision)")
        lines.append("Последняя замена: \(switcher.lastReplaceNote)")
        lines.append("Подготовка Accessibility: \(accessibilityPreparationNote)")
        lines.append("Защищённый ввод (Secure Input): "
            + (secureInputOwner().map { "ВКЛЮЧЁН (\($0)) — пока он включён, Раскладушка не видит клавиш" } ?? "выключен"))

        let alert = NSAlert()
        alert.messageText = "Диагностика Раскладушки"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Скопировать")  // чтобы приложить к письму в поддержку
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(alert.informativeText, forType: .string)
        }
    }
}

// MARK: - Исключения слов

final class WordExceptionsController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private let search = NSSearchField()
    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let deleteButton = NSButton(title: "Удалить выбранные", target: nil, action: nil)
    private var rows: [WordExceptionRow] = []

    func show() {
        if window == nil { build() }
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }
    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 430),
                         styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Исключения слов"
        w.isReleasedWhenClosed = false
        w.center()
        guard let content = w.contentView else { return }
        search.frame = NSRect(x: 20, y: 378, width: 500, height: 28)
        search.placeholderString = "Найти слово…"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        content.addSubview(search)
        let hint = NSTextField(wrappingLabelWithString: "Новые исключения показаны словами. Для старых названия не сохранены: введите слово целиком, чтобы найти его.")
        hint.frame = NSRect(x: 20, y: 325, width: 500, height: 42)
        hint.textColor = .secondaryLabelColor
        content.addSubview(hint)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 75, width: 500, height: 240))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.title = "Слово или старое исключение"
        column.width = 475
        table.addTableColumn(column)
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        scroll.documentView = table
        content.addSubview(scroll)
        countLabel.frame = NSRect(x: 20, y: 24, width: 260, height: 25)
        content.addSubview(countLabel)
        deleteButton.frame = NSRect(x: 300, y: 20, width: 220, height: 32)
        deleteButton.target = self
        deleteButton.action = #selector(deleteSelected)
        content.addSubview(deleteButton)
        window = w
    }
    private func reload() {
        rows = wordExceptionRows(query: search.stringValue, hashes: ignoredWords, labels: ignoredWordLabels)
        table.deselectAll(nil)
        table.reloadData()
        countLabel.stringValue = "Найдено: \(rows.count) · Всего: \(ignoredWords.count)"
        deleteButton.isEnabled = false
    }
    func controlTextDidChange(_ notification: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        NSTextField(labelWithString: rows[row].title)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        deleteButton.isEnabled = !table.selectedRowIndexes.isEmpty
    }
    @objc private func deleteSelected() {
        let hashes = table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].hash : nil }
        for hash in hashes { removeIgnoredHash(hash) }
        reload()
    }
}

// MARK: - Окно первого запуска

/// Проводит через разрешения: показывает, что уже готово, и открывает нужные разделы настроек.
/// Появляется при первом запуске и каждый раз, когда нет Универсального доступа; из меню — «Настройка…».
final class OnboardingController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private var rows: [(icon: NSImageView, check: () -> Bool)] = []
    private let loginBox = NSButton(checkboxWithTitle: "Запускать Раскладушку при входе в систему",
                                    target: nil, action: nil)

    static let doneKey = "onboardingDone"

    func show() {
        if window == nil { build() }
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func build() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 10),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Раскладушка"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let title = NSTextField(labelWithString: "Добро пожаловать в Раскладушку")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let intro = wrapping("Раскладушка исправляет слова, набранные не в той раскладке: «ghbdtn» → «привет», "
            + "«руддщ» → «hello». Осталось выдать разрешение. Раскладушка ничего не отправляет в интернет.")

        let accessRow = row(
            title: "Универсальный доступ",
            detail: "Нужен, чтобы видеть нажатия и заменять слово. Нажмите кнопку, включите Раскладушку в списке. "
                + "Если он уже включён, но галочка здесь не появляется, — удалите его кнопкой «−» и добавьте снова.",
            button: ("Открыть настройки", #selector(openAccessibility)),
            check: { AXIsProcessTrusted() })
        let layoutRow = row(
            title: "Раскладки английская и русская",
            detail: "Должны быть включены обе: Системные настройки → Клавиатура → Источники ввода.",
            button: ("Настройки клавиатуры", #selector(openKeyboard)),
            check: { tables.ready })
        let tapRow = row(
            title: "Раскладушка работает",
            detail: "Включится сам через несколько секунд после выдачи доступа.",
            button: nil,
            check: { eventTap != nil })

        loginBox.target = self
        loginBox.action = #selector(toggleLogin)

        let tryLabel = NSTextField(labelWithString: "Попробуйте: наберите здесь «ghbdtn» и пробел")
        tryLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let tryField = NSTextField(string: "")
        tryField.placeholderString = "ghbdtn"

        let done = NSButton(title: "Готово", target: self, action: #selector(finish))
        done.keyEquivalent = "\r"
        let bottom = NSStackView(views: [NSView(), done])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [title, intro, accessRow, layoutRow, tapRow, loginBox, tryLabel, tryField, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(6, after: tryLabel)
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [intro, accessRow, layoutRow, tapRow, tryField, bottom] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 520),
        ])
        w.contentView = content
        window = w
    }

    private func wrapping(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = 440
        return f
    }

    /// Строка шага: значок состояния, заголовок, пояснение и кнопка.
    private func row(title: String, detail: String, button: (String, Selector)?, check: @escaping () -> Bool) -> NSView {
        let icon = NSImageView()
        icon.symbolConfiguration = .init(pointSize: 18, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        let d = wrapping(detail)
        d.font = .systemFont(ofSize: 12)
        d.preferredMaxLayoutWidth = button == nil ? 420 : 280
        let texts = NSStackView(views: [t, d])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 3
        var views: [NSView] = [icon, texts]
        if let (label, sel) = button {
            let b = NSButton(title: label, target: self, action: sel)
            b.setContentHuggingPriority(.required, for: .horizontal)
            views.append(b)
        }
        let h = NSStackView(views: views)
        h.orientation = .horizontal
        h.alignment = .top
        h.spacing = 10
        rows.append((icon, check))
        return h
    }

    private func refresh() {
        tables.rebuild()
        _ = installTap()
        updateStatusTitle()
        for r in rows {
            let ok = r.check()
            r.icon.image = NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "circle",
                                   accessibilityDescription: ok ? "готово" : "не готово")
            r.icon.contentTintColor = ok ? .systemGreen : .tertiaryLabelColor
        }
        loginBox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func openAccessibility() {
        // Системный запрос добавляет Раскладушку в список Универсального доступа.
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openKeyboard() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        controller.toggleLogin()
        refresh()
    }

    @objc private func finish() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        if AXIsProcessTrusted() { UserDefaults.standard.set(true, forKey: OnboardingController.doneKey) }
    }
}

let onboarding = OnboardingController()

// MARK: - Запуск

let tapMask: CGEventMask =
    (1 << CGEventType.keyDown.rawValue)
    | (1 << CGEventType.keyUp.rawValue)
    | (1 << CGEventType.flagsChanged.rawValue)
    | (1 << CGEventType.leftMouseDown.rawValue)
    | (1 << CGEventType.rightMouseDown.rawValue)
    | (1 << CGEventType.otherMouseDown.rawValue)

/// Создаёт перехват клавиатуры. Возвращает false, пока не выданы разрешения.
func installTap() -> Bool {
    if eventTap != nil { return true }
    guard AXIsProcessTrusted() else { return false }
    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: tapMask,
        callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                // Пока перехват был выключен, часть нажатий прошла мимо — буфер больше не верен.
                switcher.reset(reason: type == .tapDisabledByTimeout ? "macOS отключила перехват по тайм-ауту" : "macOS временно отключила перехват")
                if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if switcher.handle(type: type, event: event) { return nil }
            return Unmanaged.passUnretained(event)
        },
        userInfo: nil)
    else { return false }

    eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

migrateOldSettings()
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
tables.rebuild()
let controller = AppController()

// Первый запуск или нет доступа — окно с пошаговой настройкой (системный запрос — по кнопке в нём).
if !UserDefaults.standard.bool(forKey: OnboardingController.doneKey) || !AXIsProcessTrusted() {
    DispatchQueue.main.async { onboarding.show() }
}

func updateStatusTitle() {
    let ok = eventTap != nil
    let secure = secureInputOwner()
    let button = controller.statusItem.button
    if secure != nil, ok, let img = NSImage(systemSymbolName: "lock", accessibilityDescription: "Раскладушка") {
        // Защищённый ввод: Раскладушка временно «слеп», и это видно в строке меню.
        img.isTemplate = true
        button?.image = img
        button?.title = ""
    } else if let img = AppController.statusIcon(ok: ok) {
        button?.image = img
        button?.title = ""
    } else {
        button?.title = ok ? "⇄" : "⇄⚠︎"
    }
    if !switcher.recoveredInputs.isEmpty {
        button?.title = "!"
        button?.toolTip = "Есть набранный текст для восстановления — откройте меню Раскладушки"
    } else if !ok {
        button?.toolTip = "Раскладушка: нет доступа к клавиатуре (Универсальный доступ)"
    } else if let owner = secure {
        button?.toolTip = "Раскладушка не видит клавиш: защищённый ввод включило «\(owner)»"
    } else {
        button?.toolTip = "Раскладушка"
    }
}

/// Раз в несколько секунд проверяет перехват клавиатуры и сама его восстанавливает
/// (после сна, отзыва или повторной выдачи разрешений, отключения системой).
func healthCheck() {
    guard let tap = eventTap else {
        _ = installTap()
        updateStatusTitle()
        return
    }
    if !AXIsProcessTrusted() {  // разрешение отозвали
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        eventTap = nil
        updateStatusTitle()
        return
    }
    if !CGEvent.tapIsEnabled(tap: tap) {  // систему отключила перехват
        switcher.reset()
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    updateStatusTitle()
}

// Accessibility-запросы к зависшему приложению не должны тормозить ввод (по умолчанию ждут 6 с).
AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.2)

// Словари загружаются при первой проверке — делаем это заранее, а не на первом слове.
DispatchQueue.main.async {
    _ = isValidWord("проверка", lang: "ru")
    _ = isValidWord("check", lang: "en")
}

_ = installTap()
updateStatusTitle()
let healthTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in healthCheck() }
healthTimer.tolerance = 1.5  // не будим процессор чаще, чем нужно
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
    tables.rebuild()  // могли подключить другую клавиатуру (ANSI/ISO)
    healthCheck()
}

// Раскладку сменили вручную посреди набора — буфер больше не соответствует тексту.
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
    object: nil, queue: .main) { _ in
    if ProcessInfo.processInfo.systemUptime - lastOwnLayoutSwitch > 1.0 { switcher.reset() }
}

app.run()
