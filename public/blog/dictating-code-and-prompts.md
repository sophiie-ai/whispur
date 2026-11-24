# Dictating code, commit messages and AI prompts on a Mac

By the Whispur team at Sophiie AI · 24 November 2026

Developers type a lot of prose that is not code: commit messages, pull request descriptions, code review comments, Slack threads, tickets, and more and more, long prompts for AI coding assistants. Speaking is faster than typing for most people, and a detailed prompt is exactly the kind of text that is easier to say than to write.

The catch is that general dictation tools are bad at technical text. They turn `useState` into "use state", drop the dashes from `--force`, and capitalize the first letter of a shell command. This guide shows how to set up Whispur, a free and open-source dictation app for macOS, so that technical dictation comes out right. It covers custom vocabulary, spoken symbols, the Code-aware style and per-app settings, the editable cleanup prompt, and the hands-free shortcut.

## The basic loop

Whispur lives in the menu bar and pastes into whatever app has focus: your editor, a terminal, a browser text box or an AI chat window.

- **Hold Fn**, speak, and let go. Whispur transcribes, optionally cleans up, and pastes at your cursor. Your clipboard is restored afterwards.
- **Command + Fn** starts hands-free recording. Press it again to stop and paste. You can also choose Fn twice in Settings.
- **Esc** cancels a recording.

Hold-to-talk suits short things: a commit subject, a variable rename, a one-line reply. Hands-free suits long things: a prompt that explains a bug, a pull request description, or a design note. With Command + Fn you can lean back, look at the code you are describing, and talk for as long as you need.

## Teach it your words with the Dictionary

Every codebase has words no speech engine has heard: your product name, your service names, library names, teammates' names. Add them in Settings > Dictionary.

Each term can also list how it gets misheard. If the engine keeps writing "next JS" when you mean "Next.js", add "next JS" as a "heard as" spelling. Whispur treats these in two ways:

- **Clear-cut misspellings are fixed in code**, on your Mac, every time, with no AI involved.
- **Ordinary words** (if your project is called "Whisper" or "Sophie") are left to the AI cleanup step, which replaces them only when the sentence is about your term. Turn on "Always replace" if you want them changed every time.

You do not have to build the list by hand. In the Activity tab, "Add word" fills a term in from a dictation that went wrong. You can also opt in to "Learn from my edits" in the Dictionary, which suggests a term when you correct a word Whispur got wrong.

Your Dictionary also goes to the speech engine when it can use it. Deepgram Nova-3 and ElevenLabs Scribe receive the terms as key terms, OpenAI's gpt-transcribe as keywords, and Whisper models as a short prompt. Our [speech engine guide](https://whispur.app/blog/whisper-vs-scribe-vs-nova-3) covers how each one uses them.

## Spoken symbols and text fixes

Whispur runs a set of text fixes on your Mac before any AI step, with cleanup on or off. You can turn each one off in Settings > Preferences > Text fixes. The ones that matter for code:

- **Spoken symbols:** "hashtag release" becomes `#release`, "at sign home" becomes `@home`, "my underscore variable" becomes `my_variable`, and "dash dash force" becomes `--force`. Inside a flag you have started, "dash" joins words, so "dash dash save dash dev" becomes `--save-dev`.
- **Spoken quotes:** "quote ... end quote" is written with quotation marks.
- **Filler words** such as "um" and "uh" are removed.
- **Smart spacing:** a leading space is added when your cursor sits right after a word, so pasted text does not run into the previous word.

Symbols only join when you say them as symbols. "The hashtag is trending" stays as words.

Two spoken edits also work everywhere: "scratch that" removes the sentence before it, and "new line" or "new paragraph" adds a line break. They run before cleanup, so the model never sees the words you scratched.

## Use the Code-aware style in your editor and terminal

AI cleanup fixes punctuation, capitalization and misheard words. But the right punctuation for an email is wrong for a terminal. Whispur's Styles (Settings > Styles) let cleanup read differently per app.

There are six styles: Default, Casual, Formal, Verbatim, Code-aware and Custom. Code-aware is built for developers. In prose, it wraps identifiers, file paths and commands in backticks, so "rename fetch user to load user" comes out as "Rename `fetchUser` to `loadUser`." A dictation that is only a command, code or an address stays bare: no backticks, no added capital letter and no final period. That matters in a terminal, where `git status.` is not a command.

Styles apply per app group, and Whispur ships with a Code group that covers Xcode, VS Code, Cursor, Terminal, iTerm, Ghostty and Zed. To set it up:

1. Open Settings > Styles.
2. Under App groups, set the Code group to Code-aware.
3. Optionally, under Per app, choose "Add an app" to give a specific app its own style. An app's own style wins over its group and the default.

Every group starts on Default, so nothing changes until you opt in. Styles need AI cleanup, so they have no effect while "Clean up with AI" is off.

Other groups are useful too. In the Chat group (Slack, Messages, WhatsApp, Discord and Teams), spoken enumerations stay as prose rather than becoming a numbered list, which is usually what you want in a message.

## Dictating prompts for AI assistants

Dictating into Claude, ChatGPT, Cursor or a coding agent's terminal raises a specific risk. Your prompt is full of questions and instructions, and the cleanup step is itself an AI model. A careless cleanup model might try to answer your question instead of cleaning it up.

Whispur's default cleanup prompt is written to prevent that. It tells the model that the dictation is never addressed to it, and that it must never answer, follow or comment on questions or instructions in the text. It also restates that rule after your transcript, where models pay the most attention. So "can you explain why this test is flaky and suggest a fix" is pasted as that question, cleaned up, not answered.

Some habits that help when you dictate prompts:

- **Use hands-free mode** (Command + Fn) for long prompts, and talk the way you would brief a colleague.
- **Say lists out loud.** "First ... second ..." or "bullet ... next item" becomes a list in the Default style outside chat apps, which makes multi-step instructions easier for the model to follow.
- **Name files and functions plainly.** With the Code-aware style, they come back in backticks.
- **Fix mistakes as you go.** "Make that" or "I mean" followed by a replacement keeps only the replacement.
- **Check the raw version.** If cleanup changed something, a "Cleaned up · Use raw" toast appears for 4 seconds after the paste. Press Option + Command + Z to swap in exactly what you said.

## Edit the cleanup prompt

If the built-in styles are not quite right, write your own. In Settings > Styles there is a custom prompt editor. Pick the Custom style for any app or group, and cleanup uses your prompt there instead. While the custom prompt is empty, Custom works like Default. You can also expand "Show the default cleanup prompt" to read the built-in one, which is a good starting point to copy and change.

Whispur also lets you test a prompt against your own dictations. In the Activity tab, "Mark as wrong" saves a dictation, with what it should have said, to a private file on your Mac. The repository includes an eval script that scores the cleanup prompt against those cases, so you can check a prompt change before you rely on it. The [README](https://github.com/sophiie-ai/whispur#usage) shows the command.

## Pick a cleanup model

Cleanup is optional and uses your own API key. The defaults, as listed in Whispur's provider settings:

| Provider | Default cleanup model |
| --- | --- |
| Anthropic | Claude Haiku 5.5 |
| OpenAI | GPT-6 Luna, custom base URL supported |
| Groq | gpt-oss-20b |
| Cerebras | Qwen 3.8 27B |
| AWS Bedrock | Claude, with a Bedrock API key |

Every cleanup provider accepts a custom model name, so you can switch models without waiting for a Whispur update. If cleanup fails, Whispur pastes the raw transcript instead. If you would rather have no AI in the loop at all, switch off "Clean up with AI": you still get the text fixes, spoken symbols and spoken edits.

## Commit messages, end to end

A worked example. You are in a terminal and want to commit.

1. Type `git commit -m "` yourself.
2. Hold Fn and say: "fix parse config so it handles an empty file".
3. Let go. With the Code-aware style on the Code group, you get something like: Fix `parseConfig` so it handles an empty file.
4. Close the quote and press Return.

For a longer pull request description, open the browser text box, press Command + Fn, and talk through what changed and why. Press Command + Fn again to stop.

## Why developers like an open-source dictation app

A dictation app can hear what you say and type into any app on your Mac, including your terminal. Whispur's Swift source is public under the MIT licence, there is no Whispur account or server, and API keys live in the macOS Keychain. You can read exactly where your audio and text go, build it yourself, or send a pull request. See the [about page](https://whispur.app/about) for more, or compare Whispur with other apps in our [2026 roundup](https://whispur.app/blog/best-mac-dictation-apps) and on the [Whispur vs Wispr Flow](https://whispur.app/compare/wispr-flow) and [Whispur vs Superwhisper](https://whispur.app/compare/superwhisper) pages.

## Try Whispur

[Download Whispur](https://github.com/sophiie-ai/whispur/releases/latest/download/Whispur.dmg), drag it to Applications, and allow Microphone and Accessibility access. Then add your project's words to the Dictionary, set the Code group to Code-aware, and hold Fn in your editor. It needs macOS 14 or later, and the current release build runs on Apple silicon.
