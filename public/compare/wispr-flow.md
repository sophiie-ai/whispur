# Whispur vs Wispr Flow

By the Whispur team at Sophiie AI · 24 November 2026

Whispur and Wispr Flow both let you hold a key, speak, and have clean text appear in whatever app you are using. They are built on different models. Wispr Flow is a cross-platform subscription service that transcribes in the cloud. Whispur is a free, open-source Mac app that transcribes on your Mac by default and uses your own API keys when you want a cloud engine.

We make Whispur. Wispr Flow facts below come from Wispr Flow's own website, checked on 24 November 2026.

## The verdict

Choose **Wispr Flow** if you want the same dictation on Mac, Windows, iPhone and Android, synced across devices, with no API keys to manage, and with the compliance certifications and admin controls a company may need. Choose **Whispur** if you only need a Mac, want audio to stay on your Mac by default, prefer to pay nothing or pay providers directly, and want to read the source code.

## At a glance

| | Whispur | Wispr Flow |
| --- | --- | --- |
| Price (as of November 2026) | Free. Cloud providers, if you use them, bill you directly | Free plan with limited words per week; Pro $15 per user per month, or $12 per user per month billed annually; Growth and Enterprise plans |
| Platforms | macOS 14 or later; current release build runs on Apple silicon | Mac, Windows, iPhone, Android |
| Where speech is transcribed | On your Mac by default (Parakeet or Apple speech recognition), or a cloud engine you choose with your own key | In the cloud: its privacy page says transcription always happens in the cloud |
| Offline | Yes | No offline mode published |
| Audio retention | Deleted after each dictation; failed or flagged dictations kept on your Mac for 24 hours for retry | Deleted once transcribed, unless you turn on dictation cloud storage |
| Model training | No Whispur model and no Whispur server | You can opt out of model training; off and locked on Growth and Enterprise |
| Account | None | Per-user plans |
| Languages | Parakeet: 25 European languages. Cloud engines vary | 100+ languages with automatic detection |
| Custom words | Dictionary with "heard as" spellings, sent to engines that accept key terms | Personal dictionary that learns your words, or you add them |
| Per-app styles | Yes: Default, Casual, Formal, Verbatim, Code-aware or your own prompt | Yes: different styles for messages, work chats and emails |
| Snippets | No | Yes |
| Meeting notes | No | Yes, Notetaker |
| Compliance | Open source code you can audit; no certifications published | SOC 2 Type II and ISO 27001; HIPAA with a signed BAA on Growth and Enterprise |
| Open source | Yes, MIT licence | Not published as open source |

## Choose Wispr Flow if...

- **You dictate on more than a Mac.** Wispr Flow runs on Mac, Windows, iPhone and Android and syncs across them. Whispur is Mac-only, and that is the biggest difference between the two.
- **You want zero setup.** Wispr Flow's transcription is included. With Whispur, cloud engines and AI cleanup need API keys from each provider.
- **Your company needs certifications and admin controls.** Wispr Flow lists SOC 2 Type II and ISO 27001, HIPAA support with a BAA, SCIM user provisioning, audit logs and MDM on its higher plans. Whispur has no admin console or central billing.
- **You speak many languages.** Wispr Flow lists 100+ languages with automatic detection.
- **You want snippets or meeting notes** in the same app.

## Choose Whispur if...

- **You want audio to stay on your Mac.** Whispur's default engines run on your Mac with no key: NVIDIA Parakeet on Apple silicon, after a one-time ~630 MB model download, and Apple speech recognition. See [offline dictation on a Mac](https://whispur.app/blog/offline-dictation-mac).
- **You want to pay nothing, or pay providers directly.** Whispur is free. If you add a cloud engine, such as OpenAI, Groq, Deepgram, ElevenLabs, Mistral or Meta Muse, that provider bills your own account.
- **You want to choose the engine and the model.** Pick from eight speech engines and five cleanup providers, and set a custom cleanup model. Our [engine guide](https://whispur.app/blog/whisper-vs-scribe-vs-nova-3) compares them.
- **You want to audit it.** Whispur's Swift source is public under the MIT licence. You can check where audio and text go, build it yourself, or fork it.
- **You write code.** Spoken symbols ("dash dash force" becomes `--force`), a Code-aware style for editors and terminals, and an editable cleanup prompt. See [dictating code and prompts](https://whispur.app/blog/dictating-code-and-prompts).
- **You do not want an account.** There is nothing to sign up for.

## How they work differently

Wispr Flow sends your audio to its servers over TLS, transcribes it there, and deletes it once it is transcribed unless you have turned on cloud storage. Your history can be kept on your computer, auto-deleted after 24 hours, or never saved.

Whispur has no server. With a local engine, transcription happens on your Mac. With a cloud engine, audio goes from your Mac straight to the provider you chose, using your key from the macOS Keychain, and that provider's own data policy applies. Whispur's own records, such as recent transcripts and the provider request log, stay on your Mac and can be cleared in Settings. The app has no telemetry.

## Frequently asked questions

### Is Whispur a free alternative to Wispr Flow?

Whispur is free and MIT licensed, with no account or subscription, and it covers the same core job on a Mac: hold a key, speak, and paste clean text into any app. It is not a full replacement if you need Windows, iPhone or Android, snippets, meeting notes or team admin controls, which Wispr Flow offers.

### Does Wispr Flow work offline?

Wispr Flow does not publish an offline mode. Its privacy page says transcription always happens in the cloud. Whispur can dictate offline with NVIDIA Parakeet or Apple speech recognition.

### Is Whispur available on Windows or iPhone?

No. Whispur is a macOS app only, for macOS 14 Sonoma or later, and the current release build runs on Apple silicon. Wispr Flow runs on Mac, Windows, iPhone and Android.

### How much does Wispr Flow cost compared with Whispur?

As of November 2026, Wispr Flow has a free plan with a weekly word limit and a Pro plan at $15 per user per month, or $12 billed annually. Whispur is free. If you use a cloud engine with Whispur, the provider bills you directly for your usage.

### Can I use my own API keys with Wispr Flow?

Wispr Flow's site does not describe bringing your own speech API keys; transcription runs on its own servers. Whispur is built around your own keys for cloud engines, or no key at all for its local engines.

## Try Whispur

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg), drag it to Applications, allow Microphone and Accessibility access, and hold Fn to talk. No account or key needed. For the full field, read [the best Mac dictation apps in 2026](https://whispur.app/blog/best-mac-dictation-apps) or see all [comparisons](https://whispur.app/compare).

## Sources, checked 24 November 2026

- [Wispr Flow pricing](https://wisprflow.ai/pricing)
- [Wispr Flow privacy](https://wisprflow.ai/privacy)
- [Wispr Flow homepage](https://wisprflow.ai/)
- Whispur facts: [README](https://github.com/sophiie-ai/whispur#readme), [privacy](https://whispur.app/privacy) and [llms-full.txt](https://whispur.app/llms-full.txt)
