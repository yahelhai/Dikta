<div align="center">
<img src="Resources/AppIcon.svg" width="128" alt="Dikta icon"/>

# Dikta

**Local voice dictation & lecture capture for macOS — Hebrew & English, no cloud required**

Push-to-talk dictation powered by whisper.cpp. Hold a key, speak, release — the text appears.
Plus: record your screen during a lecture and get a Markdown doc of every slide with what was said about it.
</div>

---

## What it does

Hold a keyboard shortcut (default: **Right Option**), speak, release:

- If the cursor is in a text field — the transcript is **typed right in** (and your clipboard is restored afterwards)
- If not — the transcript is **copied to the clipboard** and a notification appears

Everything runs on your machine. No audio or text ever leaves it.

## Features

- 🎙️ **Press-and-hold** — no clicks, no windows; just talk
- 🌍 **Automatic language routing** — Hebrew is routed to the [ivrit.ai](https://huggingface.co/ivrit-ai) fine-tune (if downloaded), everything else to Whisper large-v3-turbo
- ⌨️ **Custom shortcut** — a single key or a combo (⌃⌥Space etc.), captured from the menu
- 🧠 **Memory-aware** — models are unloaded after 5 idle minutes and reload in under a second
- ⚡ **Fast** — Metal on Apple Silicon; ~0.25s for 4s of speech on an M5 Pro
- 🖥️ **Screen recording → Markdown** — records a chosen display + system audio (the picker numbers each monitor on-screen so you pick the right one), detects slide changes live (perceptual hashing, no video file ever written), transcribes with timestamps, and writes `index.md`: every slide's screenshot with what was said over it
- 🤖 **Optional Claude summary** — Claude reads the slide images + transcript and writes a unified Hebrew `summary.md`: per-slide summaries, side topics, and action recaps for live coding/spreadsheet segments. Two engines: the local **Claude Code CLI** (default — runs on your Claude subscription, **no API credits**) or the **Messages API** with your own key (~$0.05–0.10 per lecture)

## Requirements

- macOS 14+ on Apple Silicon
- Xcode Command Line Tools only (`xcode-select --install`) — **no Xcode needed**
- ~600MB of disk for the base model (+1.6GB for the optional Hebrew model)
- *Only for the Claude summary:* either the [`claude` CLI](https://claude.com/claude-code) installed and logged in (default engine), or an Anthropic API key

## Installation

```bash
git clone https://github.com/yahelhai/Dikta.git
cd Dikta
make fetch     # downloads the whisper.cpp XCFramework (one-time)
make models    # downloads the base transcription model (~574MB)
make cert      # one-time: signing certificate so permissions survive updates
make install   # builds and installs to /Applications
open /Applications/Dikta.app
```

### Permissions (one-time)

Dikta needs three permissions — its menu shows ✓/✗ for each and opens the right settings pane on click:

| Permission | Why |
|---|---|
| Microphone | Recording your speech |
| Accessibility | Injecting text and detecting the focused text field |
| Input Monitoring | Listening for the global shortcut (CGEventTap) |
| Screen Recording | Only for the screen-recording feature — requested on first use, never at launch |

After granting Input Monitoring, quit and relaunch Dikta.

## Usage

1. Hold **Right Option**, speak, release
2. **Change the shortcut:** menu → "Shortcut: … — change…" → press the combo you want
3. **Better Hebrew:** menu → "Download improved Hebrew model (ivrit.ai)…" — once downloaded, Auto mode routes every Hebrew dictation to it automatically
4. **Language modes:** Auto (detection) / English / Hebrew

### Screen recording (lectures, meetings)

1. Menu → **🖥 הקלט מסך** → pick a display; recording starts (red icon, live timer in the menu)

   While the display list is open, **every connected monitor shows a large card with its own number** — the same numbers as the menu rows — so there is no guessing which "מסך 2" is which. Hovering a row highlights that monitor's card. The cards disappear the moment the menu closes, so they never end up in the recording.

2. Menu → **⏹ עצור הקלטה ועבד** — Dikta transcribes and writes the session folder:
   `~/Documents/Dikta/הקלטה <date>/` with `index.md` + `frames/` (one screenshot per detected slide, each with the transcript spoken over it). **No video file is ever written** — frames and audio are processed as they stream.
3. **Claude summary (optional):** menu → **"מנוע סיכום"** → pick an engine, then enable **"סיכום אוטומטי עם Claude"** — each recording then also gets `summary.md`, written by Claude from the slide images + transcript.

   | Engine | Billing | Needs |
   |---|---|---|
   | **Claude CLI (מנוי)** — default | Your Claude subscription — **no API credits** | The `claude` CLI installed (`~/.local/bin/claude`, Homebrew, or on your login `PATH`) and logged in. It reads the full-resolution slide PNGs straight off disk with its `Read` tool. |
   | **API key** | Anthropic API credits (~$0.05–0.10 per lecture) | A key set via menu → "הגדר Anthropic API Key…" (stored in the Keychain). Claude Haiku, images sent inline. |

   The toggle stays disabled — with an explanatory tooltip — until the *selected* engine is usable.

Also works on existing video files:

```bash
dikta video lecture.mp4 --language he [-o outdir] [--summarize] [--engine cli|api]
```

`--engine cli` (the default) summarizes through the local Claude Code CLI; `--engine api` uses the Anthropic key from the Keychain. The flag is only meaningful together with `--summarize`.

Exit codes: `0` ok · `4` index.md produced but the summary step was skipped/failed.

## Development

```bash
swift build                                    # build
./.build/debug/Dikta sysinfo                   # verify whisper + Metal
./.build/debug/Dikta transcribe file.wav --language he
./.build/debug/Dikta detect file.wav           # language detection only
./.build/debug/Dikta video file.mov --language he --summarize
make bundle && make install                    # package + install
```

Generating test audio:

```bash
say -v Carmit "שלום עולם" -o test.wav --data-format=LEI16@16000
```

### Structure

| File | Role |
|---|---|
| `HotkeyManager.swift` | CGEventTap — captures and swallows the global shortcut |
| `AudioRecorder.swift` | AVAudioEngine → 16kHz mono Float32 |
| `Transcriber.swift` | whisper.cpp (actor); model cache + idle unloading |
| `FocusInspector.swift` | AX API — is focus in a text field |
| `OutputRouter.swift` | Injection (pasteboard + ⌘V) or copy to clipboard |
| `ModelManager.swift` | Model registry, download and storage |
| `LiveRecorder.swift` | ScreenCaptureKit stream — 1fps frames + system audio |
| `DisplayNumberOverlay.swift` | Numbered cards drawn on every monitor while the display picker is open |
| `SceneCollector.swift` | dHash slide detection + async PNG writes |
| `VideoFileProcessor.swift` | Same pipeline for existing video files |
| `MarkdownExporter.swift` | Slide/transcript alignment → index.md |
| `ClaudeSummarizer.swift` | Messages API (Haiku vision) → summary.md |
| `ClaudeCLISummarizer.swift` | Local `claude -p` (subscription) → summary.md |
| `scripts/bundle.sh` | Assembles and signs the `.app` — without Xcode |

## License

[MIT](LICENSE)

## Credits

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — the transcription engine
- [OpenAI Whisper](https://github.com/openai/whisper) — the models
- [ivrit.ai](https://www.ivrit.ai) — the Hebrew fine-tune
