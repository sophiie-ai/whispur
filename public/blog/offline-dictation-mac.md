# Offline dictation on a Mac: private, on-device speech to text

By the Whispur team at Sophiie AI · 24 November 2026

A dictation app hears everything you say. If you dictate client notes, medical details, legal drafts, passwords you shouldn't be saying out loud, or just your own half-formed thoughts, you may not want that audio sent to anyone's server. The good news is that a modern Mac can do the transcription itself.

This guide explains how on-device dictation works in Whispur, a free and open-source dictation app for macOS. It covers the two local engines (NVIDIA Parakeet and Apple speech recognition), the one-time model download, the difference between Apple silicon and Intel Macs, and when it is worth switching to a cloud engine instead.

## What "on-device" means here

When you dictate with a local engine in Whispur, this is what happens:

1. You hold Fn (or press Command + Fn for hands-free recording) and speak.
2. Whispur records to a temporary file and converts it to 16 kHz mono audio.
3. The local engine turns that audio into text on your Mac.
4. Whispur applies its text fixes, also on your Mac: filler words removed, spoken symbols such as "dash dash force" written as `--force`, and spoken edits such as "scratch that" and "new line".
5. The text is pasted where your cursor is, and your clipboard is restored.
6. The temporary recording is deleted.

There is no Whispur account and no Whispur server, so there is nothing in the middle to send audio to. With Parakeet as the engine and AI cleanup switched off, Whispur makes no network request for a dictation at all.

Two exceptions keep a recording on the Mac for a short time, and both stay local. If a dictation fails, or looks wrong (for example 10 seconds or more of audio that produced very little text), Whispur keeps that recording for 24 hours so you can play it or retry it from the Activity tab. It is stored in your user's Application Support folder, readable only by you and excluded from Time Machine and iCloud backups. You can also opt in to keeping your last 5 recordings for debugging. That setting is off by default.

## Engine one: NVIDIA Parakeet

On Apple silicon, Whispur's default local engine is NVIDIA Parakeet. Whispur runs the Parakeet model on the Mac's Neural Engine through the open-source FluidAudio library. It covers 25 European languages, and you need no API key.

Parakeet is the default on Apple silicon for anyone who has not picked a provider and has no cloud speech key. You do not have to turn it on.

### The one-time model download

Parakeet needs its model on your Mac before it can transcribe. The first time you launch Whispur on Apple silicon, the welcome window asks which languages you speak and starts the download in the background. It is a one-time download of about 630 MB from Hugging Face, saved to `~/Library/Application Support/Whispur/Models`. The model weights are licensed CC BY 4.0.

A few details that matter in practice:

- **You can dictate during the download.** Apple speech recognition fills in until Parakeet is ready, and Whispur switches to Parakeet by itself when the download finishes.
- **It waits for a suitable network.** On a metered connection or with Low Data Mode on, the download waits rather than spending your data.
- **After that, no network is needed.** Once the model is on your Mac, Parakeet transcribes without a connection. Recordings never leave the Mac.

If you want to download the model by hand, or check on it, go to Settings > Providers.

### A safety net for cloud users

Parakeet also helps if you use a cloud engine. Since version 0.36.0, when your cloud speech provider can't be reached after Whispur's own retries, and Parakeet's model is on your Mac and covers the languages you speak, Whispur transcribes that dictation with Parakeet instead. The Requests tab notes when this happens. So a flaky hotel Wi-Fi connection does not have to cost you a dictation.

## Engine two: Apple speech recognition

Whispur's second local engine is Apple's speech recognition framework, built into macOS. It needs no key and no download from Whispur. On macOS 26 and later, Whispur uses Apple's newer SpeechAnalyzer model, and falls back to the older recognizer on earlier systems, for languages the new model does not cover, and while Apple's on-device model is still downloading.

Apple speech recognition is the default on Intel Macs, and the fallback on Apple silicon while Parakeet downloads. The first time you use it, macOS asks you to allow Speech Recognition access.

One honest caveat: Apple decides where its speech framework runs. As Whispur's privacy page puts it, depending on the Mac and language, macOS may process audio on the device or with Apple's speech service. If you need a firm guarantee that audio stays on the Mac, Parakeet is the engine to use, because Whispur runs it itself.

## Apple silicon vs Intel

| | Apple silicon | Intel |
| --- | --- | --- |
| Release DMG | Yes | No: the current release build runs on Apple silicon only |
| Default local engine | NVIDIA Parakeet on the Neural Engine | Apple speech recognition |
| Parakeet available | Yes | No |
| Cloud engines with your key | Yes | Yes |

Whispur needs macOS 14 Sonoma or later. The DMG you download from GitHub is built for Apple silicon. If you have an Intel Mac, you can [build Whispur from source](https://github.com/sophiie-ai/whispur#build-from-source), and it will use Apple speech recognition by default.

## Custom vocabulary on local engines

Names, product terms and jargon are where any speech engine slips. Whispur's Dictionary (Settings > Dictionary) lets you add those terms, and for each one, how it tends to get misheard.

How the Dictionary reaches each local engine:

- **Apple speech recognition** receives your terms as contextual hints, so it can lean toward them while it transcribes.
- **Parakeet** does not receive the terms directly. The biasing method available for these models would need a second, English-only model and a second pass over the audio, so Whispur does not use it.

With either engine, two things still help. First, a "heard as" spelling that is clearly a misspelling gets fixed in code on your Mac, with no AI involved. Second, if you turn on AI cleanup, your Dictionary terms go to the cleanup model too. Note that cleanup is a cloud step: it sends the transcript text, not the audio, to the provider you chose.

## Keep it fully local

To make sure nothing leaves your Mac:

1. In Settings > Providers, choose Parakeet (on Apple silicon) as the speech engine, and make sure its model has finished downloading.
2. Switch off "Clean up with AI" in Settings > Providers or from the menu bar. Whispur then pastes exactly what the speech engine heard, with no cleanup request. Text fixes and spoken edits such as "scratch that" still apply.
3. Check the Requests tab after a few dictations. It lists every provider call Whispur makes. Parakeet transcriptions are listed as running on this Mac.

Whispur's source is MIT-licensed and public, so you do not have to take any of this on trust. The [privacy page](https://whispur.app/privacy) describes exactly what is stored and where, and the code on [GitHub](https://github.com/sophiie-ai/whispur) shows it.

## When a cloud engine is worth it

Local engines are private, free to run and work on a plane. Cloud engines are worth considering when:

- **You speak a language Parakeet does not cover.** Parakeet covers 25 European languages. For other languages, a cloud engine or Apple speech recognition may be the better fit.
- **You use a lot of specialist terms.** Several cloud engines accept your vocabulary directly: Deepgram Nova-3 and ElevenLabs Scribe take key terms, and OpenAI's gpt-transcribe takes keywords.
- **You want to see words as you speak.** Live streaming, which shows the words heard so far in the recording overlay, is available with ElevenLabs Scribe and Meta Muse.
- **You are on an Intel Mac** and want something other than Apple speech recognition.

Cloud engines in Whispur use your own API key, and the provider bills you directly for what you use. Audio goes from your Mac straight to that provider. Our guide to [choosing a speech engine](https://whispur.app/blog/whisper-vs-scribe-vs-nova-3) compares them in detail.

## How this compares to other apps

Several Mac dictation apps can work offline, including Superwhisper and MacWhisper with their local models. Wispr Flow's privacy page says its transcription always happens in the cloud. For a fuller picture, see our [comparison of Mac dictation apps](https://whispur.app/blog/best-mac-dictation-apps) and the [Whispur vs Apple Dictation](https://whispur.app/compare/apple-dictation) page.

## Try it

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg), drag it to Applications and open it. Allow Microphone and Accessibility access, pick your languages, and the Parakeet download starts on its own. Then hold Fn and talk. No account, no key, and no audio leaving your Mac.
