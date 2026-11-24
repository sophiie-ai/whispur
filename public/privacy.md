# What Whispur does with your data

Short version: Whispur has no account and no backend server. Your audio and text go only to the providers you choose, with your own keys.

## Audio

When you hold your shortcut and talk, Whispur records to a temporary file on your Mac, converts it to 16 kHz mono audio for transcription, and deletes the temporary files once the dictation finishes. Recordings with no detectable speech are discarded without being sent anywhere.

- **Parakeet (on this Mac):** audio is transcribed by NVIDIA Parakeet running on your Mac. After the one-time model download from Hugging Face, recordings never leave the Mac.
- **Apple speech recognition:** audio is handed to the speech recognition framework built into macOS. Whispur does not send it anywhere else. Depending on your Mac and language, macOS may process the request on the device or with Apple's speech service, under Apple's own privacy terms.
- **Cloud providers** (OpenAI, Groq, Deepgram, ElevenLabs, Mistral, Meta Muse, or an OpenAI-compatible endpoint you set): audio goes directly from your Mac to that provider using your API key. There is no Whispur server in between.

Recordings are not kept, with two exceptions: a dictation that failed, and one that looks wrong (for example long audio with very little text, or a speech provider that fell back). Those recordings stay on your Mac for 24 hours so you can retry them, readable only by your user and excluded from Time Machine and iCloud backups. If you turn on **Keep my last few recordings on this Mac for debugging** (off by default), Whispur keeps your last 5 recordings with the same protections and deletes each one after 24 hours. Recordings are never uploaded anywhere except to the speech provider you chose.

## Transcripts

Transcripts are pasted into the app you are using. If you configured a cleanup provider (Anthropic, OpenAI, Groq, Cerebras or AWS Bedrock), the transcript is sent directly to that provider first. Recent raw and cleaned transcripts are kept in a local Activity history on your Mac, which you can clear at any time in Settings.

The optional **learn from edits** setting is off by default. When you turn it on, Whispur re-reads the text field it just pasted into, using macOS Accessibility, to spot words you corrected and suggest them as custom vocabulary. That comparison happens on your Mac.

## API keys

API keys are stored in the macOS Keychain and used only to authenticate requests to the provider they belong to. We never see them.

## Request log

The Requests tab in Settings keeps a local log of provider API calls, with timings and errors, so you can see exactly what was sent where. It stays on your Mac and can be cleared at any time.

## Analytics and telemetry

The Whispur **app** does not phone home. The only network requests it makes are to the providers you configure and to the update feed.

The Whispur **website** (whispur.app) uses Vercel Web Analytics and Speed Insights, which are cookie-free and collect no personal data. They count page views and measure performance. Fonts are served from whispur.app, and the changelog page loads the open-source marked library from the jsDelivr CDN to render release notes.

## Update checks

The app checks [whispur.app/appcast.xml](https://whispur.app/appcast.xml) for new releases through Sparkle. The request carries a standard user agent and your app version, nothing that identifies you. Downloads are verified against an EdDSA signature before they install.

## Source code

Whispur is MIT licensed. Read it, audit it or fork it at [github.com/sophiie-ai/whispur](https://github.com/sophiie-ai/whispur).

## Contact

Questions? [Open an issue on GitHub](https://github.com/sophiie-ai/whispur/issues) or reach out through [sophiie.ai](https://sophiie.ai).

Last updated: 24 November 2026

---

Canonical page: https://whispur.app/privacy

Whispur is a free, open-source (MIT) voice dictation app for macOS by Sophiie AI Pty Ltd. More: [llms.txt](https://whispur.app/llms.txt) · [Full site as Markdown](https://whispur.app/llms-full.txt) · [Sitemap](https://whispur.app/sitemap.xml)
