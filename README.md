# Whispur

Whispur is a macOS menu-bar dictation app that turns speech into polished text and drops it straight back into the app you are already using.

Hold a shortcut to talk, or use an optional toggle shortcut for hands-free capture. Whispur records, transcribes, optionally cleans up the transcript with an LLM, and pastes the result where your cursor is.

![Whispur demo — hold a shortcut, speak, and paste into any app](docs/screenshots/demo.gif)

> [whispur.app](https://whispur.app) · [Download DMG](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg) · [Changelog](https://whispur.app/changelog)

## Screenshots

| Menu bar | Recording overlay |
|---|---|
| ![Menu bar dropdown](docs/screenshots/hero-menubar.png) | ![Recording overlay with waveform](docs/screenshots/recording-overlay.png) |

| Setup checklist | Provider settings |
|---|---|
| ![Setup tab](docs/screenshots/settings-setup.png) | ![Providers tab](docs/screenshots/settings-providers.png) |

## Features

- Lives in the macOS menu bar instead of taking over your desktop
- Hold-to-talk or toggle-to-latch recording
- Multi-provider speech-to-text with on-device Apple and NVIDIA Parakeet options
- Optional transcript cleanup with provider-selectable LLMs; switch off `Clean up with AI` (`Settings` → `Providers`, or the cleanup chip in the menu bar) to paste exactly what the speech engine heard, with no LLM request
- Paste-back into the active app with clipboard preservation
- Text fixes made on your Mac with no AI, cleanup on or off (`Settings` → `Preferences` → `Text fixes`): filler words removed, spoken symbols ("hashtag release" → `#release`, "dash dash force" → `--force`) and spoken quotes ("quote … end quote") written as characters, and a leading space added when the cursor sits right after a word
- Custom vocabulary and a single editable cleanup prompt for technical dictation; each Dictionary term can list how it gets misheard ("heard as"): clear-cut misspellings are fixed in code, ordinary words ("Whisper", "Sophie") are left to cleanup unless you turn on "Always replace", and Activity's "Add word" fills one in from a dictation
- Local-first by default: with no cloud speech key, Whispur uses NVIDIA Parakeet on Apple silicon (Apple on-device on Intel Macs), and Apple on-device transcribes while Parakeet's model downloads in the background
- Sparkle-based auto-updates for signed releases

## Install

### DMG download

Download the latest signed DMG from [GitHub Releases](https://github.com/sophiie-ai/whispur/releases).

### Homebrew cask

Homebrew installation is planned but not published yet.

### Build from source

```bash
git clone https://github.com/sophiie-ai/whispur.git
cd whispur
brew install xcodegen create-dmg
make all
make run
```

## Setup

1. Open Whispur. If it isn't in your Applications folder yet (say it's still on the DMG or in Downloads), it offers to move itself there and relaunches.
2. A short welcome window walks you through first run. On Apple silicon without a cloud speech key it first asks which languages you speak and starts downloading the on-device speech model, with its progress pinned at the top of every later screen. Then: microphone access, Accessibility access (a guide docks beside System Settings so you can drag Whispur into the list), and your dictation shortcut, then lets you try a dictation right in the window. Each permission step moves on by itself once it's granted.
3. That's it: dictation works with no API keys. On Apple silicon Whispur transcribes on-device with NVIDIA Parakeet (Apple's on-device recognition fills in while Parakeet's model downloads); on Intel Macs it uses Apple's on-device recognition.
4. Optional: in `Settings`, add API keys for a cloud speech provider, or an LLM provider for transcript cleanup. Setup, shortcuts and providers all stay available there, and you can skip the welcome window and finish setup later.

If macOS switches Accessibility on but Whispur's shortcut still can't listen (this can happen after an earlier denial or an older Whispur entry), the welcome window and `Settings` → `Get Started` offer `Restart Whispur`; setup reopens after the restart where it left off.

To walk through the welcome window again, choose `Run Setup Again` in `Settings` → `Get Started` (or `Run Setup` on the menu bar's Setup Guide card). From a terminal, `open -a Whispur --args --reset-onboarding` does the same. Neither clears your settings or permissions; `defaults delete ai.sophiie.whispur whispur.onboarding.completed` makes the next launch behave like a first run.

## Usage

- Hold shortcut: Press and hold your configured shortcut to record, then release to transcribe and paste.
- Toggle shortcut: By default, press Command + Fn to start hands-free recording and press it again to stop and process. You can also pick Fn twice (press Fn twice to start, once to stop); set "Press 🌐 key to" to Do Nothing in System Settings > Keyboard so macOS doesn't open the Emoji & Symbols panel.
- Live words: With "Stream audio while you talk" on (ElevenLabs Scribe and Meta Muse), the recording overlay shows the words heard so far: the last two lines under the standard overlay, or one line beside the compact pill's waveform.
- Use raw: When cleanup changed your words, a small "Cleaned up · Use raw ⌥⌘Z" toast shows for 4 seconds after the paste. Press ⌥⌘Z (or click it) to swap the pasted text for exactly what you said. It works only in the app you dictated into and only until you type something else; turn it off in `Settings` → `Preferences`.
- Activity log: Open `Settings` → `Activity` to inspect raw and cleaned transcripts. A failed dictation keeps its recording for 24 hours so you can retry it; the retried text is copied to the clipboard. A dictation that looks wrong (10 seconds or more of audio that produced very little text or no speech at all, a cleanup that rewrote most of the words, or a speech provider that had to fall back) is marked `Looks wrong` and keeps its recording on this Mac for 24 hours the same way, so you can play it or transcribe it again. Failed and flagged dictations are kept past the usual 25-entry limit, up to 10 of them, along with their entries in `Requests`. Each dictation also shows a one-line diagnostics summary (recording length and levels, which providers ran and how long they took, transcript lengths, how much cleanup changed); `Copy diagnostics` copies it as JSON for a bug report.
- Mark as wrong: In `Settings` → `Activity`, expand a dictation and choose `Mark as wrong` (or right-click it). Fix what it should have said, tag it if you like, and Whispur appends one line to `~/Library/Application Support/Whispur/MyEvalCases.jsonl`. The file stays on your Mac; `Reveal file` in Activity opens it in Finder. Each line uses the same fields as `Evals/cleanup/cases.jsonl` with `"split": "mine"`, so you can score the cleanup prompt against your own dictations with the eval runner's `--cases-file` flag:

  ```bash
  python3 scripts/eval-cleanup.py --provider openai --prompt new \
    --cases-file ~/Library/Application\ Support/Whispur/MyEvalCases.jsonl
  ```
- Prompt tuning: Open `Settings` → `Prompts` to override the cleanup prompt or add domain vocabulary.
- Cleanup model: Open `Settings` → `Providers` and set `Custom Model` on any cleanup provider to use a model other than the default.

## Provider Matrix

### Speech-to-text

| Provider | Status | Notes |
| --- | --- | --- |
| Apple Speech Recognition | Available | On-device and local. Uses SpeechAnalyzer on macOS 26 and later. The default on Intel Macs, and the fallback while Parakeet's model downloads |
| Parakeet (on this Mac) | Available | NVIDIA Parakeet (Parakeet Ultra, 25 European languages) on the Neural Engine via [FluidAudio](https://github.com/FluidInference/FluidAudio). No key; a one-time ~630 MB model download to `~/Library/Application Support/Whispur/Models`. Model weights: CC BY 4.0. The default on Apple silicon for anyone who hasn't picked a provider and has no cloud speech key: the model downloads in the background on first launch (it waits out metered and Low Data Mode networks) and Whispur switches to it by itself once it's ready |
| OpenAI | Available | GPT Transcribe (default) or Whisper, via API key |
| Groq Whisper | Available | Whisper Large v3 or v3 Turbo, via API key |
| Deepgram | Available | Cloud STT via API key |
| ElevenLabs Scribe | Available | Cloud STT via API key. Optional live streaming while you talk |
| Mistral Voxtral | Available | Voxtral Mini or Small Transcribe 3, via API key |
| Meta Muse | Available | Muse Voice Transcribe via a Meta Model API key. Optional live streaming while you talk |

### Transcript cleanup

| Provider | Status | Notes |
| --- | --- | --- |
| Anthropic Claude | Available | High-quality cleanup |
| OpenAI | Available | Fast cleanup path |
| Groq | Available | OpenAI-compatible endpoint |
| Cerebras | Available | OpenAI-compatible endpoint; defaults to `qwen-3.8-27b` with reasoning off. `gpt-oss-120b` runs at low reasoning effort, with reasoning text hidden |
| AWS Bedrock | Available | Claude via Bedrock, authenticated with a Bedrock API key (`AWS_BEARER_TOKEN_BEDROCK`) |

## Privacy

Audio stays local by default when you use the built-in Apple speech provider, and with Parakeet, which runs on this Mac once its model is downloaded. If you switch to a cloud STT or LLM provider, the audio or transcript needed for that provider is sent only to the services you configure.

Whispur stores API keys in the macOS Keychain.

For each recent dictation, Whispur keeps diagnostics on this Mac in `~/Library/Application Support/Whispur/dictation-diagnostics.json`: numbers such as recording length, input levels, timings, transcript lengths and the providers used, plus the error when one happened. They never contain audio or transcript text. Clear History in Activity deletes them.

Recordings are not kept, with two exceptions: a failed dictation, and one that looks wrong (see Activity log above). Their normalized recording stays in `~/Library/Application Support/Whispur/FailedAudio/`, readable only by your user, excluded from Time Machine and iCloud backups, and deleted after 24 hours.

The Insights page is worked out on this Mac from counts only: words per day, how often you use words that aren't everyday words, dictations per weekday and hour, dictations per app, and how often you fix a word. No transcripts are kept for it, and nothing is sent anywhere. Clear Insights resets those counts.

## Development

```bash
make generate
make all
make dmg
```

Key project areas:

- `Sources/App`: app lifecycle, menu-bar scenes, state
- `Sources/Audio`: recording and normalization
- `Sources/Providers`: STT and LLM integrations
- `Sources/Pipeline`: dictation orchestration
- `Sources/Input`: shortcuts and paste-back
- `Sources/UI`: menu bar, onboarding, settings, about window

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Whispur is released under the [MIT License](LICENSE).
