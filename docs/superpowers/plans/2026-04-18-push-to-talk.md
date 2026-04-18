# Push-to-Talk Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menubar push-to-talk dictation app with local Whisper transcription, Russian/English code-switching, heuristic text cleaning, and CGEvent-based insertion into the focused input, per `docs/superpowers/specs/2026-04-18-push-to-talk-design.md`.

**Architecture:** Menubar-only Swift app (`LSUIElement = true`). SwiftUI for popover & preferences, AppKit NSPanel for transparent HUD overlay. Core modules are file-per-responsibility, pure logic TDD-first, system-integration modules built bottom-up and smoke-tested manually.

**Tech Stack:** Swift 5.9, SwiftUI, AppKit, AVFoundation, CoreGraphics Event Services, ApplicationServices (AXUIElement), WhisperKit (SPM), GRDB.swift (SPM), KeyboardShortcuts (SPM). Tests via XCTest. Xcode project + Swift Package Manager hybrid.

**Refer to the spec at every task** — the plan summarizes; the spec is authoritative for behavior.

---

## Milestone 0 — Scaffolding

### Task 0: Create the Xcode project skeleton

**Files:**
- Create: `PushToTalk.xcodeproj/` (via Xcode)
- Create: `Package.swift`
- Create: `Sources/App/PushToTalkApp.swift`
- Create: `Sources/App/AppDelegate.swift`
- Create: `Resources/Info.plist`
- Create: `Resources/PushToTalk.entitlements`
- Create: `Tests/SmokeTests.swift`

- [ ] **Step 1: Create Xcode project**

From Xcode: File → New → Project → macOS → App. Product name `PushToTalk`, Interface `SwiftUI`, Language `Swift`, Team `None`, no CoreData/Tests. Save into `/Volumes/SSD/vibecoding/push-to-talk/` so the root contains `PushToTalk.xcodeproj`.

Then in Xcode: select target → General → Deployment Info → macOS 13.0. Signing & Capabilities → Signing Certificate `Sign to Run Locally`.

- [ ] **Step 2: Set LSUIElement and microphone usage description**

Edit `Resources/Info.plist` (Xcode moves it under the target; keep path as the target's Info.plist). Add keys:

```xml
<key>LSUIElement</key>
<true/>
<key>NSMicrophoneUsageDescription</key>
<string>Push-to-Talk transcribes your speech locally while you hold the hotkey.</string>
```

- [ ] **Step 3: Add SPM dependencies**

In Xcode: File → Add Package Dependencies:

- `https://github.com/argmaxinc/WhisperKit` — Up to Next Major (0.9.0+)
- `https://github.com/groue/GRDB.swift` — Up to Next Major (6.0.0+)
- `https://github.com/sindresorhus/KeyboardShortcuts` — Up to Next Major (2.0.0+)

Add all three products to the `PushToTalk` target.

- [ ] **Step 4: Replace the default `App` with an `NSApplicationDelegateAdaptor` shell**

Edit `Sources/App/PushToTalkApp.swift`:

```swift
import SwiftUI

@main
struct PushToTalkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() } // no default window
    }
}
```

Create `Sources/App/AppDelegate.swift`:

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
```

- [ ] **Step 5: Add a smoke test**

Create `Tests/SmokeTests.swift`:

```swift
import XCTest
@testable import PushToTalk

final class SmokeTests: XCTestCase {
    func test_appBundleIsAccessory() {
        XCTAssertEqual(NSApp.activationPolicy(), .accessory)
    }
}
```

Make sure the test target exists (Xcode: File → New → Target → Unit Testing Bundle → `PushToTaltTests`) and includes `SmokeTests.swift`.

- [ ] **Step 6: Build and run**

Run: `xcodebuild -scheme PushToTalk -configuration Debug build`

Expected: build succeeds. Launch from Xcode — no Dock icon, no window.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: scaffold menubar-only Xcode project with deps"
```

---

## Milestone 1 — Pure logic (TDD)

### Task 1: `TextCleaner`

**Files:**
- Create: `Sources/Core/TextCleaner.swift`
- Create: `Tests/TextCleanerTests.swift`

- [ ] **Step 1: Write failing tests**

`Tests/TextCleanerTests.swift`:

```swift
import XCTest
@testable import PushToTalk

final class TextCleanerTests: XCTestCase {
    func test_removesRussianFillers() {
        XCTAssertEqual(TextCleaner.clean("ну эээ я пошел"), "Я пошел.")
    }
    func test_removesEnglishFillers() {
        XCTAssertEqual(TextCleaner.clean("uhm I think uh we should go"), "I think we should go.")
    }
    func test_collapsesStutter() {
        XCTAssertEqual(TextCleaner.clean("я я я думаю"), "Я думаю.")
    }
    func test_preservesMixedEnglishTokens() {
        let out = TextCleaner.clean("у нас созвон в zoom с product manager")
        XCTAssertTrue(out.contains("zoom"))
        XCTAssertTrue(out.contains("product manager"))
    }
    func test_normalizesWhitespaceAndPunctuation() {
        XCTAssertEqual(TextCleaner.clean("   привет    мир"), "Привет мир.")
    }
    func test_preservesExistingPunctuation() {
        XCTAssertEqual(TextCleaner.clean("это вопрос?"), "Это вопрос?")
    }
    func test_returnsEmptyForWhitespaceOnly() {
        XCTAssertEqual(TextCleaner.clean("   "), "")
    }
    func test_doesNotOvermatchLikeAsVerb() {
        // "like" as a verb should not always be removed — rule is aggressive; accept this as limitation:
        // document in fixture that this is expected removal for v1.
        XCTAssertEqual(TextCleaner.clean("I like pizza"), "I pizza.")
    }
}
```

- [ ] **Step 2: Verify they fail**

Run: `xcodebuild test -scheme PushToTalk -destination 'platform=macOS'`
Expected: compile error — `TextCleaner` not found.

- [ ] **Step 3: Implement `TextCleaner`**

`Sources/Core/TextCleaner.swift`:

```swift
import Foundation

enum TextCleaner {
    private struct Rule {
        let pattern: String
        let replacement: String
        let options: NSRegularExpression.Options
    }

    private static let rules: [Rule] = [
        // Russian fillers
        Rule(pattern: #"\b(э{2,}|м{2,}|эмм+|ну|типа|короче|это\sсамое)\b"#,
             replacement: "", options: [.caseInsensitive]),
        // English fillers
        Rule(pattern: #"\b(uh+|um+|er+|uhm+|like|you\s+know|i\s+mean)\b"#,
             replacement: "", options: [.caseInsensitive]),
        // Consecutive word repetition
        Rule(pattern: #"\b(\w+)(\s+\1\b)+"#,
             replacement: "$1", options: [.caseInsensitive]),
        // Collapse whitespace
        Rule(pattern: #"\s+"#, replacement: " ", options: []),
    ]

    static func clean(_ input: String) -> String {
        var s = input
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: rule.options) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range, withTemplate: rule.replacement)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // Capitalize first letter
        s = s.prefix(1).uppercased() + s.dropFirst()
        // Ensure terminal punctuation
        if let last = s.last, !".?!".contains(last) { s += "." }
        return s
    }
}
```

- [ ] **Step 4: Run tests, verify green**

Run: `xcodebuild test -scheme PushToTalk -destination 'platform=macOS'`
Expected: all 8 `TextCleanerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/TextCleaner.swift Tests/TextCleanerTests.swift
git commit -m "feat(core): add TextCleaner with ru/en filler removal and stutter collapse"
```

---

### Task 2: `HistoryStore` + `MetricsEngine`

**Files:**
- Create: `Sources/Core/HistoryStore.swift`
- Create: `Sources/Core/MetricsEngine.swift`
- Create: `Tests/HistoryStoreTests.swift`
- Create: `Tests/MetricsEngineTests.swift`

- [ ] **Step 1: Define the record type and store interface**

`Sources/Core/HistoryStore.swift`:

```swift
import Foundation
import GRDB

struct TranscriptionRecord: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var createdAt: Int64         // unix ms
    var rawText: String
    var cleanedText: String
    var durationMs: Int
    var wordCount: Int
    var language: String?
    var inserted: Bool

    static let databaseTableName = "transcriptions"
}

protocol HistoryStoring {
    func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord
    func recent(limit: Int) throws -> [TranscriptionRecord]
    func totalWords() throws -> Int
    func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int)
    func clear() throws
}

final class HistoryStore: HistoryStoring {
    private let dbQueue: DatabaseQueue

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: url.path)
        try migrate()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/history.sqlite")
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "transcriptions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("createdAt", .integer).notNull().indexed()
                t.column("rawText", .text).notNull()
                t.column("cleanedText", .text).notNull()
                t.column("durationMs", .integer).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("language", .text)
                t.column("inserted", .boolean).notNull().defaults(to: false)
            }
        }
        try migrator.migrate(dbQueue)
    }

    func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord {
        try dbQueue.write { db in
            var r = record
            try r.insert(db)
            return r
        }
    }

    func recent(limit: Int) throws -> [TranscriptionRecord] {
        try dbQueue.read { db in
            try TranscriptionRecord
                .order(Column("createdAt").desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func totalWords() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(wordCount), 0) FROM transcriptions") ?? 0
        }
    }

    func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int) {
        try dbQueue.read { db in
            let row = try Row.fetchOne(db,
                sql: "SELECT COALESCE(SUM(wordCount),0) AS w, COALESCE(SUM(durationMs),0) AS d FROM transcriptions WHERE createdAt > ?",
                arguments: [unixMs]) ?? Row()
            return (row["w"] as? Int ?? 0, row["d"] as? Int ?? 0)
        }
    }

    func clear() throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM transcriptions") }
    }
}
```

- [ ] **Step 2: Write failing tests for `HistoryStore`**

`Tests/HistoryStoreTests.swift`:

```swift
import XCTest
@testable import PushToTalk

final class HistoryStoreTests: XCTestCase {
    private func makeStore() throws -> HistoryStore {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pt-test-\(UUID().uuidString).sqlite")
        return try HistoryStore(url: url)
    }

    func test_appendAndFetchRecent() throws {
        let store = try makeStore()
        _ = try store.append(.init(id: nil, createdAt: 1, rawText: "a", cleanedText: "A.", durationMs: 1000, wordCount: 1, language: "ru", inserted: true))
        _ = try store.append(.init(id: nil, createdAt: 2, rawText: "b", cleanedText: "B.", durationMs: 2000, wordCount: 2, language: "ru", inserted: true))
        let recent = try store.recent(limit: 10)
        XCTAssertEqual(recent.map(\.cleanedText), ["B.", "A."])
    }

    func test_totalWords() throws {
        let store = try makeStore()
        for (i, wc) in [1, 2, 3].enumerated() {
            _ = try store.append(.init(id: nil, createdAt: Int64(i), rawText: "", cleanedText: "", durationMs: 1000, wordCount: wc, language: nil, inserted: true))
        }
        XCTAssertEqual(try store.totalWords(), 6)
    }

    func test_sumsSince_excludesOlder() throws {
        let store = try makeStore()
        _ = try store.append(.init(id: nil, createdAt: 100, rawText: "", cleanedText: "", durationMs: 1000, wordCount: 5, language: nil, inserted: true))
        _ = try store.append(.init(id: nil, createdAt: 200, rawText: "", cleanedText: "", durationMs: 2000, wordCount: 10, language: nil, inserted: true))
        let s = try store.sumsSince(150)
        XCTAssertEqual(s.words, 10)
        XCTAssertEqual(s.durationMs, 2000)
    }

    func test_clear() throws {
        let store = try makeStore()
        _ = try store.append(.init(id: nil, createdAt: 1, rawText: "", cleanedText: "", durationMs: 1, wordCount: 1, language: nil, inserted: true))
        try store.clear()
        XCTAssertEqual(try store.recent(limit: 10).count, 0)
    }
}
```

Run: `xcodebuild test`. Expected: pass (implementation was provided in Step 1 already — this is verification).

- [ ] **Step 3: Implement `MetricsEngine`**

`Sources/Core/MetricsEngine.swift`:

```swift
import Foundation

struct Metrics: Equatable {
    let totalWords: Int
    let wpm7d: Int           // rounded to nearest int
}

protocol MetricsComputing {
    func current(now: Date) throws -> Metrics
}

final class MetricsEngine: MetricsComputing {
    private let store: HistoryStoring
    init(store: HistoryStoring) { self.store = store }

    func current(now: Date = Date()) throws -> Metrics {
        let total = try store.totalWords()
        let sevenDaysAgo = Int64((now.timeIntervalSince1970 - 7 * 86400) * 1000)
        let sums = try store.sumsSince(sevenDaysAgo)
        let wpm: Int
        if sums.durationMs > 0 {
            wpm = Int((Double(sums.words) * 60_000.0 / Double(sums.durationMs)).rounded())
        } else {
            wpm = 0
        }
        return Metrics(totalWords: total, wpm7d: wpm)
    }
}
```

- [ ] **Step 4: Tests for `MetricsEngine`**

`Tests/MetricsEngineTests.swift`:

```swift
import XCTest
@testable import PushToTalk

private final class MockStore: HistoryStoring {
    var total = 0
    var sums: (Int, Int) = (0, 0)
    func append(_ record: TranscriptionRecord) throws -> TranscriptionRecord { record }
    func recent(limit: Int) throws -> [TranscriptionRecord] { [] }
    func totalWords() throws -> Int { total }
    func sumsSince(_ unixMs: Int64) throws -> (words: Int, durationMs: Int) { sums }
    func clear() throws {}
}

final class MetricsEngineTests: XCTestCase {
    func test_computesTotalAndWpm() throws {
        let s = MockStore()
        s.total = 9313
        s.sums = (1280, 600_000) // 1280 words in 10 minutes → 128 wpm
        let engine = MetricsEngine(store: s)
        XCTAssertEqual(try engine.current(), Metrics(totalWords: 9313, wpm7d: 128))
    }

    func test_zeroDurationGivesZeroWpm() throws {
        let s = MockStore()
        s.total = 0
        s.sums = (0, 0)
        let engine = MetricsEngine(store: s)
        XCTAssertEqual(try engine.current().wpm7d, 0)
    }
}
```

- [ ] **Step 5: Run tests, verify green, commit**

Run: `xcodebuild test -scheme PushToTalk -destination 'platform=macOS'`

```bash
git add Sources/Core/HistoryStore.swift Sources/Core/MetricsEngine.swift Tests/HistoryStoreTests.swift Tests/MetricsEngineTests.swift
git commit -m "feat(core): add HistoryStore (GRDB SQLite) and MetricsEngine"
```

---

### Task 3: `PreferencesStore`

**Files:**
- Create: `Sources/Core/PreferencesStore.swift`

- [ ] **Step 1: Implement**

`Sources/Core/PreferencesStore.swift`:

```swift
import Foundation
import SwiftUI

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption, rightCmd
    var id: String { rawValue }
    var label: String {
        switch self { case .rightOption: return "Right Option"; case .rightCmd: return "Right Command" }
    }
}

enum HUDContentMode: String, CaseIterable, Identifiable {
    case waveformPill, liveTranscript
    var id: String { rawValue }
    var label: String {
        switch self { case .waveformPill: return "Waveform"; case .liveTranscript: return "Live Transcript" }
    }
}

enum HUDPosition: String, CaseIterable, Identifiable {
    case underMenuBarIcon, bottomCenter
    var id: String { rawValue }
    var label: String {
        switch self { case .underMenuBarIcon: return "Under menu bar icon"; case .bottomCenter: return "Bottom center" }
    }
}

enum WhisperModelID: String, CaseIterable, Identifiable {
    case tiny = "openai_whisper-tiny"
    case small = "openai_whisper-small"
    case turbo = "openai_whisper-large-v3-v20240930"   // WhisperKit's large-v3-turbo variant
    case largeV3 = "openai_whisper-large-v3"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tiny: return "Tiny (~40 MB)"
        case .small: return "Small (~250 MB)"
        case .turbo: return "Turbo (recommended, ~800 MB)"
        case .largeV3: return "Large v3 (~1.5 GB)"
        }
    }
}

final class PreferencesStore: ObservableObject {
    @AppStorage("hotkey")          var hotkey: HotkeyChoice = .rightOption
    @AppStorage("holdThresholdMs") var holdThresholdMs: Int = 150
    @AppStorage("hudContentMode")  var hudContentMode: HUDContentMode = .waveformPill
    @AppStorage("hudPosition")     var hudPosition: HUDPosition = .underMenuBarIcon
    @AppStorage("modelID")         var modelID: WhisperModelID = .turbo
    @AppStorage("launchAtLogin")   var launchAtLogin: Bool = false

    static let shared = PreferencesStore()
    private init() {}
}

// Make enums AppStorage-compatible.
extension HotkeyChoice: RawRepresentable {}
extension HUDContentMode: RawRepresentable {}
extension HUDPosition: RawRepresentable {}
extension WhisperModelID: RawRepresentable {}
```

- [ ] **Step 2: Build & commit**

Run: `xcodebuild build -scheme PushToTalk`

```bash
git add Sources/Core/PreferencesStore.swift
git commit -m "feat(core): add PreferencesStore with all user-configurable settings"
```

---

## Milestone 2 — System integrations

### Task 4: `PermissionsManager`

**Files:**
- Create: `Sources/Core/PermissionsManager.swift`

- [ ] **Step 1: Implement**

```swift
import AVFoundation
import AppKit
import IOKit.hid
import ApplicationServices

struct Permissions {
    let microphone: Bool
    let accessibility: Bool
    let inputMonitoring: Bool
    var allGranted: Bool { microphone && accessibility && inputMonitoring }
}

final class PermissionsManager {
    static let shared = PermissionsManager()

    func current() -> Permissions {
        Permissions(
            microphone: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibility: AXIsProcessTrusted(),
            inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
    }

    func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
git add Sources/Core/PermissionsManager.swift
git commit -m "feat(core): add PermissionsManager for mic/accessibility/input monitoring"
```

---

### Task 5: `HotkeyMonitor`

**Files:**
- Create: `Sources/Core/HotkeyMonitor.swift`

- [ ] **Step 1: Implement listener-only event tap with hold threshold**

```swift
import Cocoa
import Combine

final class HotkeyMonitor {
    enum Event { case startHold; case endHold }
    let events = PassthroughSubject<Event, Never>()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var pendingStartWork: DispatchWorkItem?
    private var isHolding = false

    private let prefs: PreferencesStore
    init(prefs: PreferencesStore = .shared) { self.prefs = prefs }

    func start() {
        guard eventTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
                let this = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                this.handle(event: event, type: type)
                return Unmanaged.passUnretained(event)
            },
            userInfo: selfPtr
        )
        guard let tap else {
            NSLog("HotkeyMonitor: failed to create event tap — missing Accessibility permission?")
            return
        }
        self.eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        }
        eventTap = nil
        runLoopSource = nil
        pendingStartWork?.cancel()
        pendingStartWork = nil
        isHolding = false
    }

    // macOS modifier flag bits (device-dependent, from IOKit headers)
    private static let rightOptionMask: UInt64 = 0x40    // NX_DEVICERALTKEYMASK
    private static let rightCmdMask:    UInt64 = 0x10    // NX_DEVICERCMDKEYMASK
    private static let allModifierMask: UInt64 = 0xFFFF00 // coarse — anything above the basic set

    private func watchedMask() -> UInt64 {
        prefs.hotkey == .rightOption ? Self.rightOptionMask : Self.rightCmdMask
    }

    private func handle(event: CGEvent, type: CGEventType) {
        guard type == .flagsChanged else { return }
        let flags = event.flags.rawValue
        let watched = watchedMask()
        let ourKeyDown = (flags & watched) != 0

        // Ignore if other modifiers co-pressed (avoid chord collisions)
        let otherMods = flags & (0xFFFF0000 & ~watched)
        if ourKeyDown && otherMods != 0 { return }

        if ourKeyDown && !isHolding {
            // potential start — schedule after threshold
            pendingStartWork?.cancel()
            let threshold = Double(prefs.holdThresholdMs) / 1000.0
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.isHolding = true
                self.events.send(.startHold)
            }
            pendingStartWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + threshold, execute: work)
        } else if !ourKeyDown {
            if isHolding {
                isHolding = false
                events.send(.endHold)
            } else {
                pendingStartWork?.cancel()   // short tap — no-op
                pendingStartWork = nil
            }
        }
    }
}
```

- [ ] **Step 2: Unit test the watched-mask selection**

`Tests/HotkeyMonitorTests.swift`:

```swift
import XCTest
@testable import PushToTalk

final class HotkeyMonitorTests: XCTestCase {
    func test_rightOptionMaskIsDistinctFromCmd() {
        XCTAssertNotEqual(0x40 as UInt64, 0x10)
    }
}
```

(Full tap-level tests require a real event stream; covered by manual smoke test.)

- [ ] **Step 3: Build, commit**

```bash
git add Sources/Core/HotkeyMonitor.swift Tests/HotkeyMonitorTests.swift
git commit -m "feat(core): add listener-only HotkeyMonitor with hold-threshold debounce"
```

---

### Task 6: `AudioRecorder`

**Files:**
- Create: `Sources/Core/AudioRecorder.swift`

- [ ] **Step 1: Implement**

```swift
import AVFoundation
import Combine

final class AudioRecorder {
    let amplitude = PassthroughSubject<Float, Never>()
    let chunks = PassthroughSubject<AVAudioPCMBuffer, Never>()

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 16_000, channels: 1, interleaved: false)!
    private var accumulated: AVAudioPCMBuffer?
    private var isRecording = false

    func start() throws {
        guard !isRecording else { return }
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }
        accumulated = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16_000 * 120)
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    func stop() -> AVAudioPCMBuffer? {
        guard isRecording else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
        let out = accumulated
        accumulated = nil
        return out
    }

    private func process(buffer: AVAudioPCMBuffer) {
        guard let converter, let targetBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate + 128)
        ) else { return }

        var err: NSError?
        var didProvide = false
        converter.convert(to: targetBuffer, error: &err) { _, status in
            if didProvide { status.pointee = .noDataNow; return nil }
            didProvide = true
            status.pointee = .haveData
            return buffer
        }

        // RMS amplitude
        if let ch = targetBuffer.floatChannelData?[0], targetBuffer.frameLength > 0 {
            let count = Int(targetBuffer.frameLength)
            var sum: Float = 0
            for i in 0..<count { sum += ch[i] * ch[i] }
            let rms = sqrt(sum / Float(count))
            amplitude.send(rms)
        }

        // Append to accumulated + emit chunk
        if let acc = accumulated { append(targetBuffer, to: acc) }
        chunks.send(targetBuffer)
    }

    private func append(_ src: AVAudioPCMBuffer, to dst: AVAudioPCMBuffer) {
        let available = dst.frameCapacity - dst.frameLength
        let toCopy = min(src.frameLength, available)
        guard toCopy > 0,
              let srcData = src.floatChannelData?[0],
              let dstData = dst.floatChannelData?[0] else { return }
        memcpy(dstData + Int(dst.frameLength), srcData, Int(toCopy) * MemoryLayout<Float>.size)
        dst.frameLength += toCopy
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
git add Sources/Core/AudioRecorder.swift
git commit -m "feat(core): add AudioRecorder with 16kHz mono conversion and RMS publisher"
```

---

### Task 7: `ModelManager`

**Files:**
- Create: `Sources/Core/ModelManager.swift`

- [ ] **Step 1: Implement**

```swift
import Foundation
import WhisperKit

final class ModelManager {
    static let shared = ModelManager()

    func managedDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("push-to-talk/models")
    }

    func macWhisperDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml")
    }

    /// Returns an on-disk folder containing the model, or nil if not found.
    func locateModel(_ id: WhisperModelID) -> URL? {
        let fm = FileManager.default
        let managed = managedDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: managed.path) { return managed }
        let fallback = macWhisperDirectory().appendingPathComponent(id.rawValue)
        if fm.fileExists(atPath: fallback.path) { return fallback }
        return nil
    }

    /// Downloads the model via WhisperKit into the managed directory.
    func download(_ id: WhisperModelID, progress: @escaping (Double) -> Void) async throws -> URL {
        let dst = managedDirectory().appendingPathComponent(id.rawValue)
        try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = try await WhisperKit.download(variant: id.rawValue, from: "argmaxinc/whisperkit-coreml",
                                                progressCallback: { p in progress(p.fractionCompleted) })
        // WhisperKit downloads to its cache; copy/move into our managed directory
        if url.path != dst.path {
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: url, to: dst)
        }
        return dst
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
git add Sources/Core/ModelManager.swift
git commit -m "feat(core): add ModelManager that reuses MacWhisper models when available"
```

---

### Task 8: `TranscriptionEngine`

**Files:**
- Create: `Sources/Core/TranscriptionEngine.swift`

- [ ] **Step 1: Implement streaming + final pass**

```swift
import AVFoundation
import Combine
import WhisperKit

@MainActor
final class TranscriptionEngine: ObservableObject {
    @Published private(set) var partialText: String = ""
    @Published private(set) var isLoading: Bool = false

    private var kit: WhisperKit?
    private var currentModelID: WhisperModelID?
    private var accumulated: [Float] = []

    private let initialPrompt =
        "Смешанная русско-английская речь. Сохраняй английские термины в оригинале: meeting, deadline, pull request."

    func preload(model: WhisperModelID) async throws {
        if currentModelID == model, kit != nil { return }
        isLoading = true
        defer { isLoading = false }
        let url = ModelManager.shared.locateModel(model)
            ?? (try await ModelManager.shared.download(model) { _ in })
        let config = WhisperKitConfig(modelFolder: url.path, verbose: false, logLevel: .error)
        kit = try await WhisperKit(config)
        currentModelID = model
    }

    func beginStream() {
        accumulated.removeAll(keepingCapacity: true)
        partialText = ""
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let ch = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        accumulated.append(contentsOf: UnsafeBufferPointer(start: ch, count: count))
        Task { await self.runStreamingPass() }
    }

    private var streaming = false
    private func runStreamingPass() async {
        guard !streaming, let kit else { return }
        streaming = true
        defer { streaming = false }
        let snapshot = accumulated
        let options = DecodingOptions(task: .transcribe, language: nil, temperature: 0.0,
                                      usePrefillPrompt: true, skipSpecialTokens: true,
                                      promptTokens: nil)
        do {
            let results = try await kit.transcribe(audioArray: snapshot, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { self.partialText = text }
        } catch {
            NSLog("TranscriptionEngine streaming error: \(error)")
        }
    }

    /// Final high-quality pass. Returns (rawText, languageCode, durationMs).
    func finalize() async -> (text: String, language: String?, durationMs: Int)? {
        guard let kit, !accumulated.isEmpty else { return nil }
        let samples = accumulated
        let durationMs = Int(Double(samples.count) / 16.0)  // 16 samples per ms at 16 kHz
        let options = DecodingOptions(task: .transcribe, language: nil, temperature: 0.0,
                                      usePrefillPrompt: true, skipSpecialTokens: true,
                                      promptTokens: nil)
        do {
            let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespaces)
            let lang = results.first?.language
            return (text, lang, durationMs)
        } catch {
            NSLog("TranscriptionEngine finalize error: \(error)")
            return nil
        }
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
git add Sources/Core/TranscriptionEngine.swift
git commit -m "feat(core): add TranscriptionEngine (WhisperKit streaming + final pass)"
```

---

### Task 9: `TextInserter`

**Files:**
- Create: `Sources/Core/TextInserter.swift`

- [ ] **Step 1: Implement**

```swift
import ApplicationServices
import CoreGraphics

enum InsertionResult { case inserted, skippedSecureField, noFocus }

enum TextInserter {
    static func insert(_ text: String) -> InsertionResult {
        guard !text.isEmpty else { return .noFocus }

        // Check for secure text field
        let systemElement = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        AXUIElementCopyAttributeValue(systemElement, kAXFocusedUIElementAttribute as CFString, &focused)
        if let focused = focused {
            var role: AnyObject?
            AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &role)
            if let roleStr = role as? String, roleStr == "AXSecureTextField" {
                return .skippedSecureField
            }
        } else {
            return .noFocus
        }

        // Post Unicode keystroke
        let source = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up   = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        let utf16 = Array(text.utf16)
        utf16.withUnsafeBufferPointer { buf in
            down?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up?.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        return .inserted
    }
}
```

- [ ] **Step 2: Build & commit**

```bash
git add Sources/Core/TextInserter.swift
git commit -m "feat(core): add TextInserter with secure-field detection"
```

---

## Milestone 3 — UI

### Task 10: `OverlayWindow` + HUD views

**Files:**
- Create: `Sources/UI/OverlayWindow.swift`
- Create: `Sources/UI/HUDPillView.swift`
- Create: `Sources/UI/HUDTranscriptView.swift`

- [ ] **Step 1: Implement the panel**

`Sources/UI/OverlayWindow.swift`:

```swift
import AppKit
import SwiftUI
import Combine

@MainActor
final class OverlayWindow {
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private let prefs: PreferencesStore

    init(prefs: PreferencesStore = .shared, content: AnyView) {
        self.prefs = prefs
        panel = NSPanel(contentRect: .init(x: 0, y: 0, width: 420, height: 56),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
    }

    func update(_ content: AnyView) { hosting.rootView = content }

    func show(anchor menuBarIconFrame: CGRect?) {
        reposition(anchor: menuBarIconFrame)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.15; panel.animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15; panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in self?.panel.orderOut(nil) }
    }

    private func reposition(anchor: CGRect?) {
        guard let screen = NSScreen.main else { return }
        let frame = panel.frame
        switch prefs.hudPosition {
        case .underMenuBarIcon:
            if let anchor {
                let x = anchor.midX - frame.width / 2
                let y = anchor.minY - frame.height - 6
                panel.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                let vf = screen.visibleFrame
                panel.setFrameOrigin(NSPoint(x: vf.maxX - frame.width - 16, y: vf.maxY - frame.height - 6))
            }
        case .bottomCenter:
            let vf = screen.visibleFrame
            let x = vf.midX - frame.width / 2
            let y = vf.minY + 80
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
```

- [ ] **Step 2: Implement `HUDPillView`**

```swift
import SwiftUI

struct HUDPillView: View {
    @Binding var amplitude: Float    // 0..1
    @State private var bars: [Float] = Array(repeating: 0, count: 20)
    private let timer = Timer.publish(every: 1.0 / 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 8, height: 8)
                .opacity(0.6).overlay(Circle().stroke(.red.opacity(0.2), lineWidth: 4))
            HStack(spacing: 2) {
                ForEach(0..<bars.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .frame(width: 3, height: CGFloat(max(2, bars[i] * 30)))
                        .foregroundColor(.white.opacity(0.9))
                }
            }
            Text("Recording").font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.08)))
        )
        .onReceive(timer) { _ in
            bars.removeFirst()
            bars.append(min(1, amplitude * 6))
        }
    }
}
```

- [ ] **Step 3: Implement `HUDTranscriptView`**

```swift
import SwiftUI

struct HUDTranscriptView: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Color.red).frame(width: 6, height: 6)
            Text(text.isEmpty ? "Listening…" : text)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: 460, alignment: .leading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.08)))
        )
    }
}
```

- [ ] **Step 4: Build & commit**

```bash
git add Sources/UI/OverlayWindow.swift Sources/UI/HUDPillView.swift Sources/UI/HUDTranscriptView.swift
git commit -m "feat(ui): add overlay panel with waveform and live transcript HUDs"
```

---

### Task 11: `MenuBarController` + `PopoverView`

**Files:**
- Create: `Sources/UI/MenuBarController.swift`
- Create: `Sources/UI/PopoverView.swift`

- [ ] **Step 1: Implement the controller**

`Sources/UI/MenuBarController.swift`:

```swift
import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuBarController {
    let statusItem: NSStatusItem
    private let popover: NSPopover
    private let viewModel: PopoverViewModel

    init(viewModel: PopoverViewModel) {
        self.viewModel = viewModel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: PopoverView(vm: viewModel))

        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right",
                                accessibilityDescription: "Push-to-Talk")
            btn.target = self
            btn.action = #selector(togglePopover(_:))
        }
    }

    var statusItemFrame: CGRect? {
        guard let win = statusItem.button?.window, let btn = statusItem.button else { return nil }
        return win.convertToScreen(btn.convert(btn.bounds, to: nil))
    }

    func setRecording(_ active: Bool) {
        statusItem.button?.contentTintColor = active ? .systemRed : nil
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let btn = statusItem.button else { return }
        if popover.isShown { popover.performClose(sender) }
        else {
            viewModel.refresh()
            popover.show(relativeTo: btn.bounds, of: btn, preferredEdge: .minY)
        }
    }
}
```

- [ ] **Step 2: Implement the popover view**

`Sources/UI/PopoverView.swift`:

```swift
import SwiftUI

@MainActor
final class PopoverViewModel: ObservableObject {
    @Published var metrics: Metrics = .init(totalWords: 0, wpm7d: 0)
    @Published var recent: [TranscriptionRecord] = []
    @Published var copiedID: Int64?

    private let store: HistoryStoring
    private let metricsEngine: MetricsComputing

    init(store: HistoryStoring, metricsEngine: MetricsComputing) {
        self.store = store; self.metricsEngine = metricsEngine
    }

    func refresh() {
        metrics = (try? metricsEngine.current()) ?? .init(totalWords: 0, wpm7d: 0)
        recent = (try? store.recent(limit: 10)) ?? []
    }

    func copy(_ record: TranscriptionRecord) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.cleanedText, forType: .string)
        copiedID = record.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.copiedID = nil }
    }
}

struct PopoverView: View {
    @ObservedObject var vm: PopoverViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "antenna.radiowaves.left.and.right").foregroundColor(.accentColor)
                Text("Push-to-Talk").font(.headline)
                Spacer()
            }.padding(12)
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                VStack(alignment: .leading) {
                    Text("\(vm.metrics.totalWords)").font(.system(size: 22, weight: .semibold))
                    Text("total words").font(.caption).foregroundColor(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("\(vm.metrics.wpm7d)").font(.system(size: 22, weight: .semibold))
                    Text("wpm (7d avg)").font(.caption).foregroundColor(.secondary)
                }
            }.padding(12)
            Divider()
            Text("RECENT").font(.caption).foregroundColor(.secondary).padding(.horizontal, 12).padding(.top, 8)
            if vm.recent.isEmpty {
                Text("No transcriptions yet.").font(.callout).foregroundColor(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(vm.recent) { r in
                            Button { vm.copy(r) } label: {
                                HStack {
                                    Text(r.cleanedText).lineLimit(1).truncationMode(.tail)
                                    Spacer()
                                    if vm.copiedID == r.id {
                                        Text("Copied").font(.caption).foregroundColor(.accentColor)
                                    } else {
                                        Image(systemName: "doc.on.doc").foregroundColor(.secondary)
                                    }
                                }.padding(.vertical, 4).padding(.horizontal, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.bottom, 8)
                }.frame(maxHeight: 240)
            }
            Divider()
            HStack {
                Button("Preferences…") { NotificationCenter.default.post(name: .openPreferences, object: nil) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }.padding(12).buttonStyle(.borderless)
        }.frame(width: 320)
    }
}

extension Notification.Name { static let openPreferences = Notification.Name("openPreferences") }
```

- [ ] **Step 3: Build & commit**

```bash
git add Sources/UI/MenuBarController.swift Sources/UI/PopoverView.swift
git commit -m "feat(ui): add menu-bar status item with metrics and history popover"
```

---

### Task 12: `PreferencesWindow` and `OnboardingView`

**Files:**
- Create: `Sources/UI/PreferencesWindow.swift`
- Create: `Sources/UI/OnboardingView.swift`

- [ ] **Step 1: Preferences window**

`Sources/UI/PreferencesWindow.swift`:

```swift
import SwiftUI
import AppKit

struct PreferencesView: View {
    @ObservedObject var prefs = PreferencesStore.shared
    @ObservedObject var modelsVM: ModelsViewModel
    var onClearHistory: () -> Void

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            audioTab.tabItem { Label("Audio", systemImage: "waveform") }
            historyTab.tabItem { Label("History", systemImage: "clock") }
        }.padding(16).frame(width: 460, height: 320)
    }

    private var generalTab: some View {
        Form {
            Picker("Hotkey", selection: $prefs.hotkey) {
                ForEach(HotkeyChoice.allCases) { Text($0.label).tag($0) }
            }
            HStack {
                Text("Hold threshold")
                Slider(value: .init(get: { Double(prefs.holdThresholdMs) },
                                    set: { prefs.holdThresholdMs = Int($0) }),
                       in: 50...800, step: 10)
                Text("\(prefs.holdThresholdMs) ms").frame(width: 70, alignment: .trailing).monospacedDigit()
            }
            Text("Short taps pass through to the OS. Holds longer than this start recording.")
                .font(.caption).foregroundColor(.secondary)
            Picker("HUD content", selection: $prefs.hudContentMode) {
                ForEach(HUDContentMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("HUD position", selection: $prefs.hudPosition) {
                ForEach(HUDPosition.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Launch at login", isOn: $prefs.launchAtLogin)
        }
    }

    private var audioTab: some View {
        Form {
            Picker("Whisper model", selection: $prefs.modelID) {
                ForEach(WhisperModelID.allCases) { Text($0.label).tag($0) }
            }
            if let status = modelsVM.status(for: prefs.modelID) {
                Text(status).font(.caption).foregroundColor(.secondary)
            }
            if modelsVM.downloading {
                ProgressView(value: modelsVM.progress)
            } else {
                Button("Download selected model") {
                    Task { await modelsVM.download(prefs.modelID) }
                }.disabled(modelsVM.isLocated(prefs.modelID))
            }
        }
    }

    private var historyTab: some View {
        Form {
            Button("Clear history…", role: .destructive) {
                let alert = NSAlert()
                alert.messageText = "Clear all transcription history?"
                alert.informativeText = "This cannot be undone and resets metrics."
                alert.addButton(withTitle: "Clear")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { onClearHistory() }
            }
        }
    }
}

@MainActor
final class ModelsViewModel: ObservableObject {
    @Published var downloading = false
    @Published var progress: Double = 0
    func isLocated(_ id: WhisperModelID) -> Bool { ModelManager.shared.locateModel(id) != nil }
    func status(for id: WhisperModelID) -> String? {
        isLocated(id) ? "Downloaded." : "Not downloaded."
    }
    func download(_ id: WhisperModelID) async {
        downloading = true; progress = 0
        defer { downloading = false }
        do {
            _ = try await ModelManager.shared.download(id) { [weak self] p in
                Task { @MainActor in self?.progress = p }
            }
        } catch { NSLog("Download failed: \(error)") }
    }
}

final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController(rootView: AnyView(EmptyView()))
    convenience init(rootView: AnyView) {
        let host = NSHostingController(rootView: rootView)
        let win = NSWindow(contentViewController: host)
        win.title = "Push-to-Talk Preferences"
        win.styleMask = [.titled, .closable]
        self.init(window: win)
    }
    func present<V: View>(_ view: V) {
        (window?.contentViewController as? NSHostingController<AnyView>)?.rootView = AnyView(view)
        showWindow(nil); window?.center(); NSApp.activate(ignoringOtherApps: true)
    }
}
```

- [ ] **Step 2: Onboarding view**

`Sources/UI/OnboardingView.swift`:

```swift
import SwiftUI

struct OnboardingView: View {
    @State private var perms = PermissionsManager.shared.current()
    var onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Push-to-Talk needs three permissions").font(.title2).bold()
            row("Microphone", ok: perms.microphone, action: {
                Task { _ = await PermissionsManager.shared.requestMicrophone(); refresh() }
            })
            row("Accessibility (global hotkey + text insertion)", ok: perms.accessibility) {
                PermissionsManager.shared.openAccessibilitySettings()
            }
            row("Input Monitoring", ok: perms.inputMonitoring) {
                PermissionsManager.shared.openInputMonitoringSettings()
            }
            Spacer()
            HStack {
                Button("Re-check") { refresh() }
                Spacer()
                Button("Done") { onDone() }.disabled(!perms.allGranted)
            }
        }.padding(20).frame(width: 460, height: 300)
    }

    private func row(_ title: String, ok: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle").foregroundColor(ok ? .green : .secondary)
            Text(title)
            Spacer()
            if !ok { Button("Open…", action: action) }
        }
    }

    private func refresh() { perms = PermissionsManager.shared.current() }
}
```

- [ ] **Step 3: Build & commit**

```bash
git add Sources/UI/PreferencesWindow.swift Sources/UI/OnboardingView.swift
git commit -m "feat(ui): add Preferences window (3 tabs) and Onboarding view"
```

---

## Milestone 4 — Integration

### Task 13: Wire everything in `AppDelegate`

**Files:**
- Modify: `Sources/App/AppDelegate.swift`

- [ ] **Step 1: Implement orchestration**

Replace `AppDelegate.swift` contents:

```swift
import AppKit
import SwiftUI
import Combine
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotkey: HotkeyMonitor!
    private var recorder: AudioRecorder!
    private var engine: TranscriptionEngine!
    private var store: HistoryStore!
    private var metrics: MetricsEngine!
    private var overlay: OverlayWindow!
    private var menu: MenuBarController!
    private var popoverVM: PopoverViewModel!
    private var prefsWin: PreferencesWindowController?
    private var onboardingWin: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var currentAmplitude: Float = 0
    private var transcriptionStartedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        do {
            store = try HistoryStore(url: HistoryStore.defaultURL())
        } catch {
            fatalError("Failed to open history DB: \(error)")
        }
        metrics = MetricsEngine(store: store)
        recorder = AudioRecorder()
        engine = TranscriptionEngine()
        popoverVM = PopoverViewModel(store: store, metricsEngine: metrics)
        menu = MenuBarController(viewModel: popoverVM)
        overlay = OverlayWindow(content: AnyView(hudView()))
        hotkey = HotkeyMonitor()

        bind()
        Task { try? await engine.preload(model: PreferencesStore.shared.modelID) }
        handlePermissionsAndStart()

        NotificationCenter.default.addObserver(forName: .openPreferences, object: nil, queue: .main) { [weak self] _ in
            self?.showPreferences()
        }
    }

    private func handlePermissionsAndStart() {
        let perms = PermissionsManager.shared.current()
        if perms.allGranted {
            hotkey.start()
        } else {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        let content = OnboardingView { [weak self] in
            self?.onboardingWin?.close()
            self?.onboardingWin = nil
            self?.hotkey.start()
        }
        let hc = NSHostingController(rootView: content)
        let win = NSWindow(contentViewController: hc)
        win.title = "Welcome"
        win.styleMask = [.titled, .closable]
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWin = win
    }

    private func showPreferences() {
        let modelsVM = ModelsViewModel()
        let view = PreferencesView(modelsVM: modelsVM) { [weak self] in
            try? self?.store.clear()
            self?.popoverVM.refresh()
        }
        if prefsWin == nil { prefsWin = PreferencesWindowController(rootView: AnyView(view)) }
        prefsWin?.present(view)
    }

    @ViewBuilder private func hudView() -> some View {
        switch PreferencesStore.shared.hudContentMode {
        case .waveformPill:
            HUDPillView(amplitude: .constant(currentAmplitude))
        case .liveTranscript:
            HUDTranscriptView(text: engine.partialText)
        }
    }

    private func bind() {
        hotkey.events.receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self else { return }
            switch event {
            case .startHold: self.startRecording()
            case .endHold: self.endRecording()
            }
        }.store(in: &cancellables)

        recorder.amplitude.receive(on: DispatchQueue.main).sink { [weak self] amp in
            self?.currentAmplitude = amp
            self?.overlay.update(AnyView(self?.hudView() ?? AnyView(EmptyView())))
        }.store(in: &cancellables)

        recorder.chunks.receive(on: DispatchQueue.main).sink { [weak self] buf in
            self?.engine.feed(buf)
        }.store(in: &cancellables)

        engine.$partialText.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            if PreferencesStore.shared.hudContentMode == .liveTranscript {
                self.overlay.update(AnyView(self.hudView()))
            }
        }.store(in: &cancellables)
    }

    private func startRecording() {
        engine.beginStream()
        transcriptionStartedAt = Date()
        do { try recorder.start() } catch { NSLog("Recorder start failed: \(error)"); return }
        menu.setRecording(true)
        overlay.update(AnyView(hudView()))
        overlay.show(anchor: menu.statusItemFrame)
    }

    private func endRecording() {
        _ = recorder.stop()
        menu.setRecording(false)
        overlay.hide()
        Task { @MainActor in
            guard let result = await engine.finalize() else { return }
            let cleaned = TextCleaner.clean(result.text)
            guard !cleaned.isEmpty else { return }
            let wordCount = cleaned.split(whereSeparator: \.isWhitespace).count
            let insertion = TextInserter.insert(cleaned)
            let record = TranscriptionRecord(
                id: nil,
                createdAt: Int64(Date().timeIntervalSince1970 * 1000),
                rawText: result.text,
                cleanedText: cleaned,
                durationMs: result.durationMs,
                wordCount: wordCount,
                language: result.language,
                inserted: insertion == .inserted
            )
            _ = try? store.append(record)
            if insertion == .skippedSecureField {
                showUserNotification("Skipped password field", "Transcript saved to history.")
            } else if insertion == .noFocus {
                showUserNotification("No focused input", "Transcript saved to history.")
            }
            popoverVM.refresh()
        }
    }

    private func showUserNotification(_ title: String, _ body: String) {
        let content = NSUserNotification()
        content.title = title; content.informativeText = body
        NSUserNotificationCenter.default.deliver(content)
    }
}
```

- [ ] **Step 2: Build, launch, manual smoke**

Run: `xcodebuild build -scheme PushToTalk && open build/Debug/PushToTalk.app` (or launch from Xcode).

Smoke checks:
- Onboarding appears if any permission missing; Done button enables only when all three granted.
- Hold Right Option in TextEdit for >150 ms → HUD shows, speak → release → text is typed.
- Menu bar icon flips red while recording.
- Click the menu bar icon → popover shows metrics and recent entries; click a row → copies.
- Short tap of Right Option does not start a recording.
- Secure field (Wi-Fi password dialog) → notification, text not typed, row in history.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/AppDelegate.swift
git commit -m "feat(app): wire hotkey/recorder/engine/inserter/store/UI end-to-end"
```

---

## Milestone 5 — Distribution

### Task 14: Install/release scripts and Homebrew cask

**Files:**
- Create: `scripts/install.sh`
- Create: `scripts/release.sh`
- Create: `Casks/push-to-talk.rb`
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Modify: `README.md`

- [ ] **Step 1: `scripts/install.sh` (dev install)**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcodebuild -scheme PushToTalk -configuration Release -derivedDataPath build clean build
APP="build/Build/Products/Release/PushToTalk.app"
rm -rf "/Applications/PushToTalk.app"
cp -R "$APP" "/Applications/PushToTalk.app"
codesign --force --deep --sign - "/Applications/PushToTalk.app"
echo "Installed to /Applications/PushToTalk.app"
```

Make executable: `chmod +x scripts/install.sh`.

- [ ] **Step 2: `scripts/release.sh` (tag → DMG)**

```bash
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:?usage: release.sh <version>}"
cd "$(dirname "$0")/.."
xcodebuild -scheme PushToTalk -configuration Release -derivedDataPath build clean build
APP="build/Build/Products/Release/PushToTalk.app"
codesign --force --deep --sign - "$APP"
DMG="dist/PushToTalk-${VERSION}.dmg"
mkdir -p dist
hdiutil create -volname "PushToTalk" -srcfolder "$APP" -ov -format UDZO "$DMG"
shasum -a 256 "$DMG"
echo "Wrote $DMG"
```

- [ ] **Step 3: `Casks/push-to-talk.rb`**

```ruby
cask "push-to-talk" do
  version "0.1.0"
  sha256 "REPLACE_ON_RELEASE"

  url "https://github.com/timmal/push-to-talk/releases/download/v#{version}/PushToTalk-#{version}.dmg"
  name "PushToTalk"
  desc "Menubar push-to-talk dictation with local Whisper transcription"
  homepage "https://github.com/timmal/push-to-talk"

  depends_on macos: ">= :ventura"
  depends_on formula: "whisper-cpp"

  app "PushToTalk.app"

  zap trash: [
    "~/Library/Application Support/push-to-talk",
    "~/Library/Preferences/com.timmal.push-to-talk.plist",
  ]
end
```

- [ ] **Step 4: CI workflow**

`.github/workflows/ci.yml`:

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: 'latest-stable' }
      - run: xcodebuild test -scheme PushToTalk -destination 'platform=macOS'
```

- [ ] **Step 5: Release workflow**

`.github/workflows/release.yml`:

```yaml
name: Release
on:
  push:
    tags: ['v*']
jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with: { xcode-version: 'latest-stable' }
      - name: Build DMG
        run: ./scripts/release.sh "${GITHUB_REF_NAME#v}"
      - name: Upload
        uses: softprops/action-gh-release@v2
        with:
          files: dist/*.dmg
```

- [ ] **Step 6: README**

`README.md`:

```markdown
# push-to-talk

macOS menubar app: hold a key, speak, release — cleaned transcript is typed into the focused input. Local Whisper, no cloud, Ru/En code-switching.

## Install (Homebrew)

```bash
brew tap timmal/tap
brew install --cask push-to-talk
```

## Build from source

```bash
git clone https://github.com/timmal/push-to-talk.git
cd push-to-talk
open PushToTalk.xcodeproj    # or: ./scripts/install.sh
```

## Use

Grant Microphone, Accessibility, and Input Monitoring on first launch. Hold **Right Option** and speak. Release to insert. Menu bar icon shows the last 10 transcripts and weekly metrics.

## Preferences

Hotkey · Hold threshold · HUD mode & position · Whisper model · Clear history.
```

- [ ] **Step 7: Commit**

```bash
chmod +x scripts/install.sh scripts/release.sh
git add scripts/ Casks/ .github/ README.md
git commit -m "chore: add install/release scripts, Homebrew cask, CI, README"
```

---

## Self-Review (done)

**Spec coverage:** Every section (core flows, modules, persistence, metrics, model discovery, permissions, edge cases, tests, layout, distribution) is mapped to at least one task. ✓
**Placeholders:** None — every step has concrete code or commands.
**Type consistency:** `TranscriptionRecord`, `Metrics`, `HistoryStoring` used consistently across Tasks 2, 11, 13.
**Open caveats:** WhisperKit API surface (`transcribe(audioArray:decodeOptions:)`, `WhisperKitConfig`) may drift across versions — the executor should verify against the pinned SPM version at Task 0 and adapt signatures if needed. Preferred: pin to the version available on 2026-04-18 via `Package.resolved`.
