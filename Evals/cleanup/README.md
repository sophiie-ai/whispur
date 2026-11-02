# Cleanup prompt eval

Checks the default cleanup prompt (`Prompts.defaultCleanup`) against a fixed set of dictations.
Each request is built the way the app builds it, sent to a real provider, and the model's output
is scored against an expected cleanup.

- `cases.jsonl`: 128 cases (108 tune, 20 held-out), one JSON object per line.
- `golden/`: a fixed transcript + vocabulary and the exact user message the app builds for it,
  and the system prompt for a Chat app (`system-prompt-chat.txt`).
  `CleanupPromptTests.testUserMessageMatchesEvalGoldenFile`,
  `CleanupPromptTests.testChatPromptMatchesEvalGoldenFile` and `eval-cleanup.py --self-test`
  check against them, so the Swift and Python request builders can't drift apart.
- `../../scripts/eval-cleanup.py`: the runner (Python 3, standard library only).

This directory is not part of the Xcode project (`project.yml` only builds `Sources/`, `Resources/`
and `Tests/`).

## Running

```bash
export GROQ_API_KEY=...      # or: "$(security find-generic-password -s ai.sophiie.whispur -a groq-api-key -w)"
export OPENAI_API_KEY=...

python3 scripts/eval-cleanup.py --self-test                       # request building only, no API calls
python3 scripts/eval-cleanup.py --provider openai --prompt new    # working-tree prompt, gpt-6-luna
python3 scripts/eval-cleanup.py --provider groq --prompt current  # origin/main prompt, openai/gpt-oss-20b
python3 scripts/eval-cleanup.py --provider openai --cases sorry-late,code-npm --runs 3
python3 scripts/eval-cleanup.py --provider openai --split tune    # tuning cases only
python3 scripts/eval-cleanup.py --provider openai --cases-file ~/Library/Application\ Support/Whispur/MyEvalCases.jsonl
python3 scripts/eval-cleanup.py --provider openai --text-fixes --runs 1   # inputs through the app's text fixes first
python3 scripts/eval-cleanup.py --alias-report                            # "heard as" replacements in code alone, no API calls
```

Options:

| Flag | Meaning |
|---|---|
| `--prompt new` | `Prompts.defaultCleanup` from the working tree, with the current request shape: vocabulary in a `<vocabulary>` block in the user message, the transcript in `<dictation-to-clean>`, then the one-line output contract (`Prompts.cleanupOutputContract`). |
| `--prompt current` | `Prompts.defaultCleanup` from `origin/main` (read with `git show`), with origin/main's request shape: the same user message as `new` when origin/main has `Prompts.cleanupOutputContract`, otherwise the legacy shape (vocabulary appended to the system prompt as a sentence, bare wrapped transcript). |
| `--provider groq` / `openai` | Groq `openai/gpt-oss-20b` or OpenAI `gpt-6-luna`, with the same parameters the app sends (`OpenAIChatFormat.body`): Groq `reasoning_effort: low`, `include_reasoning: false`, `temperature: 0`; OpenAI `reasoning_effort: none`, `temperature: 0`; both `max_completion_tokens` from `LLMRequest.cleanupMaxTokens`. |
| `--model ID` | Any other model on that provider (`openai/gpt-oss-120b`, `gpt-6.1-terra`, ...). Parameters follow `OpenAIChatFormat.parameterStyle`, so a model gets the request shape the app would send it. |
| `--token-cap N` | Stop sending requests once the run has used N tokens (prompt + completion); the runs that finished are scored and saved. Use it to keep a Groq free-tier run inside a daily budget. |
| `--text-fixes` | Run every input through the app's no-AI text fixes first (`Sources/Pipeline/TextFixes.swift`, compiled with `swiftc` into `/tmp/whispur-eval/text-fixes-cli` from `scripts/text-fixes-cli/main.swift`), with every fix on and straight quotes for `code` cases, as the app sends it to cleanup. An input left with nothing but fillers or annotations is scored as `EMPTY` with no request, as the app dismisses it. Without the flag the input is sent as written, like a build without text fixes. |
| `--alias-report` | Score the dictionary's "heard as" replacements made in code (what cleanup-off users get) on the cases with `alias_check`: term recall and false replacements, no API calls. Exits 1 on any false replacement. |
| `--runs N` | Runs per case (default 2). |
| `--cases-file PATH` | Read cases from another JSONL file in the `cases.jsonl` schema (default `Evals/cleanup/cases.jsonl`), such as the private `MyEvalCases.jsonl` that Activity's `Mark as wrong` writes. Its cases use `"split": "mine"` and get their own summary row. |
| `--cases a,b` / `--split tune\|heldout\|mine` | Run a subset. |
| `--show-heldout` | Print diffs for held-out failures too (hidden by default; see below). |
| `--rescore REPORT` | Re-score the outputs saved in an earlier report against the current `cases.jsonl` (after adding an alternate, say). No API calls. |
| `--report PATH` | JSON report location. Default `/tmp/whispur-eval/<prompt>-<provider>-<timestamp>.json`. Reports contain model output, so keep them out of the repo. |

The system prompt is read straight out of the Swift source: the runner parses the
`static let defaultCleanup = """ … """` literal (indentation stripping, `\` line continuations,
standard escapes; interpolation is rejected). Keys are read from the environment and never printed.
Groq's free tier allows 8,000 tokens per minute and counts the requested completion budget, so
Groq runs go one request at a time behind a client-side token bucket that resyncs from the
`x-ratelimit-*` headers and backs off on 429 (waits capped at 60 s and printed to stderr). Expect a full Groq run to take 30 to 60 minutes. The free tier also caps `openai/gpt-oss-20b` at 200,000 tokens per day: one `--runs 2` pass of the new prompt uses about 130k and of the current prompt about 280k, so a full Groq comparison needs a Dev-tier key or several days. When the daily quota runs out the runner stops sending requests and scores the runs that finished;
OpenAI runs six requests in parallel and takes about a minute.

## Cases

Each line has:

| Field | |
|---|---|
| `id` | Stable name. |
| `split` | `tune` or `heldout`. |
| `input` | The raw transcript. |
| `vocabulary` | Optional list of the user's custom terms. |
| `aliases` | Optional "heard as" spellings per term (`{"Whispur": ["Whisper", "Wispur"]}`). Only sent with `--text-fixes`: clear-cut ones are replaced in code, ordinary words go to the vocabulary block as `Whispur (heard as: Whisper)` (`VocabularyAliasPlan`). |
| `always_replace` | Optional terms whose aliases are all replaced in code ("Always replace" in Dictionary). |
| `alias_check` | Optional `{"term": ..., "kind": "recall" \| "guard"}`: `recall` cases should end up with the term, `guard` cases mean the alias as written ("Sophie from accounting called") and must not. Summarized as term recall and false replacements. |
| `style` | Optional. The kind of app the dictation goes into: `chat`, `email`, `docs`, `code` (an `AppGroup`), or `default` (an app outside every group; the default). Every group is on the Default writing style, as on a fresh install, so only `chat` changes the system prompt today: it adds the Chat formatting section (`Prompts.chatFormatting`) the way `Prompts.cleanupPrompt(for:group:customPrompt:)` does. With `--prompt current`, a prompt that has no group sections is used as is for every style. |
| `expected` | The cleanup we want. `EMPTY` means "no speech". |
| `alternates` | Optional other acceptable outputs. |
| `tags` | Free-form labels (`answering`, `corrections`, `numbers`, `code`, `multilingual`, ...). |
| `critical` | `true` when failing the case means real damage: answering or executing the dictation, invented facts, lost negation, wrong deletion, corrupted code or numbers, translation. |
| `loose_punctuation` | Optional. Compare ignoring `. , ; : !` and case, for cases about content rather than punctuation (long dictations, "Sorry I'm late"). |
| `strict_period` | Optional. The trailing period is not optional, for a bare address or command that must not gain one (`jake@sophiie.ai`, not `jake@sophiie.ai.`). |

The held-out split (17 cases: the original 10, 3 email/URL cases added with the email/URL set, and
4 self-correction cases added with the correction set) was set aside before tuning started. While tuning the new prompt,
only tuning-split failures were looked at; held-out results were read as totals only. Keep it that
way when iterating, or the held-out numbers stop meaning anything.

## Scoring

A run passes when the output, after light normalization, equals `expected` or one of the
`alternates`. Normalization, applied to both sides:

- zero-width spaces removed, curly quotes and non-breaking spaces straightened;
- spaces and tabs collapsed, lines trimmed, blank lines dropped;
- **a single trailing period is optional** (`Thanks` = `Thanks.`) unless the case sets
  `strict_period`; `?` and `!` are not, because a question turned into a statement is a real change;
- empty output and `EMPTY` count as the same outcome (the app treats both as "no speech");
- with `loose_punctuation`, also `. , ; : !` removed and lowercased.

A run that stops at the token limit (`finish_reason: length`) or errors is a failure. A critical
failure is a failed run of a `critical` case. The summary counts runs, so with `--runs 2` a case
that fails both times counts as two failures.

Exact match is strict on purpose: a cleanup that drops "the" or adds a `$` is a different text.
When a case fails on a defensible variant (a comma, `3 pm` vs `3pm`), add an alternate rather than
loosening the scorer.

## Decisions the cases pin

- **Numbers.** Number words stay words, except clock times (`10:30`, `3pm`), percentages (`25%`),
  amounts with a unit or currency (`5 kilometers`, `2.5 GB`, `4,500 dollars`), versions, and codes,
  which become digits. Units stay as spoken. Existing digits, leading zeros (`0042`) and IDs are
  never touched. Idioms (`one of the reasons`) stay words.
- **Currency.** The currency word the speaker used is kept and no symbol is added unless they
  said one: `four thousand five hundred dollars` becomes `4,500 dollars`, not `$4,500`. Whispur
  doesn't know whether "dollars" means USD, AUD or CAD, so a `$` would be a guess.
- **Lists.** Items dictated with "bullet" or "next item" become a bulleted list, in every app.
  A clear enumeration of two or more items with ordinal markers ("first ... second ... third",
  "number one ... number two", "one ... two ... three" after "three things") becomes a numbered
  list in Docs, Email, Code and other apps, with any words before the first item as its heading;
  in Chat apps it stays prose, ordinal words included. Everything else stays prose: `first ...
  then ...` (one ordinal is not an enumeration, so the held-out `prose-first-then` keeps its prose
  expectation), "first of all", sentences that mention a bullet, and short inline items with no
  ordinals (`I need three things milk eggs and bread` becomes `I need three things: milk, eggs,
  and bread.`: the sentence reads naturally and nothing marks the items as separate entries).
  The list cases are tagged `new-lists`.
- **Self-corrections.** A cue ("no", "sorry", "I mean", "actually", "wait", "make that", Spanish
  "perdón", "digo", "o sea", "mejor dicho") directly followed by a replacement for the words just
  before it keeps only the replacement (`schedule it for Tuesday oh sorry for Thursday` becomes
  `Schedule it for Thursday.`), also inside a dictated list. Anywhere else the cue is content:
  `sorry I'm late`, `I mean it`, `no, we shouldn't`, `actually that's a good idea` keep every word.
  Retractions ("start over", "forget the room number") drop what they retract; discard phrases are
  kept when they're part of the message ("please ignore my last email") or quoted.
- **Voice commands are code, not prompt.** "scratch that" / "delete that", "new line" and "new
  paragraph" are applied by `VoiceCommands` (unit-tested in `VoiceCommandsTests`) on the raw
  transcript before cleanup, so this eval never sees them. What the eval does pin is the cleanup
  keeping the line breaks they insert (`linebreak-kept`, `linebreak-paragraph-kept`; blank lines
  are dropped by the scorer, and the app restores them after cleanup).
- **Text fixes are code too.** Filler removal ("um", "uh", "hmm"), spoken quote pairs ("quote ...
  end quote") and spoken symbols ("hashtag release", "max underscore retries", "dash dash force")
  run in `TextFixes` before cleanup, unit-tested in `TextFixesTests`. The `text-fixes` cases pin what
  cleanup does with their output (`fix-hashtag`, `fix-quote-pair`, ...) and that the words stay when
  they aren't the symbol (`fix-hashtag-word`, `fix-quote-price`: a quote is also a price). Run them
  with `--text-fixes`; without it they measure a build that has no text fixes.
- **Emails and URLs.** Spoken addresses are written out (`jake at sophiie dot ai` becomes
  `jake@sophiie.ai`, `whispur dot app slash download` becomes `whispur.app/download`), lowercase,
  with vocabulary spellings applied to the domain. A dictation that is only an address gets no final
  period; one inside a sentence ends the sentence normally. "at" in ordinary sentences stays a word
  (`meet me at the office`, `I'm at Google today`).
- **No speech.** Output `EMPTY`. The pipeline only treats it as no-speech when the raw transcript
  itself is non-speech; otherwise it pastes the raw transcript.

## Latest results

Run 2026-11-02 on all 105 cases, OpenAI `gpt-6-luna`, N=2. Self-correction cases are tagged
`new-corrections` (29), enumeration and list cases `new-lists` (15).

| Prompt | Words | Runs passed | Critical failures | Held-out | `new-corrections` | `new-lists` | p50 / p95 latency | Input tokens |
|---|---|---|---|---|---|---|---|---|
| v0.24.0 (origin/main) | 391 | 192/210 | 0 | 36/40 | 56/58 | 16/30 | 1.01 s / 1.41 s | 625 |
| corrections (first layer) | 428 | on its 90 cases: 178/180 vs v0.24.0's 176/180 | 0 | 32/34 | 58/58 | | 0.98 s / 1.31 s | 690 |
| corrections + lists | 464 | **208/210** | 0 | 38/40 | 58/58 | **30/30** | 0.84 s / 1.05 s | 750 |
| any | | Groq `gpt-oss-20b`: pending | | | | | | |

Text fixes, run 2026-11-02 on all 112 cases, OpenAI `gpt-6-luna`, N=1, same prompt (464 words):

| Input | Runs passed | Critical failures | Held-out | `text-fixes` (7) | p50 / p95 latency |
|---|---|---|---|---|---|
| as written (no text fixes) | 110/112 | 0 | 19/20 | 6/7 | 1.12 s / 1.75 s |
| `--text-fixes` | **111/112** | 0 | 19/20 | **7/7** | 1.02 s / 1.37 s |

The only case that changed is `fix-hashtag`: without the fix the model keeps "hashtag release" as
words. Both runs fail only the held-out `prose-first-then`.

"Heard as" vocabulary, run 2026-11-02 on the 16 `aliases` cases (10 recall, 6 guard), OpenAI
`gpt-6-luna`:

| Build | Term recall | False replacements (guard) |
|---|---|---|
| In code alone (`--alias-report`, cleanup off) | 5/10 (the clear-cut ones) | **0/6** |
| Vocabulary only, no aliases (`main`), N=2 | 20/20 | 8/12 |
| Aliases as bare `(heard as: ...)` hints, N=2 | 20/20 | 10/12 |
| Aliases + the `heardAsNote` line (shipped), N=3 | **30/30** | **3/18** |

The bare hints made the model replace more ("Please Whispur it so the baby doesn't wake up"); the
one-line note after the block (`CleanupMessage.heardAsNote`) brought false replacements below
`main`'s without losing recall. The remaining one is `guard-whisper-openai` ("I use Whisper from
OpenAI"). On all 128 cases with `--text-fixes`, N=1: 125/128, the original 112 at 111/112 as before.

Groq results are pending: the free-tier quota was kept for a separate run, so none of these prompts
was scored on Groq yet. Every prompt fails the held-out `prose-first-then` (written as two
sentences). v0.24.0 also flattens the line break in `linebreak-kept` (`Hello, Maya. The build
passed.`) and writes every ordinal enumeration as prose, including in Docs, Email and Code.
