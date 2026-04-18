# Push-to-Talk — Design Spec

**Date:** 2026-04-18
**Repo:** https://github.com/timmal/push-to-talk.git
**Status:** Approved design, pending implementation plan

## 1. Goal

macOS menubar application for push-to-talk live speech-to-text dictation with mixed Russian/English (code-switching) support. Hold a modifier key, speak, release — the cleaned transcript is typed into the focused text input. If insertion fails, the text is still available in a menu-bar popover showing the last 10 transcriptions and weekly usage metrics.

All transcription runs locally on the GPU/ANE via WhisperKit. No network calls at runtime. No subscription, no telemetry.

## 2. Core user flows

1. **Dictation.** Hold Right Option (or Right Cmd, configurable) beyond the hold threshold → HUD appears → speak → release → text is typed into the focused input.
2. **Short tap passthrough.** A tap of Right Option shorter than the hold threshold does not start recording; the key behaves as normal for the focused application.
3. **Recovery.** If the focused input changed or cannot accept text (e.g. password field), the transcript is still saved and surfaced in the menu-bar popover, where the user can click to copy.
4. **Quick glance.** Menu-bar popover shows `total_words`, `wpm (7d avg)`, and the last 10 transcriptions.
5. **Configuration.** Preferences window: hotkey, Whisper model, HUD content mode, HUD position, hold threshold, history controls.

## 3. Non-goals

- No main app window. All interaction is through the menu bar and the transparent HUD.
- No streaks, no gamification.
- No cloud sync, no account, no telemetry.
- No LLM post-processing (heuristic cleaning only).
- No custom hotkey recorder UI v1 — fixed choice between Right Option and Right Cmd.

## 4. Architecture

Single menubar-only Swift application (`LSUIElement = true`, no Dock icon). SwiftUI for the popover and Preferences, AppKit (`NSPanel`) for the transparent HUD overlay.

### 4.1 Data flow (single transcription)

```
[Right Option/Cmd held beyond threshold]
    ↓ (CGEventTap listener-only, global)
HotkeyMonitor → AudioRecorder (AVAudioEngine, 16 kHz mono Float32)
                     ↓ streaming 500 ms chunks
           TranscriptionEngine (WhisperKit, CoreML / ANE)
                     ↓ partial text updates
              OverlayWindow (live HUD)
[Key released]
                     ↓ full audio buffer
           TranscriptionEngine.finalize() → raw text
                     ↓
              TextCleaner (regex: fillers, repetitions, ru/en)
                     ↓
              TextInserter (CGEventKeyboardSetUnicodeString)
                     ↓                       ↓
     [types into focused input]    HistoryStore (SQLite)
                                   MetricsEngine.record()
```

### 4.2 Module responsibilities

| Module | Responsibility | Depends on |
|---|---|---|
| `HotkeyMonitor` | Global listener-only CGEventTap. Emits `startHold`/`endHold` after the hold threshold elapses. | CGEventTap, Accessibility permission |
| `AudioRecorder` | AVAudioEngine capture, 16 kHz mono, RMS amplitude publisher (50 Hz), PCM buffer on stop. | AVAudioEngine, Microphone permission |
| `TranscriptionEngine` | WhisperKit wrapper. Streaming partial transcription + final high-quality pass. Holds the loaded model in memory. | WhisperKit, `ModelManager` |
| `TextCleaner` | Pure function `clean(String) -> String`. Rule-based filler/repetition removal. | — |
| `TextInserter` | Synthesizes keystrokes via `CGEventKeyboardSetUnicodeString`. Detects `AXSecureTextField` and skips insertion. | CGEvent, AXUIElement |
| `OverlayWindow` | Transparent `NSPanel`, two content modes and two positions. | AppKit |
| `MenuBarController` | `NSStatusItem`, SwiftUI popover, state icon toggling. | AppKit, SwiftUI |
| `HistoryStore` | SQLite (GRDB) persistence, read last N, clear. | GRDB |
| `MetricsEngine` | Computes `total_words` and 7-day rolling WPM from `HistoryStore`. | `HistoryStore` |
| `PreferencesStore` | `@AppStorage` wrappers for all settings. | UserDefaults |
| `ModelManager` | Discovers existing Whisper models on disk, downloads via WhisperKit if absent, reports progress. | WhisperKit, FileManager |
| `PermissionsManager` | Checks microphone, accessibility, input monitoring; drives onboarding. | AVCaptureDevice, AXIsProcessTrusted, IOHIDCheckAccess |

Each module lives in its own file, exposes a narrow interface, and is testable in isolation.

## 5. Component design

### 5.1 HotkeyMonitor

- **Passive observation, not interception.** Uses `CGEvent.tapCreate` with `.listenOnly` on `.cgSessionEventTap`, listening for `.flagsChanged`. The OS still delivers the key to the focused application; we just observe.
- **Hold-threshold logic.**
  - On modifier-down for the configured key (and only that key, no other modifiers): schedule a `DispatchWorkItem` with delay = hold-threshold. When it fires, emit `startHold`.
  - On modifier-up: if the item has not yet fired, cancel it (short tap — no-op). If it has fired, emit `endHold`.
- **Key selection.** `preferences.hotkey == .rightOption` → keyCode 61 / flag `NSEvent.ModifierFlags.option` with device-dependent right bit. `.rightCmd` → keyCode 54 / `.command` right bit. Ignore events where other modifier flags are also set (avoid conflict with user's OS shortcuts).
- Requires Accessibility permission to create the event tap.

### 5.2 AudioRecorder

- `AVAudioEngine` with a tap on `inputNode` at the hardware format, converted to 16 kHz mono Float32 via `AVAudioConverter`.
- Publishes two streams:
  - `amplitudePublisher: PassthroughSubject<Float, Never>` — RMS per 20 ms window, 50 Hz (for the waveform HUD).
  - `chunkPublisher: PassthroughSubject<AVAudioPCMBuffer, Never>` — 500 ms chunks (for streaming transcription).
- On stop: returns the concatenated full `AVAudioPCMBuffer`.
- Handles input-device change notifications by stopping the current recording and emitting a `deviceChanged` event (current transcription is discarded with a user notification).

### 5.3 TranscriptionEngine

- Wraps WhisperKit. Loads the model selected in preferences (`tiny` / `small` / `turbo` (default) / `large-v3`) via `ModelManager`.
- **Streaming path.** For each chunk from `AudioRecorder.chunkPublisher`, append to a running buffer and call `transcribe(audioArray:)` with short time window. Publishes `partialText` to the HUD. This is best-effort — if streaming lags, the HUD just updates less often.
- **Final path.** On `endHold`: cancel any in-flight streaming transcription, run the final pass on the full buffer (no streaming, better context), return the text.
- **Decoding options.**
  - `language = nil` (auto-detect).
  - `temperature = 0.0`.
  - `initialPrompt = "Смешанная русско-английская речь. Сохраняй английские термины в оригинале: meeting, deadline, pull request."` — biases Whisper to keep English tokens in their original script rather than transliterating to Cyrillic.
- Empty result (silence) → return `nil`. The pipeline skips insertion and history for nil.

### 5.4 TextCleaner

Pure function. Applied in order, each step operates on the output of the previous:

1. **Filler removal.**
   - Russian: `\b(э{1,}|м{2,}|эмм+|ну|типа|короче|это самое)\b` — case-insensitive, word-boundary.
   - English: `\b(uh+|um+|er+|uhm+|like|you know|I mean)\b` — case-insensitive.
2. **Consecutive word repetition.** `\b(\w+)\s+\1\b` → `$1` (stutter compression).
3. **Whitespace normalization.** Trim, collapse runs of whitespace to single space.
4. **Sentence casing.** Uppercase the first letter. If the last character is not `.`, `!`, or `?`, append `.`.

Each rule lives in an array of `CleanRule { pattern, replacement, options }`, tested on fixture pairs (ru, en, mixed). Users cannot customize rules in v1.

### 5.5 TextInserter

- Build a pair of empty key events via `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with `virtualKey = 0`, then set the Unicode string via `CGEventKeyboardSetUnicodeString`. Post the down event, then the up, to `.cghidEventTap`.
- **Secure-field detection.** Before posting, query the system-wide `AXUIElement`:
  - `kAXFocusedUIElementAttribute` → focused element.
  - Read `kAXRoleAttribute`. If `AXSecureTextField` (or `AXRoleDescription == "secure text field"` as fallback), abort insertion. Save to history with `inserted = 0`, show `NSUserNotification` "Skipped password field — transcript saved to history."
- **No focus.** If no focused element, or the focused element doesn't accept text (no `AXValueAttribute` writeable), same fallback: history only + notification.
- Clipboard is never touched.

### 5.6 OverlayWindow

- `NSPanel` subclass. Style: `.nonactivatingPanel | .borderless`. Level: `.floating`. `backgroundColor = .clear`, `isOpaque = false`, `hasShadow = false`, `ignoresMouseEvents = true`, `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]`.
- **Content modes** (from `preferences.hudContentMode`):
  - `.waveformPill` — `HUDPillView`: 20 vertical bars, heights driven by `AudioRecorder.amplitudePublisher` (log-scaled). Recording dot on the left, "Recording" text optional.
  - `.liveTranscript` — `HUDTranscriptView`: single line of text bound to `TranscriptionEngine.partialText`. Max width 480 pt, tail-truncated.
- **Positions** (from `preferences.hudPosition`):
  - `.underMenuBarIcon` — origin computed from `NSStatusItem.button.window.convertToScreen(...)`, centered horizontally on the icon, 6 pt below the menu bar, on the screen containing the icon.
  - `.bottomCenter` — centered on `NSScreen.main.visibleFrame`, 80 pt from the bottom.
- Shown on `startHold`, hidden with a 150 ms fade on `endHold`.

### 5.7 MenuBarController + Popover

- `NSStatusItem` with variable-length length. Icon: SF Symbol `antenna.radiowaves.left.and.right` (placeholder; user will replace). Active state during recording: same symbol, red tint (`.contentTintColor`).
- Click → SwiftUI popover (`NSPopover`, 320 pt wide, content-hugging height).
- Popover content:
  - Header: app name + status dot.
  - Metrics block: `total_words`, `wpm (7d avg)`.
  - Recent transcriptions: list of up to 10 items; each row shows cleaned text (one-line truncation) and a copy icon; click anywhere on the row copies the full text to the pasteboard and flashes a "Copied" inline toast.
  - Footer: "Preferences…" (opens `PreferencesWindow`), "Quit".

### 5.8 Preferences

Separate `NSWindow` with SwiftUI content. Tabs: General, Audio, History.

- **General.** Hotkey picker (Right Option / Right Cmd). Hold threshold slider (50–800 ms, step 10, default 150). HUD content mode (Waveform / Live transcript). HUD position (Under menu bar / Bottom center). Launch at login (ServiceManagement SMAppService).
- **Audio.** Whisper model picker (tiny / small / turbo / large-v3), shows disk status ("Downloaded" / "Not downloaded — 800 MB"). Input device info (read-only, default system input).
- **History.** "Clear history" button (confirm dialog). Shows on-disk size of `history.sqlite`.

## 6. Persistence

SQLite database at `~/Library/Application Support/push-to-talk/history.sqlite`, accessed via GRDB.

```sql
CREATE TABLE transcriptions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at INTEGER NOT NULL,    -- unix ms
  raw_text TEXT NOT NULL,
  cleaned_text TEXT NOT NULL,
  duration_ms INTEGER NOT NULL,
  word_count INTEGER NOT NULL,
  language TEXT,
  inserted INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_transcriptions_created_at ON transcriptions(created_at);
```

Rows are never auto-pruned — metrics need history. "Clear history" in Preferences truncates the table.

`word_count` is computed at insert time: `cleaned_text.split(by: whitespaceAndNewlines).count`.

Preferences live in `UserDefaults` (suite: `com.timmal.push-to-talk`). Downloaded models live in `~/Library/Application Support/push-to-talk/models/`.

## 7. Metrics

- `total_words = SUM(word_count) FROM transcriptions`
- `wpm_7d = SUM(word_count) * 60000.0 / SUM(duration_ms) WHERE created_at > now - 7*86400*1000`

Computed lazily when the popover is opened, with an in-memory cache invalidated by an `NSNotification` posted on each new transcription.

## 8. Model management

`ModelManager.locateModel(for: modelID)` checks in order:

1. `~/Library/Application Support/push-to-talk/models/<modelID>/` (own managed location)
2. `~/Library/Application Support/MacWhisper/models/whisperkit/models/argmaxinc/whisperkit-coreml/openai_whisper-<modelID>*/` (reuse MacWhisper's downloaded CoreML models when available)
3. Not found → download via `WhisperKit.download(variant:)` into location (1), with progress surfaced to the UI. This is the only network call the app makes, and only on first run or when the user changes the selected model.

If the selected model fails to load (corruption, missing files), fall back to `tiny` and emit a user notification. The fallback model is bundled as an SPM resource (~40 MB) so the app is usable offline on first launch.

## 9. Permissions and onboarding

`PermissionsManager` runs at launch and when the popover is opened. Required:

- **Microphone.** `AVCaptureDevice.requestAccess(for: .audio)`. Plist key `NSMicrophoneUsageDescription`.
- **Accessibility.** `AXIsProcessTrusted()`. Needed for the CGEventTap and `CGEvent.post` insertion. Cannot be requested programmatically — onboarding opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility` and instructs the user.
- **Input Monitoring.** `IOHIDCheckAccess(.listenEvent)`. Usually auto-granted with Accessibility; checked for completeness.

First-run onboarding is a single SwiftUI window walking through the three permissions. The app does not start the hotkey listener until all three are granted.

## 10. Edge cases

| Case | Behavior |
|---|---|
| Hold < threshold | No-op, short tap passes through to the OS. |
| Hold > 60 s | Recording continues; `os_log` warning logged. |
| Rapid consecutive holds | Queue: first finishes transcription in background, second starts immediately. Insertion happens in order. |
| Focused element is `AXSecureTextField` | Skip insertion, save to history with `inserted = 0`, show notification. |
| No focused element | Skip insertion, save to history, show notification. |
| Whisper returns empty string | Skip insertion and history. |
| Selected model fails to load | Fall back to `tiny`, notify. |
| Audio device changes mid-recording | Stop current recording, discard buffer, notify. |
| Accessibility permission revoked at runtime | Hotkey listener disabled, banner shown in popover with one-tap re-grant. |
| Microphone permission revoked at runtime | Hotkey listener disabled, banner shown in popover. |

## 11. Testing

- **Unit — `TextCleaner`.** Fixture pairs (~30 cases) across ru, en, and mixed. Each rule has at least two positive cases and one negative (don't overmatch).
- **Unit — `MetricsEngine`.** Seed an in-memory GRDB queue with rows across time ranges; assert total and rolling WPM.
- **Unit — `HotkeyMonitor`.** Mock `CGEvent` stream; verify debounce, threshold, and multi-modifier filtering.
- **Integration — transcription pipeline.** Bundled fixture WAV (short ru+en mixed utterance) → `TranscriptionEngine` → `TextCleaner`. Asserts: (a) English tokens preserved in Latin script, (b) fillers removed, (c) output non-empty.
- **Manual smoke checklist (in `README.md`).** Hotkey hold, HUD appearance in both modes and both positions, insertion into TextEdit / Chrome / Terminal, secure-field skip, permission onboarding, model download progress, preferences persistence across relaunch.

Whisper correctness is not regression-tested — the model is a black box. The integration test asserts on coarse properties only.

## 12. Project layout

```
push-to-talk/
├─ Package.swift                     WhisperKit, GRDB, KeyboardShortcuts
├─ PushToTalk.xcodeproj/             Xcode project for .app bundle + entitlements
├─ Sources/
│  ├─ App/
│  │  ├─ PushToTalkApp.swift
│  │  └─ AppDelegate.swift
│  ├─ Core/
│  │  ├─ HotkeyMonitor.swift
│  │  ├─ AudioRecorder.swift
│  │  ├─ TranscriptionEngine.swift
│  │  ├─ TextCleaner.swift
│  │  ├─ TextInserter.swift
│  │  ├─ HistoryStore.swift
│  │  ├─ MetricsEngine.swift
│  │  ├─ ModelManager.swift
│  │  ├─ PermissionsManager.swift
│  │  └─ PreferencesStore.swift
│  └─ UI/
│     ├─ MenuBarController.swift
│     ├─ PopoverView.swift
│     ├─ OverlayWindow.swift
│     ├─ HUDPillView.swift
│     ├─ HUDTranscriptView.swift
│     ├─ PreferencesWindow.swift
│     └─ OnboardingView.swift
├─ Tests/
│  ├─ TextCleanerTests.swift
│  ├─ MetricsEngineTests.swift
│  ├─ HotkeyMonitorTests.swift
│  └─ Fixtures/
├─ Resources/
│  ├─ Info.plist
│  ├─ PushToTalk.entitlements
│  └─ Assets.xcassets
├─ scripts/
│  ├─ install.sh
│  └─ release.sh
├─ Casks/
│  └─ push-to-talk.rb
├─ .github/workflows/
│  ├─ ci.yml
│  └─ release.yml
└─ README.md
```

## 13. Distribution

- **Development.** `git clone && open PushToTalk.xcodeproj && ⌘R`. Or `./scripts/install.sh` for a release build copied to `/Applications`.
- **Release (Homebrew cask).** `brew tap timmal/tap && brew install --cask push-to-talk`. The cask points at the DMG attached to a GitHub Release. `brew upgrade` handles updates.
- **Signing.** Ad-hoc (`codesign -s - --deep --force`). No paid Apple Developer account. On first launch the user right-clicks → Open to bypass Gatekeeper, once.
- **CI.** `.github/workflows/ci.yml` runs `xcodebuild test` on PR. `.github/workflows/release.yml` triggers on `v*` tags: build, sign ad-hoc, create DMG, upload to GitHub Release, and (optionally) open a PR against `timmal/homebrew-tap` bumping the cask version and SHA.

## 14. Open questions for implementation planning

- Exact `initialPrompt` wording may need tuning against real mixed-language recordings — plan in a quick prompt-tuning pass during implementation of `TranscriptionEngine`.
- Streaming transcription cadence (500 ms chunks) is a starting point — may adjust based on live-transcript HUD responsiveness.
- Whether to bundle `tiny` as an SPM resource vs. download on first run — favored bundling for a usable first experience, but adds ~40 MB to the DMG.
