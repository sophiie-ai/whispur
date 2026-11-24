# About Whispur

Whispur is a free, open-source voice dictation app for macOS. Hold a shortcut, speak, and release: Whispur transcribes what you said, optionally tidies it up with an LLM, and pastes it into the app you are using.

## What Whispur is

Whispur lives in the macOS menu bar instead of taking over your desktop. Hold Fn to talk and release to paste, or press Command + Fn for hands-free recording. Text lands where your cursor is, in email, Slack, your editor or a prompt box, and your clipboard is restored afterwards.

It works with no API key at all: on Apple silicon it transcribes on your Mac with NVIDIA Parakeet, and on Intel Macs with Apple speech recognition. When you want a cloud engine, you can bring your own key for OpenAI, Groq, Deepgram, ElevenLabs, Mistral or Meta Muse, and optionally add a cleanup model from Anthropic, OpenAI, Groq, Cerebras or AWS Bedrock. Whispur needs macOS 14 Sonoma or later, and the current release build runs on Apple silicon.

## Who makes it

Whispur is made by [Sophiie AI Pty Ltd](https://sophiie.ai), the company behind [Sophiie](https://sophiie.ai). Sophiie AI publishes and maintains Whispur, signs and notarizes its releases, and reviews contributions on GitHub. The project is developed in the open: the code, issue tracker and release history are all public.

## Why it is open source

A dictation app hears everything you say and can type into any app on your Mac. That kind of access should be auditable. Whispur's Swift source is public, so you can check exactly where your audio and text go, build it yourself, or fork it.

- **MIT licensed:** free to use, modify and redistribute. See the [license](https://github.com/sophiie-ai/whispur/blob/main/LICENSE).
- **No account:** there is nothing to sign up for and no subscription.
- **No backend:** there is no Whispur server. Audio and transcripts go straight from your Mac to the providers you choose, with your own API keys, which are stored in the macOS Keychain.
- **No app telemetry:** the app only talks to your providers and to the signed update feed.

## Releases and updates

Every release is signed with an Apple Developer ID certificate, notarized by Apple, and updated through Sparkle, which checks an EdDSA signature before installing. Release notes for every version are on the [changelog](https://whispur.app/changelog).

## Source code and contributing

The code, issues and pull requests live at [github.com/sophiie-ai/whispur](https://github.com/sophiie-ai/whispur). Read the [contributing guide](https://github.com/sophiie-ai/whispur/blob/main/CONTRIBUTING.md) to get started, or [contact us](https://whispur.app/contact) with questions.

---

Canonical page: https://whispur.app/about

Whispur is a free, open-source (MIT) voice dictation app for macOS by Sophiie AI Pty Ltd. More: [llms.txt](https://whispur.app/llms.txt) · [Full site as Markdown](https://whispur.app/llms-full.txt) · [Sitemap](https://whispur.app/sitemap.xml)
