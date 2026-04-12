# Whispur

Open-source macOS dictation tool with multi-provider STT and LLM-powered transcription cleanup. Bring your own API keys.

Use a hold shortcut to speak, or an optional toggle shortcut to start and stop recording. Whispur then transcribes, cleans up, and pastes text into your active app.

## How It Works

```
Shortcut → Record audio → STT transcription → LLM cleanup → Paste text
```

Raw speech-to-text output is noisy — filler words, missed punctuation, misheard terms. Whispur pipes the raw transcript through an LLM that cleans it up: fixes errors, adds punctuation, handles self-corrections, and preserves technical terms. You get polished text pasted directly where your cursor is.

## Supported Providers

### Speech-to-Text
| Provider | Model | Notes |
|----------|-------|-------|
| OpenAI | Whisper | Most widely used |
| Deepgram | Nova 3 | Fast, accurate |
| ElevenLabs | Scribe v1 | Multi-language |
| AWS Bedrock | Various | Enterprise AWS integration |
| Apple | On-device | Free, offline, lower accuracy |

### LLM Cleanup
| Provider | Model | Notes |
|----------|-------|-------|
| Anthropic | Claude Sonnet | High quality cleanup |
| OpenAI | GPT-4o-mini | Fast, cheap |
| Groq | Llama 3.3 70B | Very fast inference |
| AWS Bedrock | Various | Enterprise AWS integration |

Mix and match — use Deepgram for STT and Claude for cleanup, or OpenAI for both, or Groq for everything. Your keys, your choice.

## Requirements

- macOS 14 (Sonoma) or later
- Microphone access
- Accessibility permission (for pasting text)
- At least one STT provider API key (or use Apple on-device)

## Install

### From Source

```bash
# Clone
git clone https://github.com/sophiie-ai/whispur.git
cd whispur

# Generate Xcode project (requires xcodegen)
brew install xcodegen
make generate

# Build
make all

# Run
make run
```

### From DMG

Download the latest release from [Releases](https://github.com/sophiie-ai/whispur/releases).

## Setup

1. Launch Whispur — it lives in your menu bar
2. Open Settings (click menu bar icon → Settings)
3. Start with the **Setup** tab, then go to **Providers**
4. Enter your API keys for at least one STT provider
5. Enter an API key for at least one LLM provider
6. Select your preferred providers from the dropdowns
7. Grant microphone and accessibility permissions when prompted
8. Review your hold and toggle shortcuts in **General**

## Usage

- **Hold to talk**: Press and hold your hold shortcut to record, then release to transcribe and paste.
- **Toggle**: Press your toggle shortcut once to start, then again to stop.
- The cleaned text is pasted wherever your cursor is.
- Check **Activity** in Settings to review raw vs. cleaned transcriptions.

### Customization

- **Custom prompts**: Modify the LLM cleanup behavior in Settings → Prompts
- **Custom vocabulary**: Add terms that should be preserved exactly (product names, technical terms)
- **Deep context**: Enable to capture your current app context for smarter cleanup

## Architecture

```
Sources/
├── App/          # SwiftUI app lifecycle, state management
├── Audio/        # AVAudioEngine recording, normalization
├── Providers/
│   ├── STT/      # Speech-to-text provider protocol + implementations
│   └── LLM/      # LLM provider protocol + implementations
├── Pipeline/     # Orchestration: record → transcribe → clean → paste
├── Input/        # Global hotkey (CGEventTap), text injection
├── Security/     # Keychain API key storage
└── UI/           # Menu bar, settings, recording overlay
```

### Adding a New Provider

1. Create a new file in `Sources/Providers/STT/` or `Sources/Providers/LLM/`
2. Implement the `STTProvider` or `LLMProvider` protocol
3. Add a case to the provider ID enum
4. Register in `ProviderRegistry.swift`

## Contributing

Contributions welcome. Please open an issue first to discuss what you'd like to change.

## License

[MIT](LICENSE)
