# Whisper vs Scribe vs Nova-3: choosing a speech engine for dictation

By the Whispur team at Sophiie AI · 24 November 2026

Most dictation apps pick a speech engine for you. Whispur lets you choose from eight: two that run on your Mac with no key, and six cloud engines you use with your own API key. That choice is useful, but it raises a fair question. Which one should you use?

This guide walks through the trade-offs that matter for dictation, as opposed to transcribing long recordings: how quickly text appears, how you pay, whether the engine streams, how it handles languages, and whether it accepts your custom vocabulary. It ends with how to switch engines in Whispur. We do not publish accuracy benchmarks here, because accuracy depends heavily on your voice, microphone, language and vocabulary. The best test is your own: try two engines for a day each and use the Activity tab to compare.

## The engines Whispur supports

| Engine | Where it runs | Models in Whispur | Vocabulary | Streaming |
| --- | --- | --- | --- | --- |
| NVIDIA Parakeet | Your Mac (Neural Engine) | Parakeet Ultra, 25 European languages | Not passed to the engine; used by cleanup | No |
| Apple speech recognition | Built into macOS | SpeechAnalyzer on macOS 26 and later | Contextual hints | No |
| OpenAI | Cloud, your key | gpt-transcribe (default), whisper-1 until February 2027, or any OpenAI-compatible endpoint | Keywords (gpt-transcribe) or prompt (whisper-1) | No |
| Groq | Cloud, your key | Whisper Large v3 (default) or v3 Turbo | Prompt | No |
| Deepgram | Cloud, your key | Nova-3 | Key terms | No |
| ElevenLabs | Cloud, your key | Scribe v3 (default) or Scribe v2 | Key terms | Optional |
| Mistral | Cloud, your key | Voxtral Mini Transcribe 3 (default) or Voxtral Small Transcribe 3 | Context bias | No |
| Meta Muse | Cloud, your key | Muse Voice Transcribe | Keywords | Optional |

"Streaming" means Whispur sends audio while you talk and shows the words heard so far in the recording overlay. Every other engine works in batch: Whispur sends the recording when you let go of the shortcut.

## Latency: what you actually feel

For dictation, the delay that matters is the gap between letting go of the shortcut and seeing your text. That gap has up to three parts: uploading the audio, the engine's processing time, and the optional AI cleanup step.

A few things in Whispur shorten it regardless of engine:

- Audio is converted to 16 kHz mono before it is sent, and providers that accept FLAC (OpenAI, Groq, Deepgram, ElevenLabs and Mistral) get it compressed as FLAC. Meta Muse takes WAV.
- Local engines skip the upload entirely.
- Switching off "Clean up with AI" removes the cleanup round trip. Whispur then pastes what the engine heard, after its local text fixes.

Streaming engines change how the wait feels. With ElevenLabs Scribe or Meta Muse and "Stream audio while you talk" turned on, you see words in the overlay as you speak, and the engine has already heard most of the audio by the time you let go. Streaming is opt-in. If a stream fails, Whispur falls back to sending the full recording in batch, so you do not lose the dictation.

Groq is worth a mention here. Groq publishes a "speed factor" for its Whisper models: as of November 2026 its docs list 189 for Whisper Large v3 and 216 for v3 Turbo. That is Groq's own figure for how much faster than real time the model runs.

We do not quote end-to-end latency numbers for each engine. They vary with your network, region and recording length, and a number measured on our machines would not tell you much about yours. The Requests tab in Whispur shows the timing of every provider call, so you can measure your own.

## Cost: how each engine bills

Whispur is free and never charges for transcription. Cloud engines bill you directly, on your own account, for what you use. The local engines cost nothing to run.

The cost models differ:

- **Parakeet and Apple speech recognition:** free. Parakeet needs a one-time model download of about 630 MB.
- **Deepgram:** billed per second of audio. As of November 2026, Deepgram's pricing page lists Nova-3 pre-recorded audio at $0.0043 per minute for monolingual and $0.0052 per minute for multilingual on pay-as-you-go, and offers a $200 free credit to start.
- **Groq:** billed per hour of audio transcribed. As of November 2026, Groq's docs list Whisper Large v3 at $0.111 per hour and Whisper Large v3 Turbo at $0.04 per hour.
- **ElevenLabs:** billed per hour of audio, with rates that vary by plan and model. Its docs note that key term prompting costs extra and that silence counts toward billed time.
- **OpenAI, Mistral and Meta Muse:** billed by the provider for usage on your own key. Check each provider's pricing page for current rates.

Dictation is short. Most dictations are seconds long, not hours, so for many people the cloud bill is small. But it is your bill, so it is worth checking the provider's pricing page before you commit.

## Languages

Whispur lets you pick the languages you speak in Settings. Several are fine. How Whispur passes them on depends on the engine:

- **Parakeet** covers 25 European languages. If you speak a language it does not cover, pick another engine.
- **Apple speech recognition** works in one language at a time.
- **OpenAI gpt-transcribe** gets every language you picked as a hint. **whisper-1** and **Groq Whisper** take one language, or detect it automatically.
- **Deepgram Nova-3** uses one language when you pick one, and its multilingual mode with a hint per language when you pick several.
- **ElevenLabs Scribe v3** takes your other languages as secondary languages. ElevenLabs says Scribe v3 and v2 support more than 90 languages.
- **Meta Muse** takes your languages as a language bias.

Whispur also runs a guard when you speak several languages: if a result comes back in the wrong writing system, it transcribes again.

## Custom vocabulary and key terms

This is where engines differ most for technical users. Add your terms in Settings > Dictionary, and Whispur sends them to the engine in the form it understands:

- **Deepgram Nova-3** gets them as key terms. Deepgram's docs describe key terms as a way to improve recognition of important terminology, product and company names, with a limit of 500 tokens per request.
- **ElevenLabs Scribe** gets them as key terms. ElevenLabs documents up to 1,000 key terms for batch requests. Whispur sends up to 50.
- **OpenAI gpt-transcribe** gets them as keywords, up to 50.
- **whisper-1 and Groq Whisper** get them as a short comma-separated prompt. Whisper prompts are capped at 224 tokens, so long lists are trimmed.
- **Mistral Voxtral** gets them as context bias.
- **Meta Muse** gets them as keywords.
- **Apple speech recognition** gets them as contextual hints.
- **Parakeet** does not receive them.

Whatever the engine, your Dictionary also reaches the AI cleanup step if you use one, and clear-cut "heard as" misspellings are fixed in code on your Mac. So even Parakeet users benefit from a well-kept Dictionary.

## Privacy

Local engines keep audio on your Mac. Parakeet runs entirely on your Mac once its model is downloaded. Apple speech recognition uses the framework built into macOS, and depending on the Mac and language, macOS may process audio on the device or with Apple's speech service.

Cloud engines receive your audio directly from your Mac, using your API key. There is no Whispur server in between. Each provider's own data policy then applies, so read it if that matters to you. Our guide to [offline dictation on a Mac](https://whispur.app/blog/offline-dictation-mac) covers the local route in detail.

## Which engine should you pick?

Some starting points:

- **You want privacy and no setup:** Parakeet on Apple silicon, which is the default anyway.
- **You are on an Intel Mac:** Apple speech recognition, or any cloud engine.
- **You use a lot of names and jargon:** Deepgram Nova-3, ElevenLabs Scribe or OpenAI gpt-transcribe, which accept your vocabulary directly.
- **You want to see words as you speak:** ElevenLabs Scribe or Meta Muse with streaming on.
- **You want low cost per hour from a cloud engine:** compare Groq's Whisper Turbo and Deepgram's published rates.
- **You speak several languages in one sentence:** try Deepgram's multilingual mode or ElevenLabs Scribe v3 with secondary languages.

## How to switch engines in Whispur

1. Open Settings > Providers.
2. Add the API key for the engine you want. It is stored in the macOS Keychain.
3. Choose that engine as your speech provider. Where Whispur offers a model picker (OpenAI, Groq, ElevenLabs and Mistral), pick the model.
4. For ElevenLabs or Meta Muse, turn on "Stream audio while you talk" if you want live words.
5. Dictate as usual. The Activity tab shows the raw and cleaned text, and the Requests tab shows each call's timing and any error.

If a cloud engine can't be reached, and Parakeet's model is on your Mac and covers your languages, Whispur transcribes that dictation with Parakeet so you do not lose it.

For developers, our guide to [dictating code and prompts](https://whispur.app/blog/dictating-code-and-prompts) shows how vocabulary, the cleanup prompt and per-app styles fit together. To see how Whispur compares with other apps, read [the best Mac dictation apps in 2026](https://whispur.app/blog/best-mac-dictation-apps) or browse the [comparison pages](https://whispur.app/compare).

## Try Whispur

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg) and start with no key on Parakeet. Add a cloud key later if you want to compare engines.

## Sources, checked 24 November 2026

- [Deepgram pricing](https://deepgram.com/pricing)
- [Deepgram key term prompting](https://developers.deepgram.com/docs/keyterm)
- [Groq speech to text docs](https://console.groq.com/docs/speech-to-text)
- [ElevenLabs speech to text docs](https://elevenlabs.io/docs/capabilities/speech-to-text)
- Whispur facts: [README](https://github.com/sophiie-ai/whispur#readme), [changelog](https://whispur.app/changelog) and the provider source code in [Sources/Providers](https://github.com/sophiie-ai/whispur/tree/main/Sources/Providers)
