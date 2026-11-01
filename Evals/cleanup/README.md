# Cleanup prompt eval

Checks the default cleanup prompt (`Prompts.defaultCleanup`) against a fixed set of dictations.
Each request is built the way the app builds it, sent to a real provider, and the model's output
is scored against an expected cleanup.

- `cases.jsonl`: 61 cases (48 tune, 13 held-out), one JSON object per line.
- `golden/`: a fixed transcript + vocabulary and the exact user message the app builds for it.
  `CleanupPromptTests.testUserMessageMatchesEvalGoldenFile` and `eval-cleanup.py --self-test`
  both check against it, so the Swift and Python request builders can't drift apart.
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
```

Options:

| Flag | Meaning |
|---|---|
| `--prompt new` | `Prompts.defaultCleanup` from the working tree, with the current request shape: vocabulary in a `<vocabulary>` block in the user message, the transcript in `<dictation-to-clean>`, then the one-line output contract (`Prompts.cleanupOutputContract`). |
| `--prompt current` | `Prompts.defaultCleanup` from `origin/main` (read with `git show`), with origin/main's request shape: the same user message as `new` when origin/main has `Prompts.cleanupOutputContract`, otherwise the legacy shape (vocabulary appended to the system prompt as a sentence, bare wrapped transcript). |
| `--provider groq` / `openai` | Groq `openai/gpt-oss-20b` or OpenAI `gpt-6-luna`, with the same parameters the app sends (`OpenAIChatFormat.body`): Groq `reasoning_effort: low`, `include_reasoning: false`, `temperature: 0`; OpenAI `reasoning_effort: none`, `temperature: 0`; both `max_completion_tokens` from `LLMRequest.cleanupMaxTokens`. |
| `--runs N` | Runs per case (default 2). |
| `--cases a,b` / `--split tune\|heldout` | Run a subset. |
| `--show-heldout` | Print diffs for held-out failures too (hidden by default; see below). |
| `--rescore REPORT` | Re-score the outputs saved in an earlier report against the current `cases.jsonl` (after adding an alternate, say). No API calls. |
| `--report PATH` | JSON report location. Default `/tmp/whispur-eval/<prompt>-<provider>-<timestamp>.json`. Reports contain model output, so keep them out of the repo. |

The system prompt is read straight out of the Swift source: the runner parses the
`static let defaultCleanup = """ … """` literal (indentation stripping, `\` line continuations,
standard escapes; interpolation is rejected). Keys are read from the environment and never printed.
Groq's free tier allows 8,000 tokens per minute and counts the requested completion budget, so
Groq runs go one request at a time behind a client-side token bucket that resyncs from the
`x-ratelimit-*` headers and backs off on 429 (waits capped at 60 s and printed to stderr). Expect a full Groq run to take 30 to 60 minutes. The free tier also caps `openai/gpt-oss-20b` at 200,000 tokens per day: one `--runs 2` pass of the new prompt uses about 130k and of the current prompt about 280k, so a full Groq comparison needs a Dev-tier key or several days. The runner stops with a clear message when the daily quota is exhausted;
OpenAI runs six requests in parallel and takes about a minute.

## Cases

Each line has:

| Field | |
|---|---|
| `id` | Stable name. |
| `split` | `tune` or `heldout`. |
| `input` | The raw transcript. |
| `vocabulary` | Optional list of the user's custom terms. |
| `expected` | The cleanup we want. `EMPTY` means "no speech". |
| `alternates` | Optional other acceptable outputs. |
| `tags` | Free-form labels (`answering`, `corrections`, `numbers`, `code`, `multilingual`, ...). |
| `critical` | `true` when failing the case means real damage: answering or executing the dictation, invented facts, lost negation, wrong deletion, corrupted code or numbers, translation. |
| `loose_punctuation` | Optional. Compare ignoring `. , ; : !` and case, for cases about content rather than punctuation (long dictations, "Sorry I'm late"). |
| `strict_period` | Optional. The trailing period is not optional, for a bare address or command that must not gain one (`jake@sophiie.ai`, not `jake@sophiie.ai.`). |

The held-out split (13 cases: the original 10, plus 3 email/URL cases added with the email/URL set)
was set aside before tuning started. While tuning the new prompt,
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
- **Lists.** Only from explicitly dictated items ("bullet", "next item", "new line"). `first ...
  then ...` prose and sentences that mention a bullet stay prose.
- **Self-corrections.** Only clear replacements ("Tuesday, no, Wednesday"); "sorry", "actually",
  "no", "I mean" are content on their own. Discard phrases are kept when they're part of the
  message ("please ignore my last email") or quoted.
- **Emails and URLs.** Spoken addresses are written out (`jake at sophiie dot ai` becomes
  `jake@sophiie.ai`, `whispur dot app slash download` becomes `whispur.app/download`), lowercase,
  with vocabulary spellings applied to the domain. A dictation that is only an address gets no final
  period; one inside a sentence ends the sentence normally. "at" in ordinary sentences stays a word
  (`meet me at the office`, `I'm at Google today`).
- **No speech.** Output `EMPTY`. The pipeline only treats it as no-speech when the raw transcript
  itself is non-speech; otherwise it pastes the raw transcript.

## Latest results

Run 2026-11-01. New prompt: 796 words, about 1.2k input tokens per request including the user
message. Current prompt (origin/main): 1,872 words, about 2.7k.

| Prompt | Provider | Runs passed | Critical failures | Held-out | p50 / p95 latency | Input tokens |
|---|---|---|---|---|---|---|
| current | OpenAI `gpt-6-luna`, N=2 | 81/100 | 11 | 16/20 | 1.11 s / 1.71 s | 2,710 |
| new | OpenAI `gpt-6-luna`, N=2 | **100/100** | **0** | **20/20** | 1.04 s / 1.47 s | 1,199 |
| new | Groq `gpt-oss-20b`, tune split only, N=1 | 39/40 | 1 | not run | 0.38 s / 0.62 s | 1,264 |
| current | Groq `gpt-oss-20b` | not run | | | | |

The Groq rows are incomplete: the free-tier daily token cap (200k) ran out during tuning, so the
full N=2 Groq comparison for both prompts still has to be run (see Running).

Where the current prompt fails on OpenAI: it drops "no, no" and the repeated "really" (lost
negation and emphasis), drops words from the long dictation, turns "two plus two equals four" into
`2 + 2 = 4`, deletes the word "comma" in a sentence about the word comma, rewrites "Sorry I'm late",
adds `$` to dollar amounts, turns "first ... then ..." prose into a numbered list, and keeps a
trailing "Thanks for watching." Some of these (the `$`, the numbered list) were deliberate in the
old prompt; this set encodes the new decisions above.

Remaining failure on the new prompt: on Groq `gpt-oss-20b`, `correction-spanish` resolves the
Spanish correction but translates the English half of the mixed-language sentence into Spanish
(earlier rounds also missed the Spanish and German corrections on Groq). It passes on OpenAI.
