# Whispur vs Apple Dictation

By the Whispur team at Sophiie AI · 24 November 2026

Every Mac already has Dictation built in. It is free, needs nothing installed, and works well for short messages. So why install a separate app? This page sets out what Apple Dictation does, what Whispur adds, and when the built-in feature is all you need.

We make Whispur. Apple Dictation facts below come from Apple's own support and privacy pages, checked on 24 November 2026.

## The verdict

Use **Apple Dictation** if you dictate occasionally, want zero setup, and are happy with Apple's engine and formatting. Choose **Whispur** if you dictate a lot and want a choice of speech engines, AI cleanup you can control, custom vocabulary, per-app styles, push-to-talk, and a record of every dictation. Both are free.

## At a glance

| | Whispur | Apple Dictation |
| --- | --- | --- |
| Price | Free and open source (MIT). Cloud providers, if you use them, bill you directly | Free, built into macOS |
| Setup | Download, allow Microphone and Accessibility access | Turn on in System Settings > Keyboard > Dictation |
| How you start it | Hold Fn to talk and release to paste; Command + Fn hands-free; Esc cancels | Microphone key, a Dictation shortcut you choose, or Edit > Start Dictation |
| Speech engines | NVIDIA Parakeet on your Mac, Apple speech recognition, or six cloud engines with your own key | Apple's |
| Where audio is processed | On your Mac with Parakeet; Apple speech recognition as macOS decides; cloud engines you choose | Keyboard settings show whether dictation is processed on your device; otherwise it is sent to and processed by Apple |
| Punctuation | AI cleanup, optional, plus spoken punctuation | Automatic commas, periods and question marks in supported languages; spoken punctuation |
| Custom vocabulary | Dictionary with "heard as" spellings | Not described in Apple's Dictation guide |
| Per-app styles | Yes | Not described in Apple's Dictation guide |
| Choice of engine or AI prompt | Yes | Not described in Apple's Dictation guide |
| History of dictations | Activity tab with raw and cleaned text, and retry for failed dictations | Not described in Apple's Dictation guide |
| Open source | Yes | No |

## What Apple Dictation does well

- **It is already there.** No download, no permissions beyond turning it on.
- **It is free and private by default on supported setups.** Apple says your device shows in Keyboard settings whether dictation is processed on device. Apple does not store your audio unless you opt in to Improve Siri and Dictation.
- **It handles long dictation.** Apple's guide says you can dictate text of any length without a timeout. It stops automatically after 30 seconds of silence.
- **It punctuates for you.** In supported languages it inserts commas, periods and question marks as you speak, and you can say "new line" or name a punctuation mark.
- **It is improving.** Apple says that with Apple Intelligence in macOS 27, dictation uses an on-device model to improve spelling, punctuation and capitalization, in English on Macs with M3 or later and at least 12 GB of unified memory.

## What Whispur adds

- **Push-to-talk.** Hold Fn to talk and let go to paste, which avoids the start and stop of a toggle for short dictations. Command + Fn records hands-free for longer ones.
- **A choice of engines.** Run NVIDIA Parakeet on your Mac's Neural Engine with no key, or bring your own key for OpenAI, Groq, Deepgram, ElevenLabs, Mistral or Meta Muse. Read the [engine guide](https://whispur.app/blog/whisper-vs-scribe-vs-nova-3) for the trade-offs.
- **AI cleanup you control.** Optionally pass each transcript through Claude, OpenAI, Groq, Cerebras or AWS Bedrock with your own key, to fix punctuation and misheard words. Edit the cleanup prompt, set a custom model, or switch cleanup off to paste exactly what the engine heard.
- **Your own words.** Add names and jargon in the Dictionary, with the ways they get misheard. Engines that accept vocabulary receive it directly.
- **Different styles per app.** Casual in Slack, Formal in Mail, Code-aware in your editor and terminal. See [dictating code and prompts](https://whispur.app/blog/dictating-code-and-prompts).
- **Text fixes for technical writing.** Spoken symbols ("dash dash force" becomes `--force`), filler words removed, and "scratch that" to delete the last sentence.
- **A record.** The Activity tab shows raw and cleaned text for recent dictations, and a failed dictation keeps its recording on your Mac for 24 hours so you can retry it.

## How Whispur uses Apple's engine

Whispur can use Apple's speech recognition as one of its engines. It is the default on Intel Macs, and on Apple silicon it fills in while the Parakeet model downloads. On macOS 26 and later Whispur uses Apple's newer SpeechAnalyzer model. So you are not choosing between Apple's speech technology and Whispur: Whispur can run on top of it, and add the shortcut, cleanup, vocabulary and history around it.

If you want a firm guarantee that audio stays on your Mac, use Parakeet, which Whispur runs on the Mac itself. Read more in [offline dictation on a Mac](https://whispur.app/blog/offline-dictation-mac).

## Frequently asked questions

### Is Apple Dictation good enough?

For short, occasional dictation, often yes. It is free, built in and needs no setup. People who dictate for long stretches, use specialist vocabulary, or want different formatting in different apps tend to want more control than it offers.

### Does Apple Dictation send audio to Apple?

Apple says your Mac shows in Keyboard settings whether what you say is processed on your device. If it is not, it is sent to and processed by Apple. Apple does not store your audio unless you opt in to Improve Siri and Dictation.

### Can I use Whispur and Apple Dictation together?

Yes. They use different shortcuts. Whispur defaults to holding Fn; if your Fn key is set to start Apple Dictation, change one of them. To use Fn twice in Whispur, set "Press 🌐 key to" to Do Nothing in System Settings > Keyboard first.

### Does Whispur cost anything?

No. Whispur is free and MIT licensed. Its local engines cost nothing to run. If you choose a cloud engine or AI cleanup, that provider bills your own account.

## Try Whispur

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg), drag it to Applications and hold Fn to talk. It needs macOS 14 or later, and the current release build runs on Apple silicon. See all [comparisons](https://whispur.app/compare) or read [the best Mac dictation apps in 2026](https://whispur.app/blog/best-mac-dictation-apps).

## Sources, checked 24 November 2026

- [Apple: Use Dictation on Mac](https://support.apple.com/guide/mac-help/use-dictation-mh40584/mac)
- [Apple: Ask Siri, Dictation and privacy](https://www.apple.com/legal/privacy/data/en/ask-siri-dictation/)
- Whispur facts: [README](https://github.com/sophiie-ai/whispur#readme), [privacy](https://whispur.app/privacy) and [llms-full.txt](https://whispur.app/llms-full.txt)
