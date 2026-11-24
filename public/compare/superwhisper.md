# Whispur vs Superwhisper

By the Whispur team at Sophiie AI · 24 November 2026

Superwhisper and Whispur have a lot in common. Both are push-to-talk dictation apps that started on the Mac, both can transcribe on your machine with local models, and both let you shape the output with custom prompts. The differences are in platforms, pricing and openness: Superwhisper runs on more platforms and sells a Pro plan, while Whispur is Mac-only, free for everything and open source.

We make Whispur. Superwhisper facts below come from Superwhisper's own website, checked on 24 November 2026.

## The verdict

Choose **Superwhisper** if you want local and cloud dictation on Mac, Windows, iOS and Android under one licence, with cloud AI models included in Pro and a mature set of modes. Choose **Whispur** if you only need a Mac and want every feature free, no account, your own API keys for cloud engines, and source code you can read.

## At a glance

| | Whispur | Superwhisper |
| --- | --- | --- |
| Price (as of November 2026) | Free. Cloud providers, if you use them, bill you directly | Free tier that does not expire; Pro $8.49 per month, $84.99 per year, or $249.99 lifetime; 3,000-word Pro trial; 14-day refund |
| Platforms | macOS 14 or later; current release build runs on Apple silicon | Mac, Windows, iOS, Android |
| Local speech | NVIDIA Parakeet on Apple silicon (25 European languages), Apple speech recognition | Local Whisper models; its site says offline models run best on Apple silicon Macs |
| Cloud speech | Your own key: OpenAI, Groq, Deepgram, ElevenLabs, Mistral, Meta Muse | Cloud models included in Pro; Pro can also use your own API keys |
| AI cleanup models | Your own key: Anthropic, OpenAI, Groq, Cerebras, AWS Bedrock, with a custom model name | Pro lists models including GPT-5, Claude Haiku 4.5, Llama 4, Grok 4.1 and Gemini 3.0 Flash |
| Custom output | Styles per app group or app, plus your own cleanup prompt | Preset and custom modes, which can switch on per app |
| Custom vocabulary | Dictionary with "heard as" spellings | Vocabulary for names, abbreviations and terms |
| Intel Macs | Build from source; uses Apple speech recognition | Its site says Intel Macs work best with cloud models |
| Compliance | Open source code you can audit; no certifications published | SOC 2 Type II listed for Enterprise |
| Open source | Yes, MIT licence | Not published as open source |

## Choose Superwhisper if...

- **You use Windows, iPhone or Android too.** Superwhisper is available on all of them, with one Pro licence covering your devices. Whispur only runs on macOS.
- **You want cloud models without managing keys.** Superwhisper Pro includes cloud and local AI models. With Whispur, every cloud engine and cleanup model uses your own API key.
- **You like a one-time purchase with lifetime access.** Superwhisper offers a $249.99 lifetime licence as of November 2026.
- **You want ready-made modes.** Superwhisper ships presets for voice, message and email, plus tone styles, and custom modes that turn on in chosen apps.
- **You need an Enterprise plan** with hosted models and model access control.

## Choose Whispur if...

- **You want everything free.** Whispur has no paid tier and no word limits. Local engines cost nothing to run, and cloud providers bill you directly at their own rates.
- **You want open source.** Whispur's Swift code is public under the MIT licence. You can audit how audio and text are handled, build it yourself, or contribute.
- **You do not want an account.** Whispur has no sign-up and no Whispur server.
- **You want a specific engine.** Whispur supports eight speech engines, including Deepgram Nova-3 and ElevenLabs Scribe with your vocabulary sent as key terms, and live streaming with ElevenLabs and Meta Muse. See our [engine guide](https://whispur.app/blog/whisper-vs-scribe-vs-nova-3).
- **You want Parakeet.** On Apple silicon Whispur runs NVIDIA Parakeet on the Neural Engine, with no key, after a one-time ~630 MB download. If a cloud engine can't be reached, Whispur can fall back to Parakeet for that dictation.
- **You dictate code.** The Code-aware style, spoken symbols and per-app styles are covered in [dictating code and prompts](https://whispur.app/blog/dictating-code-and-prompts).

## How they work differently

The core experience is close: a global shortcut, a small recording overlay, and text pasted where your cursor is. Whispur uses Fn to hold and talk, and Command + Fn for hands-free recording.

The main difference is the business model. Superwhisper bundles access to cloud models in its Pro plan, which is convenient. Whispur never sits between you and a provider: you sign up with the provider you want, paste your key into Settings, and audio goes from your Mac straight to them. That is more setup, but it means Whispur itself has nothing to charge for and no server to run.

## Frequently asked questions

### Is Whispur a free alternative to Superwhisper?

Whispur is free and open source, and covers the core job on a Mac: local or cloud dictation into any app, with custom vocabulary and prompts. Superwhisper offers more platforms and bundled cloud models in its paid Pro plan, so which is the better fit depends on whether you need those.

### Do both apps work offline?

Yes. Superwhisper's site says it works offline with local models. Whispur works offline with NVIDIA Parakeet on Apple silicon or Apple speech recognition.

### Does Whispur work on Windows or iPhone like Superwhisper?

No. Whispur is macOS only, for macOS 14 Sonoma or later. Superwhisper lists Mac, Windows, iOS and Android.

### How much does Superwhisper Pro cost?

As of November 2026, Superwhisper's site lists Pro at $8.49 per month, $84.99 per year, or $249.99 once for lifetime access, with a free tier that does not expire.

## Try Whispur

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg) and hold Fn to talk. No account or key needed. See all [comparisons](https://whispur.app/compare) or read [the best Mac dictation apps in 2026](https://whispur.app/blog/best-mac-dictation-apps).

## Sources, checked 24 November 2026

- [Superwhisper homepage](https://superwhisper.com/)
- [Superwhisper pricing comparison page](https://superwhisper.com/vs/wispr-flow/pricing)
- Whispur facts: [README](https://github.com/sophiie-ai/whispur#readme), [changelog](https://whispur.app/changelog) and [llms-full.txt](https://whispur.app/llms-full.txt)
