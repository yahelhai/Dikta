# Changelog

Every released version and exactly what went into it. Versions follow
[semantic versioning](https://semver.org): the major changes on a break, the
minor on new capability, the patch on fixes alone.

## [1.3] — 2026-08-12

Screen-recording quality of life: choosing *which* screen and *where the
recording lands* both stop being guesswork.

### Added

- **Numbered cards on every screen.** Opening the **🖥 הקלט מסך** submenu draws a
  large numbered card in the middle of each connected monitor, matching the
  numbers in the menu rows; hovering a row highlights that monitor's card. Until
  now the number was just the index in `SCShareableContent.displays` — not a
  macOS display number — so on a multi-monitor setup there was no way to tell
  which "מסך 2" was which except by guessing from the resolution. The cards are
  torn down when the menu closes, so they never land in a recording.
- **The recording location is asked for up front**, before capture starts,
  instead of being decided silently after the fact.

### Fixed

- **Resolutions rendered backwards in the display picker.** The Hebrew "(ראשי)"
  made the label right-to-left, and bidi reordered the two number runs around
  the "×" — a 3456×2234 display read as "2234×3456". The resolution is now
  wrapped in a Unicode isolate.
- **No passive Keychain reads.** Opening the menu no longer touches the
  Keychain, so macOS stops prompting for access when none is needed.

### Documentation

- **README rewritten around a complete CLI reference:** every subcommand, every
  flag with its default, the value aliases, the stdout/stderr split, and one
  exit-code table — all verified against the binary. `sysinfo`, `transcribe
  --model` and the `record-test` flags had never been documented at all, and
  none of the examples mentioned that nothing puts `dikta` on `PATH`.
- The permissions table said "three permissions" and listed four; the structure
  table covered 16 of the 25 sources and now covers all of them.

### Housekeeping

- `CFBundleShortVersionString` had drifted — it still read `1.0` at v1.2 — and
  is now kept in step with the tag.
- This changelog, and releases from here on going through pull requests.

## [1.2] — 2026-08-09

### Changed

- **The Claude Code CLI is the default summary engine**, billed to your Claude
  subscription rather than API credits. The Anthropic API key becomes the
  opt-in alternative, and the summary toggle stays disabled until the
  *selected* engine is actually usable.

## [1.1] — 2026-08-09

The lecture-capture release.

### Added

- **Live screen recording → Markdown.** Records a chosen display plus system
  audio, detects slide changes as they happen by perceptual hashing, and writes
  `index.md`: every slide's screenshot with the transcript spoken over it.
  Frames and audio are processed as they stream — **no video file is ever
  written**.
- **`dikta video`** — the same pipeline for video files that already exist.
- **Optional Claude summary** (Haiku vision) → `summary.md`: per-slide
  summaries, side topics, and action recaps for live coding segments.
- **Automatic trailing space** after a transcript, as a menu toggle.
- MIT license, and an English README.

### Changed

- A bare `transcribe`/`detect` prints its usage instead of launching the
  menu-bar app.
- Removed the unlabeled last-transcript menu item.

## [1.0] — 2026-07-09

First release: local Hebrew/English push-to-talk dictation as a menu-bar app.
Hold a shortcut, speak, release — the transcript is typed into the focused text
field, or copied to the clipboard when there is nowhere to type. whisper.cpp on
Metal, with optional routing of Hebrew to the ivrit.ai fine-tune. Nothing leaves
the machine.

[1.3]: https://github.com/yahelhai/Dikta/compare/v1.2...v1.3
[1.2]: https://github.com/yahelhai/Dikta/compare/v1.1...v1.2
[1.1]: https://github.com/yahelhai/Dikta/compare/v1.0...v1.1
[1.0]: https://github.com/yahelhai/Dikta/releases/tag/v1.0
