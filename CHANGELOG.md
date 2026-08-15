# Changelog

Every released version and exactly what went into it. Versions follow
[semantic versioning](https://semver.org): the major changes on a break, the
minor on new capability, the patch on fixes alone.

## [1.4] — 2026-08-13

Transcription now happens while the recording is still going, and sped-up
playback no longer quietly produces an empty transcript.

Measured on a real 80-minute lecture, the old pipeline spent **251 seconds**
transcribing after capture stopped. The same stage now takes **under 3
seconds**, because only the final chunk is left to do.

### Added

- **Transcription during the recording.** Audio is written in ~2 minute
  chunks; each one is transcribed and deleted as it closes, and the segments
  are appended and flushed to `<session>/.dikta-work/transcript.jsonl` as they
  are produced. The wait after `stop` is one chunk long whatever the length of
  the lecture, and peak memory for audio drops from ~310MB for an 80-minute
  recording to ~7.7MB — one chunk — regardless of length. `--chunk-seconds`
  tunes it.
- **Sped-up playback is detected and corrected.** Recording a lecture at 1.5x
  is the point of the CLI flow, but whisper is trained on ordinary speech and
  collapses on the result: two minutes of clean, loud narration (RMS 0.108,
  peak 0.91) came back as "Thank you." four times, and transcribed word for
  word the moment it was slowed to real time. When loud audio produces almost
  no text — a combination that does not occur naturally, since real silence is
  quiet — the chunk is re-read at 1.5x, 2x, 1.25x and 3x and the best result
  wins. The answer is reused for the rest of the recording, so the search runs
  at most once, and only after something already looked wrong. `--speed <rate>`
  states it outright and skips the check.
- **`--keep-audio`** keeps the captured chunks in `<session>/audio/` instead of
  deleting them once transcribed, for a recording that may be re-transcribed
  with a different model.
- **Crash resilience.** Frame timestamps are written to `frames.jsonl` as each
  PNG lands, and the transcript is flushed chunk by chunk. Both used to exist
  only in memory, so a crash in the last minute of a lecture threw away the
  whole lecture — the audio lived in a temporary file that nothing had read
  yet. Finishing an interrupted session automatically is not in this release;
  what survives has to be assembled by hand for now.

### Changed

- **The summary covers the whole recording, not its first 60 slides.** Both
  engines cut the slide list at a fixed 60 and asked the model to note that the
  rest was missing, so a long lecture was summarized from its opening alone.
  The CLI engine now sends every slide — it reads the PNGs off disk with its own
  Read tool, so a count was never its constraint, only an inherited one — and
  the API engine packs slides until the encoded body approaches the 32MB request
  limit, which is the limit that actually exists. The CLI timeout rises from 15
  to 45 minutes to cover the extra reading.

### Fixed

- **Chunk seams no longer strand half a sentence.** Cutting on a quiet moment
  keeps most seams off a word, but not all: a real capture split "If a claim
  isn't / backed by a real source, it stays flagged" and whisper finished the
  stranded half by inventing "it's the only thing that you can do". Each chunk
  now carries the last six seconds of the previous one, so the boundary is read
  with the audio that follows it, and the fragment is written once, whole.
- **The frame writer had no back pressure.** Every captured frame was queued
  for PNG encoding holding a full-size `CGImage` — ~31MB at 3456×2234 — with no
  limit on how many could pile up. At most two are now in flight.

### Known

Muting the Mac's output silences the captured audio as well: the recording
keeps its picture and loses every word. The volume *level* has no effect —
audio captured at volume 6 measures the same as at volume 60. This is
ScreenCaptureKit's behaviour, not something Dikta can override, so it is
documented in the README rather than worked around.

## [1.3.1] — 2026-08-12

Three fixes to things that were supposed to work and did not, all in the menu
bar.

### Fixed

- **The recording icon was never actually red.** `contentTintColor` paints
  template images only, and the code turned the template off for exactly the
  states it then tried to tint — so the icon rendered in its own monochrome,
  i.e. black on a dark menu bar. Worse, a template image that *does* carry a
  tint renders as nothing at all on current macOS, so the obvious one-line fix
  made it invisible. The colour now comes from a palette symbol configuration,
  which was verified against a standalone status item rather than assumed.
  Idle is now the only state without a colour, so "Dikta is doing something" is
  legible at a glance: orange while it is listening to you, red while it is
  capturing the screen.
- **Dictating during a screen recording hid the recording icon for good.** The
  comment claimed the red circle won, but the guard only ran on the stop path:
  dictation overwrote the icon, left it at `mic`, and the restore then declined
  to fire. Precedence is now a pure function — dictation takes over while it is
  happening and hands the icon back when it finishes.
- **The menu bar could start a second recording on top of a `dikta record`.**
  The CLI has refused in the other direction since it shipped, but the app only
  ever *wrote* to the run registry and never read it, so both recorders could
  capture the same screen at once, each unaware of the other. The menu now shows
  a CLI recording in place of the display picker, and refuses with an alert if
  one is somehow started anyway. Both refusals share one predicate so they
  cannot drift apart.

Stopping a CLI recording from the menu is deliberately still not possible —
that would be a new capability, not a fix. `dikta stop` owns it.

## [1.3] — 2026-08-12

Screen-recording quality of life: choosing *which* screen and *where the
recording lands* both stop being guesswork.

### Added

- **Screen recording from the command line** — `dikta displays`, `record`, `stop`
  and `status`. The same capture, slide detection and Claude summary the menu
  performs, for content that can only be *played* and therefore has to be
  recorded off the screen. `record` returns as soon as capture is genuinely
  live and detaches into its own session, so it survives the shell that started
  it; `stop` works from any later shell and prints the paths it produced.
  `displays` numbers screens exactly as the on-screen cards do, and
  `displays --identify` flashes those cards on every monitor on demand — so a
  script can identify a screen without opening the menu, which on a desk of
  identical monitors is the difference between picking one and guessing.
  New exit codes: `5` nothing recording, `6` already recording, `7` stopped but
  processing outlasted the wait.
- **Only one recording at a time.** The menu bar app and the CLI now see each
  other, so a second recording is refused instead of quietly capturing the same
  screen twice.
- **The display is kept awake while recording** — a screen that sleeps
  mid-lecture was the likeliest way an unattended run produced blank frames.
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

- **The project has tests.** Everything moved into a `DiktaCore` library so it
  could be tested at all, leaving `main.swift` a thin shell. `make test` runs
  the unit suite; `make test-integration` drives the real binary through a
  record/stop cycle. The runner is an ordinary executable target rather than
  `swift test`: XCTest ships only with Xcode, and the `Testing.framework` in the
  Command Line Tools is missing `lib_TestingInterop.dylib`, so `swift test`
  builds and then dies at `dlopen` — and Dikta's stated requirement is Command
  Line Tools only.
- Settings now read the `com.yahel.dikta` domain explicitly. `.standard` keys off
  the bundle identifier, which a bare SwiftPM binary does not have, so
  `.build/debug/Dikta` was silently reading different preferences from the app.
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

[1.4]: https://github.com/yahelhai/Dikta/compare/v1.3.1...v1.4
[1.3.1]: https://github.com/yahelhai/Dikta/compare/v1.3...v1.3.1
[1.3]: https://github.com/yahelhai/Dikta/compare/v1.2...v1.3
[1.2]: https://github.com/yahelhai/Dikta/compare/v1.1...v1.2
[1.1]: https://github.com/yahelhai/Dikta/compare/v1.0...v1.1
[1.0]: https://github.com/yahelhai/Dikta/releases/tag/v1.0
