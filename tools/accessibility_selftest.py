"""Exercise the production retry function with a deterministic scheduler and AX replies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "main.swift").read_text()
function = source[source.index("func prepareAccessibility("):source.index("func readFocusedElement(")]
stubs = r'''
import Foundation
typealias CFString = String
let kCFBooleanTrue = true
enum AXError: Int { case success = 0, cannotComplete = -25204, attributeUnsupported = -25205 }
final class NSRunningApplication {
    let processIdentifier: Int32
    let bundleIdentifier: String? = "com.openai.codex"
    let bundleURL: URL? = URL(fileURLWithPath: "/Test.app")
    var isTerminated = false
    init(_ pid: Int32) { processIdentifier = pid }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    var frontmostApplication: NSRunningApplication?
}
final class DispatchWorkItem {
    let action: () -> Void
    var cancelled = false
    init(block: @escaping () -> Void) { action = block }
    func cancel() { cancelled = true }
}
struct Deadline {
    static func now() -> Deadline { Deadline() }
    static func + (lhs: Deadline, rhs: Double) -> Deadline { lhs }
}
final class DispatchQueue {
    static let main = DispatchQueue()
    var pending: [DispatchWorkItem] = []
    func asyncAfter(deadline: Deadline, execute: DispatchWorkItem) { pending.append(execute) }
    func drain() {
        var count = 0
        while !pending.isEmpty {
            count += 1
            precondition(count < 20, "unbounded retry")
            let item = pending.removeFirst()
            if !item.cancelled { item.action() }
        }
    }
}
var accessibilityPrepared = Set<Int32>()
var accessibilityPreparationNote = ""
var accessibilityRetry: DispatchWorkItem?
var replies: [AXError] = []
var calls: [String] = []
func usesElectronRuntime(at url: URL) -> Bool { true }
func AXUIElementCreateApplication(_ pid: Int32) -> Int32 { pid }
func AXUIElementSetAttributeValue(_ element: Int32, _ name: String, _ value: Bool) -> AXError {
    calls.append(name)
    return replies.isEmpty ? .cannotComplete : replies.removeFirst()
}
func reset(_ app: NSRunningApplication) {
    accessibilityPrepared = []
    accessibilityRetry = nil
    DispatchQueue.main.pending = []
    calls = []
    replies = []
    NSWorkspace.shared.frontmostApplication = app
}
'''
checks = r'''
let app = NSRunningApplication(1)
reset(app)
replies = [.cannotComplete, .attributeUnsupported, .success]
prepareAccessibility(for: app)
DispatchQueue.main.drain()
precondition(accessibilityPrepared.contains(1))
precondition(calls == ["AXManualAccessibility", "AXManualAccessibility", "AXEnhancedUserInterface"])
print("Temporary failure recovers automatically through fallback: PASS")
reset(app)
prepareAccessibility(for: app)
NSWorkspace.shared.frontmostApplication = NSRunningApplication(2)
DispatchQueue.main.drain()
precondition(calls.count == 1)
print("Changed foreground cancels retry: PASS")
reset(app)
prepareAccessibility(for: app)
app.isTerminated = true
DispatchQueue.main.drain()
precondition(calls.count == 1)
app.isTerminated = false
print("Terminated process cancels retry: PASS")
reset(app)
prepareAccessibility(for: app)
DispatchQueue.main.drain()
precondition(calls.count == 6)
print("Persistent failure stops after five retries: PASS")
reset(app)
prepareAccessibility(for: app)
replies = [.success]
prepareAccessibility(for: app)
DispatchQueue.main.drain()
precondition(calls.count == 2)
print("New activation cancels stale retry: PASS")
'''
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory)
    (path / "main.swift").write_text(stubs + function + checks)
    subprocess.run(["swiftc", str(path / "main.swift"), "-o", str(path / "check")], check=True)
    subprocess.run([str(path / "check")], check=True)
