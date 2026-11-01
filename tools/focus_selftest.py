from pathlib import Path
import subprocess, tempfile
r=Path(__file__).resolve().parents[1]
s=(r/'main.swift').read_text().split('// MARK: - Меню в строке состояния')[0]
s=s.replace('if verifyEnabled { return false }', 'if true { return false }')
s=s.replace('private func','func').replace('private var','var').replace('private enum','enum')
def body(signature,replacement):
 global s
 a=s.index(signature); b=s.index('{',a); level=1; i=b+1
 while level:
  if s[i]=='{': level+=1
  if s[i]=='}': level-=1
  i+=1
 s=s[:b+1]+'\n'+replacement+'\n'+s[i-1:]
s=s.replace('let element: AXUIElement', 'let probeID = probeFocus\n    let element: AXUIElement')
body('static func capture(', 'return InputTarget(element: AXUIElementCreateSystemWide())')
body('func isCurrent(', 'return probeID == probeFocus')
body('func tapKey(', '    probeEvents.append("\\(probeFocus):key=\\(code):text=\\(text ?? "")")')
body('func switchLayout(', '    probeLayout = toRussian ? "ru" : "en"')
body('func currentLayoutLanguage(', '    return probeLayout')
body('func focusedAppBundleID(', '    return probeFocus')
body('func caretContext(', '    return probeCaret')
s='var probeEvents: [String] = []\nvar probeFocus = "A"\nvar probeLayout = "en"\nvar probeCaret: CaretContext?\n'+s
s+='''
tables.rebuild()
let ks: [Key] = [5,4,11,2,17,45].map { Key(code: CGKeyCode($0)) }
probeCaret = CaretContext(before: "x", selection: 0, tail: 0)
let shortCheck = checkBeforeCaret(shownString(ks, lang: "en")!)
if case .unknown = shortCheck { print("BUG: readable short field classified as unknown") }
let a = Switcher()
let started = a.replaceWord(ks, fromLang: "en", toRussian: true) {}
print("Short-field replacement started (must be false):", started, "backspaces:", probeEvents.count)
RunLoop.current.run(until: Date().addingTimeInterval(0.35))
probeEvents = []; probeFocus = "A"; probeLayout = "en"
probeCaret = CaretContext(before: shownString(ks, lang: "en")!, selection: 0, tail: 0)
let b = Switcher()
_ = b.replaceWord(ks, fromLang: "en", toRussian: true) {}
probeFocus = "B"
probeCaret = CaretContext(before: "", selection: 0, tail: 0)
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
let wrongFocus = probeEvents.filter { $0.hasPrefix("B:") }
print("Events sent to different focus:", wrongFocus.count)
if started || !wrongFocus.isEmpty { exit(1) }
probeFocus = "A"; probeEvents = []; probeLayout = "en"
probeCaret = CaretContext(before: shownString(ks, lang: "en")!, selection: 0, tail: 0)
let c = Switcher(); c.busy = true
_ = c.replaceWord(ks, fromLang: "en", toRussian: true) {}
c.reset()
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
if probeEvents.contains(where: { !$0.hasSuffix("text=") }) { exit(1) }
print("Cancelled operation produced no delayed text: PASS")
probeEvents = []; probeLayout = "en"
probeCaret = CaretContext(before: shownString(ks, lang: "en")!, selection: 0, tail: 0)
let d = Switcher(); d.busy = true
_ = d.replaceWord(ks, fromLang: "en", toRussian: true) {}
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
if probeEvents.filter({ !$0.hasSuffix("text=") }).count != ks.count { exit(1) }
print("Unchanged field still receives replacement: PASS")
probeEvents = []; probeLayout = "en"
let recovered = Switcher(); recovered.busy = true
recovered.pending = ks
recovered.cancelOperation()
if recovered.recoveredInputs != [shownString(ks, lang: "en")!] { exit(1) }
recovered.cancelOperation()
if recovered.recoveredInputs.count != 1 || !recovered.pending.isEmpty { exit(1) }
if !probeEvents.isEmpty { exit(1) }
print("Cancelled pending text retained once without replay: PASS")
let interrupted = Switcher(); interrupted.busy = true
interrupted.deletedText = "original"; interrupted.heldBoundary = " "
interrupted.pending = ks
interrupted.cancelOperation()
if interrupted.recoveredInputs != ["original " + shownString(ks, lang: "en")!] { exit(1) }
print("Deleted original and withheld boundary remain recoverable: PASS")
let beforeIgnored = ignoredWords
probeCaret = CaretContext(before: shownString(ks, lang: "en")!, selection: 0, tail: 0)
let undo = Switcher(); undo.buffer = ks
undo.lastAuto = (ks, "undo-test", ProcessInfo.processInfo.systemUptime)
undo.convertWord()
RunLoop.current.run(until: Date().addingTimeInterval(0.4))
if ignoredWords != beforeIgnored || undo.lastUndoCandidate != "undo-test" { exit(1) }
print("Undo requires explicit action to remember exception: PASS")
print("All keyboard output was intercepted by the probe; no events sent to apps.")
'''
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp); (p/'main.swift').write_text(s)
 subprocess.run(['swiftc','-O',str(p/'main.swift'),str(r/'Ngrams.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)

