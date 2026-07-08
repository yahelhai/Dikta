<div align="center">
<img src="Resources/AppIcon.svg" width="128" alt="Dikta icon"/>

# Dikta

**Local voice dictation for macOS — Hebrew & English, no cloud, no subscription**

Push-to-talk dictation powered by whisper.cpp. Hold a key, speak, release — the text appears.
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

## Requirements

- macOS 14+ on Apple Silicon
- Xcode Command Line Tools only (`xcode-select --install`) — **no Xcode needed**
- ~600MB of disk for the base model (+1.6GB for the optional Hebrew model)

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

After granting Input Monitoring, quit and relaunch Dikta.

## Usage

1. Hold **Right Option**, speak, release
2. **Change the shortcut:** menu → "Shortcut: … — change…" → press the combo you want
3. **Better Hebrew:** menu → "Download improved Hebrew model (ivrit.ai)…" — once downloaded, Auto mode routes every Hebrew dictation to it automatically
4. **Language modes:** Auto (detection) / English / Hebrew

## Development

```bash
swift build                                    # build
./.build/debug/Dikta sysinfo                   # verify whisper + Metal
./.build/debug/Dikta transcribe file.wav --language he
./.build/debug/Dikta detect file.wav           # language detection only
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
| `scripts/bundle.sh` | Assembles and signs the `.app` — without Xcode |

## Credits

- [whisper.cpp](https://github.com/ggml-org/whisper.cpp) — the transcription engine
- [OpenAI Whisper](https://github.com/openai/whisper) — the models
- [ivrit.ai](https://www.ivrit.ai) — the Hebrew fine-tune
