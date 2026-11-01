#!/usr/bin/env python3
"""Cleanup-prompt eval for Whispur.

Builds cleanup requests the way the app does and scores the model's output
against Evals/cleanup/cases.jsonl. Python 3 standard library only.

  python3 scripts/eval-cleanup.py --provider openai --prompt new
  python3 scripts/eval-cleanup.py --provider groq --prompt current --runs 1
  python3 scripts/eval-cleanup.py --self-test
  python3 scripts/eval-cleanup.py --cases-file "$HOME/Library/Application Support/Whispur/MyEvalCases.jsonl"

--prompt new      system prompt = Prompts.defaultCleanup in the working tree,
                  user message = CleanupMessage (vocabulary block, wrapped
                  transcript, trailing output contract).
--prompt current  system prompt = Prompts.defaultCleanup at origin/main (via
                  git show), with origin/main's request shape: the same
                  CleanupMessage shape when origin/main has
                  cleanupOutputContract, else the legacy shape (vocabulary
                  appended to the system prompt, bare wrapped transcript).

Keys come from GROQ_API_KEY / OPENAI_API_KEY and are never printed. See
Evals/cleanup/README.md for the scoring rules.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROMPTS_SWIFT = "Sources/Pipeline/Prompts.swift"
STYLES_SWIFT = "Sources/Pipeline/WritingStyles.swift"
CASES_PATH = ROOT / "Evals/cleanup/cases.jsonl"
GOLDEN_PATH = ROOT / "Evals/cleanup/golden/user-message.txt"
GOLDEN_CHAT_PROMPT_PATH = ROOT / "Evals/cleanup/golden/system-prompt-chat.txt"
# A case's `style` is the kind of app it is dictated into: an AppGroup raw
# value, or "default" for an app outside every group. Every group is on the
# Default writing style, as on a fresh install.
APP_STYLES = ("default", "chat", "email", "docs", "code")
USER_AGENT = "whispur-cleanup-eval/1.0"

# Mirrors LLMProviderID.defaultModel and OpenAIChatFormat.body in
# Sources/Providers/LLM/{LLMProvider,OpenAILLM}.swift.
PROVIDERS = {
    "groq": {
        "url": "https://api.groq.com/openai/v1/chat/completions",
        "model": "openai/gpt-oss-20b",
        "key_env": "GROQ_API_KEY",
    },
    "openai": {
        "url": "https://api.openai.com/v1/chat/completions",
        "model": "gpt-6-luna",
        "key_env": "OPENAI_API_KEY",
    },
}

REASONING_OFF_MODELS = ("gpt-6-luna", "gpt-6-sol", "gpt-6.1-terra")
REASONING_PREFIXES = ("gpt-6", "gpt-5", "o1", "o3", "o4")


def request_params(model: str, provider: str, max_tokens: int) -> dict:
    """Mirrors OpenAIChatFormat.parameterStyle + body (temperature 0)."""
    name = model.lower().split("/")[-1]
    if name.startswith("gpt-oss"):
        if provider == "groq":
            return {"max_completion_tokens": max_tokens, "reasoning_effort": "low",
                    "include_reasoning": False, "temperature": 0.0}
        return {"max_tokens": max_tokens, "temperature": 0.0}
    if provider == "openai":
        if name.startswith(REASONING_OFF_MODELS):
            return {"max_completion_tokens": max_tokens, "reasoning_effort": "none", "temperature": 0.0}
        if name.startswith(REASONING_PREFIXES) and "chat" not in name:
            return {"max_completion_tokens": max_tokens, "reasoning_effort": "low"}
    return {"max_tokens": max_tokens, "temperature": 0.0}


# ---------------------------------------------------------------------------
# Swift string literal extraction


def swift_multiline_literal(source: str, name: str) -> str:
    """Returns the value of `static let <name> = \"\"\" … \"\"\"`.

    Implements the parts of Swift's multi-line literal rules the prompt file
    uses: indentation stripping by the closing delimiter, `\\` line
    continuation, and the standard escapes. Interpolation is rejected.
    """
    match = re.search(r"static let " + re.escape(name) + r' = """\n', source)
    if not match:
        raise SystemExit(f"could not find `static let {name}` in Prompts.swift")
    lines = []
    for line in source[match.end():].split("\n"):
        if line.strip() == '"""':
            indent = line[: len(line) - len(line.lstrip())]
            break
        lines.append(line)
    else:
        raise SystemExit(f"unterminated literal for {name}")
    stripped = []
    for line in lines:
        if line.strip() == "":
            stripped.append("")
        elif line.startswith(indent):
            stripped.append(line[len(indent):])
        else:
            raise SystemExit(f"{name}: line is less indented than the closing delimiter: {line!r}")
    raw = "\n".join(stripped)

    out = []
    i = 0
    while i < len(raw):
        ch = raw[i]
        if ch != "\\":
            out.append(ch)
            i += 1
            continue
        nxt = raw[i + 1] if i + 1 < len(raw) else ""
        if nxt == "\n":  # line continuation
            i += 2
        elif nxt in ('"', "\\", "'"):
            out.append(nxt)
            i += 2
        elif nxt == "n":
            out.append("\n")
            i += 2
        elif nxt == "t":
            out.append("\t")
            i += 2
        elif nxt == "0":
            out.append("\0")
            i += 2
        elif nxt == "u" and raw[i + 2: i + 3] == "{":
            end = raw.index("}", i)
            out.append(chr(int(raw[i + 3: end], 16)))
            i = end + 1
        elif nxt == "(":
            raise SystemExit(f"{name}: string interpolation is not supported by the eval parser")
        else:
            raise SystemExit(f"{name}: unsupported escape \\{nxt}")
    return "".join(out)


def load_swift_source(which: str, path: str = PROMPTS_SWIFT) -> str:
    if which == "new":
        return (ROOT / path).read_text()
    return subprocess.run(
        ["git", "-C", str(ROOT), "show", f"origin/main:{path}"],
        check=True, capture_output=True, text=True,
    ).stdout


# ---------------------------------------------------------------------------
# Request building (mirrors the app)

TRANSCRIPT_TAG = "dictation-to-clean"
VOCAB_TAG = "vocabulary"
_TAG_RE = re.compile(r"<(\s*/?\s*)(" + TRANSCRIPT_TAG + "|" + VOCAB_TAG + ")", re.IGNORECASE)


def neutralize_tags(text: str) -> str:
    """Mirrors CleanupMessage.neutralizeTags."""
    return _TAG_RE.sub(lambda m: "<​" + m.group(1) + m.group(2), text)


def vocabulary_terms(vocabulary: list[str]) -> list[str]:
    """Mirrors CleanupMessage.vocabularyTerms."""
    terms = []
    for term in vocabulary:
        joined = " ".join(re.split(r"\r\n|[\n\r  \x0b\x0c\x85]", term)).strip()
        if joined:
            terms.append(neutralize_tags(joined))
    return terms


def new_user_message(transcript: str, vocabulary: list[str], contract: str) -> str:
    """Mirrors CleanupMessage.userMessage."""
    sections = []
    terms = vocabulary_terms(vocabulary)
    if terms:
        sections.append(f"<{VOCAB_TAG}>\n" + "\n".join(terms) + f"\n</{VOCAB_TAG}>")
    sections.append(f"<{TRANSCRIPT_TAG}>\n{neutralize_tags(transcript)}\n</{TRANSCRIPT_TAG}>")
    sections.append(contract)
    return "\n\n".join(sections)


def current_request(system_prompt: str, transcript: str, vocabulary: list[str]) -> tuple[str, str]:
    """origin/main's buildSystemPrompt + wrapForCleanup."""
    terms = [t.strip() for t in vocabulary if t.strip()]
    if terms:
        system_prompt += (
            "\n\nPreserve these proper nouns / terms exactly as spelled when they appear "
            "(do not paraphrase, translate, or correct them): " + ", ".join(terms) + "."
        )
    safe = transcript.replace("</dictation-to-clean>", "<​/dictation-to-clean>")
    return system_prompt, f"<dictation-to-clean>\n{safe}\n</dictation-to-clean>"


def cleanup_max_tokens(chars: int) -> int:
    """Mirrors LLMRequest.cleanupMaxTokens."""
    return min(max(chars // 2 + 512, 1024), 8192)


class RequestBuilder:
    def __init__(self, which: str):
        self.which = which
        source = load_swift_source(which)
        self.system_prompt = swift_multiline_literal(source, "defaultCleanup")
        self.contract = (swift_multiline_literal(source, "cleanupOutputContract")
                         if "static let cleanupOutputContract" in source else None)
        # Per-app formatting sections (Prompts.cleanupPrompt(for:group:)).
        # A prompt without them uses the shared prompt in every app.
        styles = load_swift_source(which, STYLES_SWIFT)
        self.group_sections = {}
        if "static let chatFormatting" in styles:
            self.group_sections["chat"] = swift_multiline_literal(styles, "chatFormatting")
        marker = re.search(r'static let styleInsertionMarker = "([^"]*)"', styles)
        self.marker = marker.group(1) if marker else None

    def system_prompt_for(self, style: str) -> str:
        """Mirrors Prompts.cleanupPrompt(for: .standard, group:, customPrompt: "")."""
        if style not in APP_STYLES:
            raise SystemExit(f"unknown case style {style!r}; expected one of {', '.join(APP_STYLES)}")
        section = self.group_sections.get(style)
        if section is None:
            return self.system_prompt
        at = self.system_prompt.index(self.marker)
        block = (f"App: {style.capitalize()}. This formatting rule takes priority over the cleaning rules "
                 f"above and the examples below where they conflict:\n{section}\n\n")
        return self.system_prompt[:at] + block + self.system_prompt[at:]

    def build(self, transcript: str, vocabulary: list[str], style: str = "default") -> tuple[str, str]:
        system_prompt = self.system_prompt_for(style)
        if self.contract is not None:
            return system_prompt, new_user_message(transcript, vocabulary, self.contract)
        return current_request(system_prompt, transcript, vocabulary)


# ---------------------------------------------------------------------------
# Transport


class GroqThrottle:
    """Client-side token bucket for Groq's free-tier tokens-per-minute limit.

    Groq counts prompt tokens plus the requested completion budget, so each
    request reserves an estimate of both, and the bucket is resynced from
    the x-ratelimit-* response headers.
    """

    def __init__(self, tpm: int = 8000):
        self.capacity = tpm
        self.tokens = float(tpm)
        self.updated = time.monotonic()

    def _refill(self):
        now = time.monotonic()
        self.tokens = min(self.capacity, self.tokens + (now - self.updated) * self.capacity / 60.0)
        self.updated = now

    def reserve(self, cost: int):
        cost = min(cost, self.capacity)
        while True:
            self._refill()
            if self.tokens >= cost:
                self.tokens -= cost
                return
            time.sleep((cost - self.tokens) * 60.0 / self.capacity + 0.05)

    def sync(self, headers):
        limit = headers.get("x-ratelimit-limit-tokens")
        remaining = headers.get("x-ratelimit-remaining-tokens")
        if limit and limit.isdigit():
            self.capacity = int(limit)
        if remaining and remaining.lstrip("-").isdigit():
            self._refill()
            self.tokens = min(self.tokens, float(remaining))


def parse_duration(value: str | None) -> float | None:
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        pass
    total = 0.0
    for amount, unit in re.findall(r"([\d.]+)(ms|h|m|s)", value):
        total += float(amount) * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[unit]
    return total or None


REASONING_RE = re.compile(r"<(think|thinking)>.*?</\1>", re.IGNORECASE | re.DOTALL)
UNCLOSED_REASONING_RE = re.compile(r"<(think|thinking)>.*\Z", re.IGNORECASE | re.DOTALL)


def strip_reasoning(text: str) -> str:
    """Mirrors LLMOutputSanitizer.stripReasoning."""
    text = REASONING_RE.sub("", text)
    text = UNCLOSED_REASONING_RE.sub("", text)
    return text.strip()


class TokenCap:
    """Stops new requests once the run has used `limit` tokens (prompt + completion)."""

    def __init__(self, limit: int | None):
        self.limit = limit
        self.used = 0

    def check(self):
        if self.limit is not None and self.used >= self.limit:
            raise TokenCapReached(self.used)

    def add(self, result: dict):
        self.used += (result.get("prompt_tokens") or 0) + (result.get("completion_tokens") or 0)


class TokenCapReached(Exception):
    pass


class QuotaExhausted(Exception):
    """The provider's daily quota ran out; the runs so far are still scored and saved."""


def call(provider: str, model: str, system_prompt: str, user_message: str, max_tokens: int,
         throttle: GroqThrottle | None):
    cfg = PROVIDERS[provider]
    key = os.environ.get(cfg["key_env"])
    if not key:
        raise SystemExit(f"{cfg['key_env']} is not set")
    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_message},
        ],
        **request_params(model, provider, max_tokens),
    }
    data = json.dumps(body).encode()
    estimate = (len(system_prompt) + len(user_message)) // 3 + max_tokens
    for attempt in range(12):
        if throttle:
            throttle.reserve(estimate)
        req = urllib.request.Request(cfg["url"], data=data, method="POST", headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "User-Agent": USER_AGENT,
        })
        started = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                payload = json.loads(resp.read())
                latency = time.monotonic() - started
                if throttle:
                    throttle.sync(resp.headers)
        except urllib.error.HTTPError as err:
            if throttle:
                throttle.sync(err.headers)
            if err.code == 429:
                detail = err.read().decode(errors="replace")
                if "per day" in detail:
                    raise QuotaExhausted(f"{provider}: daily token quota exhausted: {detail[:300]}")
            if err.code == 429 or err.code >= 500:
                wait = min(parse_duration(err.headers.get("retry-after")) or 2 ** attempt, 60)
                if throttle:
                    throttle.tokens = 0
                print(f"\n  HTTP {err.code}, retrying in {wait:.0f}s", file=sys.stderr, flush=True)
                time.sleep(wait + 0.25)
                continue
            detail = err.read().decode(errors="replace")[:300]
            return {"error": f"HTTP {err.code}: {detail}"}
        except (urllib.error.URLError, TimeoutError) as err:
            print(f"\n  {err}, retrying", file=sys.stderr, flush=True)
            time.sleep(min(2 ** attempt, 30))
            continue
        choice = (payload.get("choices") or [{}])[0]
        message = choice.get("message") or {}
        usage = payload.get("usage") or {}
        return {
            "text": strip_reasoning(message.get("content") or ""),
            "finish_reason": choice.get("finish_reason"),
            "refusal": message.get("refusal"),
            "latency": latency,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "cached_tokens": (usage.get("prompt_tokens_details") or {}).get("cached_tokens"),
        }
    return {"error": "gave up after retries"}


# ---------------------------------------------------------------------------
# Scoring

QUOTE_MAP = str.maketrans({"‘": "'", "’": "'", "“": '"', "”": '"', " ": " "})
LOOSE_PUNCT_RE = re.compile(r"[.,;:!。、]")


def normalize(text: str, loose: bool = False, strict_period: bool = False) -> str:
    """Light normalization applied to both sides before comparing.

    - zero-width spaces dropped, curly quotes and NBSP straightened
    - runs of spaces/tabs collapsed, each line trimmed, blank lines dropped
    - one trailing "." removed (a final period is optional; "?" and "!" are not),
      unless strict_period (a bare address or command must not gain a period)
    - "" and "EMPTY" are the same outcome (both mean no speech to the app)
    - loose cases also drop . , ; : ! and lowercase, for cases that test
      content rather than punctuation
    """
    text = text.replace("​", "").translate(QUOTE_MAP)
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.strip().split("\n")]
    text = "\n".join(line for line in lines if line)
    if text.upper() == "EMPTY":
        return ""
    if not strict_period and text.endswith(".") and not text.endswith(".."):
        text = text[:-1]
    if loose:
        text = re.sub(r" +", " ", LOOSE_PUNCT_RE.sub("", text)).lower()
    return text


def score(case: dict, output: str) -> bool:
    loose = case.get("loose_punctuation", False)
    strict = case.get("strict_period", False)
    got = normalize(output, loose, strict)
    return any(got == normalize(t, loose, strict) for t in [case["expected"], *case.get("alternates", [])])


def pct(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    values = sorted(values)
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


# ---------------------------------------------------------------------------


def load_cases(path: Path) -> list[dict]:
    """Reads a cases.jsonl-shaped file; exits with the line number on a malformed case."""
    if not path.is_file():
        raise SystemExit(f"cases file not found: {path}")
    cases = []
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            case = json.loads(line)
        except json.JSONDecodeError as err:
            raise SystemExit(f"{path}:{n}: invalid JSON: {err}")
        missing = [k for k in ("id", "input", "expected") if k not in case]
        if missing:
            raise SystemExit(f"{path}:{n}: missing {', '.join(missing)}")
        case.setdefault("critical", False)
        cases.append(case)
    if not cases:
        raise SystemExit(f"no cases in {path}")
    return cases


def self_test() -> int:
    builder = RequestBuilder("new")
    golden_input = json.loads((ROOT / "Evals/cleanup/golden/input.json").read_text())
    built = new_user_message(golden_input["transcript"], golden_input["vocabulary"], builder.contract)
    expected = GOLDEN_PATH.read_text()
    ok = built == expected
    print(f"user message matches golden: {ok}")
    if not ok:
        print("--- built ---\n" + built + "\n--- golden ---\n" + expected)
    chat_ok = builder.system_prompt_for("chat") == GOLDEN_CHAT_PROMPT_PATH.read_text()
    print(f"chat system prompt matches golden: {chat_ok}")
    ok = ok and chat_ok
    words = len(builder.system_prompt.split())
    print(f"new system prompt: {words} words, {len(builder.system_prompt)} chars")
    current = RequestBuilder("current")
    print(f"current system prompt: {len(current.system_prompt.split())} words, {len(current.system_prompt)} chars")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--provider", choices=sorted(PROVIDERS), default="openai")
    ap.add_argument("--model", help="model id (default: the provider's app default)")
    ap.add_argument("--token-cap", type=int, default=None,
                    help="stop sending requests once the run has used this many tokens (prompt + completion)")
    ap.add_argument("--prompt", choices=["current", "new"], default="new")
    ap.add_argument("--runs", type=int, default=2, help="runs per case (default 2)")
    ap.add_argument("--cases-file", metavar="PATH", default=str(CASES_PATH),
                    help="JSONL cases file (default Evals/cleanup/cases.jsonl), e.g. the app's MyEvalCases.jsonl")
    ap.add_argument("--cases", help="comma-separated case ids")
    ap.add_argument("--split", choices=["all", "tune", "heldout", "mine"], default="all")
    ap.add_argument("--show-heldout", action="store_true", help="print diffs for held-out failures too")
    ap.add_argument("--concurrency", type=int, default=None, help="parallel requests (Groq is always 1)")
    ap.add_argument("--report", help="JSON report path (default /tmp/whispur-eval/<prompt>-<provider>-<ts>.json)")
    ap.add_argument("--self-test", action="store_true", help="check request building against the golden file")
    ap.add_argument("--rescore", metavar="REPORT",
                    help="re-score the outputs saved in a previous JSON report against the current cases (no API calls)")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    previous = None
    if args.rescore:
        previous = json.loads(Path(args.rescore).read_text())
        args.prompt, args.provider, args.runs = previous["prompt"], previous["provider"], previous["runs_per_case"]
        args.model = previous.get("model")
    model = args.model or PROVIDERS[args.provider]["model"]

    cases = load_cases(Path(args.cases_file).expanduser())
    if args.cases:
        wanted = set(args.cases.split(","))
        unknown = wanted - {c["id"] for c in cases}
        if unknown:
            raise SystemExit(f"unknown case ids: {', '.join(sorted(unknown))}")
        cases = [c for c in cases if c["id"] in wanted]
    if args.split != "all":
        cases = [c for c in cases if c.get("split", "tune") == args.split]

    builder = RequestBuilder(args.prompt)
    throttle = GroqThrottle() if args.provider == "groq" else None
    concurrency = 1 if args.provider == "groq" else (args.concurrency or 6)

    jobs = []
    for case in cases:
        system_prompt, user_message = builder.build(case["input"], case.get("vocabulary", []),
                                                    case.get("style", "default"))
        max_tokens = cleanup_max_tokens(len(case["input"]))
        for run in range(args.runs):
            jobs.append((case, run, system_prompt, user_message, max_tokens))

    if previous is not None:
        saved = {c["id"]: c["runs"] for c in previous["cases"]}
        missing = [c["id"] for c in cases if c["id"] not in saved]
        if missing:
            raise SystemExit(f"report has no runs for: {', '.join(missing)}")
        results = []
        for case in cases:
            for r in saved[case["id"]]:
                r["passed"] = "error" not in r and r.get("finish_reason") != "length" and score(case, r["text"])
                results.append(r)
    else:
        cap = TokenCap(args.token_cap)

        stopped = []

        def work(job):
            case, run, system_prompt, user_message, max_tokens = job
            if stopped:
                return None
            try:
                cap.check()
                result = call(args.provider, model, system_prompt, user_message, max_tokens, throttle)
            except TokenCapReached:
                return None
            except QuotaExhausted as err:
                stopped.append(str(err))
                print(f"\n{err}\nstopping; scoring the runs that finished", file=sys.stderr)
                return None
            cap.add(result)
            result.update(id=case["id"], run=run)
            result["passed"] = "error" not in result and result.get("finish_reason") != "length" and score(case, result["text"])
            return result

        print(f"{args.prompt} prompt on {args.provider} ({model}): "
              f"{len(cases)} cases x {args.runs} runs", file=sys.stderr)
        with ThreadPoolExecutor(max_workers=concurrency) as pool:
            results = []
            for i, res in enumerate(pool.map(work, jobs), 1):
                if res is not None:
                    results.append(res)
                print(f"\r  {i}/{len(jobs)}", end="", file=sys.stderr, flush=True)
        print(file=sys.stderr)
        skipped = len(jobs) - len(results)
        if args.token_cap is not None or stopped:
            print(f"tokens used: {cap.used} (cap {args.token_cap}); runs not sent: {skipped}", file=sys.stderr)
            if skipped:
                ran = {r["id"] for r in results}
                cases = [c for c in cases if c["id"] in ran]

    case_rows = []
    for case in cases:
        runs = [r for r in results if r["id"] == case["id"]]
        case_rows.append({"case": case, "runs": runs, "passes": sum(r["passed"] for r in runs)})

    # Failure diffs.
    for row in case_rows:
        case = row["case"]
        heldout = case.get("split") == "heldout"
        if row["passes"] == len(row["runs"]):
            continue
        if heldout and not args.show_heldout:
            continue
        flag = " CRITICAL" if case["critical"] else ""
        print(f"\nFAIL {case['id']}{flag} ({row['passes']}/{len(row['runs'])})")
        print(f"  input:    {case['input']!r}")
        print(f"  expected: {case['expected']!r}")
        seen = set()
        for r in row["runs"]:
            if r["passed"]:
                continue
            got = r.get("error") or r.get("text")
            if r.get("finish_reason") == "length":
                got = f"[truncated] {got}"
            if got in seen:
                continue
            seen.add(got)
            print(f"  got:      {got!r}")

    def summarize(rows):
        runs = [r for row in rows for r in row["runs"]]
        ok = [r for r in runs if "error" not in r]
        crit_runs = [r for row in rows if row["case"]["critical"] for r in row["runs"]]
        lat = [r["latency"] for r in ok]
        toks = [r["prompt_tokens"] for r in ok if r.get("prompt_tokens")]
        return {
            "cases": len(rows),
            "runs": len(runs),
            "passed_runs": sum(r["passed"] for r in runs),
            "pass_rate": (sum(r["passed"] for r in runs) / len(runs)) if runs else float("nan"),
            "cases_all_runs_pass": sum(row["passes"] == len(row["runs"]) for row in rows),
            "critical_failures": sum(not r["passed"] for r in crit_runs),
            "critical_cases_failed": sum(row["case"]["critical"] and row["passes"] < len(row["runs"]) for row in rows),
            "errors": len(runs) - len(ok),
            "truncated": sum(r.get("finish_reason") == "length" for r in ok),
            "latency_p50": pct(lat, 0.5),
            "latency_p95": pct(lat, 0.95),
            "prompt_tokens_mean": statistics.mean(toks) if toks else float("nan"),
            "prompt_tokens_total": sum(toks),
            "completion_tokens_total": sum(r.get("completion_tokens") or 0 for r in ok),
        }

    summary = {
        "all": summarize(case_rows),
        "tune": summarize([r for r in case_rows if r["case"].get("split", "tune") == "tune"]),
        "heldout": summarize([r for r in case_rows if r["case"].get("split") == "heldout"]),
        "mine": summarize([r for r in case_rows if r["case"].get("split") == "mine"]),
    }

    print(f"\n{args.prompt} / {args.provider} ({model}), {args.runs} runs per case")
    print(f"{'split':8} {'cases':>5} {'pass':>9} {'crit fails':>10} {'p50 s':>6} {'p95 s':>6} {'in tok':>7}")
    for name, s in summary.items():
        if not s["cases"]:
            continue
        print(f"{name:8} {s['cases']:>5} {s['passed_runs']:>4}/{s['runs']:<4} {s['critical_failures']:>10} "
              f"{s['latency_p50']:>6.2f} {s['latency_p95']:>6.2f} {s['prompt_tokens_mean']:>7.0f}")
    if summary["all"]["errors"] or summary["all"]["truncated"]:
        print(f"errors: {summary['all']['errors']}, truncated: {summary['all']['truncated']}")

    report_path = Path(args.report) if args.report else Path(
        f"/tmp/whispur-eval/{args.prompt}-{args.provider}-{model.split('/')[-1]}-{time.strftime('%Y%m%d-%H%M%S')}.json")
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps({
        "prompt": args.prompt,
        "provider": args.provider,
        "model": model,
        "runs_per_case": args.runs,
        "system_prompt_words": len(builder.system_prompt.split()),
        "summary": summary,
        "cases": [{"id": row["case"]["id"], "split": row["case"].get("split", "tune"),
                   "critical": row["case"]["critical"], "passes": row["passes"],
                   "runs": row["runs"]} for row in case_rows],
    }, indent=2, ensure_ascii=False))
    print(f"report: {report_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
