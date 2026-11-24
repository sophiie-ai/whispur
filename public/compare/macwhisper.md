# Whispur vs MacWhisper

By the Whispur team at Sophiie AI · 24 November 2026

MacWhisper and Whispur are both Mac apps with "Whisper" in their name, and both turn speech into text on your Mac. They are built for different main jobs. MacWhisper's site leads with transcribing audio and video files, and adds meeting recording and system-wide dictation. Whispur does one thing: live, push-to-talk dictation into whatever app you are using.

We make Whispur. MacWhisper facts below come from MacWhisper's own website, checked on 24 November 2026.

## The verdict

Choose **MacWhisper** if you need to transcribe recordings, podcasts, interviews or meetings, with speaker recognition, batch processing and exports, and want dictation as well. Choose **Whispur** if live dictation is the job, and you want it free, open source and focused, with a wide choice of speech engines.

## At a glance

| | Whispur | MacWhisper |
| --- | --- | --- |
| Price (as of November 2026) | Free. Cloud providers, if you use them, bill you directly | Free tier; Pro €64, paid once, with lifetime updates |
| Platforms | macOS 14 or later; current release build runs on Apple silicon | Mac, sold through Gumroad or the App Store |
| Main job | Live dictation into any app | Transcribing audio and video files |
| File transcription | No | Yes: mp3, wav, m4a, ogg, opus, mov and mp4, batch and watched folders |
| Meeting recording | No | Yes, records meetings in apps such as Zoom and Teams without a bot |
| Speaker recognition | No | Yes |
| System-wide dictation | Yes, hold Fn or Command + Fn hands-free | Yes, with AI prompts and app-specific prompts |
| Local speech | NVIDIA Parakeet, Apple speech recognition | Local models |
| Cloud services | Your own key: OpenAI, Groq, Deepgram, ElevenLabs, Mistral, Meta Muse for speech; Anthropic, OpenAI, Groq, Cerebras, AWS Bedrock for cleanup | Your own keys for providers including OpenAI, Anthropic, Groq, Google and OpenRouter, plus Deepgram and ElevenLabs; local models through Ollama or LM Studio |
| Command-line tool | No | Yes |
| Open source | Yes, MIT licence | Not published as open source |

## Choose MacWhisper if...

- **You transcribe files.** MacWhisper handles audio and video files, in batches, from watched folders, with exports to formats such as .docx, .pdf and .md. Whispur has no file transcription at all.
- **You record meetings.** MacWhisper can record calls in apps like Zoom, Teams and Webex without a bot joining, and recognize speakers. Whispur only hears your own dictation.
- **You want translation, a CLI or automations** that push transcripts to tools like Notion or Obsidian.
- **You prefer a one-time licence** for a broad toolkit. MacWhisper Pro is €64 once, as of November 2026.

## Choose Whispur if...

- **You mainly dictate.** Whispur is built only for dictation: hold Fn, speak, release, and the text is pasted where your cursor is, with your clipboard restored afterwards.
- **You want it free and open source.** Whispur costs nothing and its Swift source is public under the MIT licence.
- **You want a specific speech engine.** Whispur supports NVIDIA Parakeet on the Neural Engine, Apple speech recognition, and six cloud engines with your own key, including Deepgram Nova-3, ElevenLabs Scribe with optional live streaming, Mistral Voxtral and Meta Muse. See the [engine guide](https://whispur.app/blog/whisper-vs-scribe-vs-nova-3).
- **You want dictation details handled for you.** Spoken edits ("scratch that", "new line"), spoken symbols for code, a Dictionary with "heard as" spellings, per-app styles, and a "Use raw" undo for cleanup. See [dictating code and prompts](https://whispur.app/blog/dictating-code-and-prompts).
- **You want to see every request.** The Activity tab shows raw and cleaned text, and the Requests tab lists every provider call with its timing.

## Using both

They overlap only on dictation, so plenty of people could reasonably run both: MacWhisper for recordings and meetings, Whispur for day-to-day dictation. If you do, give them different shortcuts so they do not both start recording at once.

## Frequently asked questions

### Can Whispur transcribe audio files like MacWhisper?

No. Whispur only transcribes live dictation and pastes it into the app you are using. It has no file transcription, API or command-line tool. MacWhisper is built for transcribing files.

### Does MacWhisper have system-wide dictation?

Yes. MacWhisper's site lists system-wide dictation, with AI prompts and app-specific prompts, alongside its file transcription features.

### Do both run locally?

Yes. MacWhisper says it uses local models to transcribe your files. Whispur uses NVIDIA Parakeet on Apple silicon or Apple speech recognition with no key, and can also use cloud engines with your own key.

### How much does MacWhisper cost?

As of November 2026, MacWhisper has a free tier and a Pro licence for €64, paid once, with lifetime updates. Whispur is free.

## Try Whispur

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg) and hold Fn to talk. No account or key needed. See all [comparisons](https://whispur.app/compare) or read [the best Mac dictation apps in 2026](https://whispur.app/blog/best-mac-dictation-apps).

## Sources, checked 24 November 2026

- [MacWhisper homepage](https://macwhisper.com/)
- Whispur facts: [README](https://github.com/sophiie-ai/whispur#readme), [llms-full.txt](https://whispur.app/llms-full.txt)
