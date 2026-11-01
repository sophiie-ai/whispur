#!/usr/bin/env python3
"""Speech-to-text benchmark for Whispur.

Synthesizes clips from Evals/stt/sentences.jsonl with macOS `say`, sends each
clip to the batch STT providers with the request shapes the app uses
(Sources/Providers/STT/*.swift), and reports normalized WER, vocabulary-term
accuracy and latency. Python 3 standard library only; needs `say`,
`afconvert`, and `ffmpeg` for the noisy clips.

  python3 scripts/bench-stt.py --make-clips
  python3 scripts/bench-stt.py --providers groq-v3,openai,mistral
  python3 scripts/bench-stt.py --rescore /tmp/whispur-bench/stt/report.json

Keys come from GROQ_API_KEY / OPENAI_API_KEY / MISTRAL_API_KEY /
ELEVENLABS_API_KEY and are never printed. Clips and reports go to --out
(default /tmp/whispur-bench/stt); never commit them.

TTS audio is far cleaner than real speech, so absolute WER is optimistic;
compare providers relative to each other.
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
import unicodedata
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SENTENCES = ROOT / "Evals/stt/sentences.jsonl"
VOCABULARY = ["Sophiie", "Whispur", "Priya"]
USER_AGENT = "whispur-stt-bench/1.0"

# Provider configs mirror Sources/Providers/STT/*.swift.
PROVIDERS = {
    "groq-v3": {"kind": "whisper", "url": "https://api.groq.com/openai/v1/audio/transcriptions",
                "model": "whisper-large-v3", "key_env": "GROQ_API_KEY", "groq": True},
    "groq-turbo": {"kind": "whisper", "url": "https://api.groq.com/openai/v1/audio/transcriptions",
                   "model": "whisper-large-v3-turbo", "key_env": "GROQ_API_KEY", "groq": True},
    "openai": {"kind": "openai", "url": "https://api.openai.com/v1/audio/transcriptions",
               "model": "gpt-transcribe", "key_env": "OPENAI_API_KEY"},
    "mistral-mini": {"kind": "mistral", "url": "https://api.mistral.ai/v1/audio/transcriptions",
                     "model": "voxtral-mini-transcribe-3", "key_env": "MISTRAL_API_KEY"},
    "mistral-small": {"kind": "mistral", "url": "https://api.mistral.ai/v1/audio/transcriptions",
                      "model": "voxtral-small-transcribe-3", "key_env": "MISTRAL_API_KEY"},
    "elevenlabs": {"kind": "elevenlabs", "url": "https://api.elevenlabs.io/v1/speech-to-text",
                   "model": "scribe_v2", "key_env": "ELEVENLABS_API_KEY"},
}


# ---------------------------------------------------------------------------
# Clips


def load_sentences() -> list[dict]:
    return [json.loads(line) for line in SENTENCES.read_text().splitlines() if line.strip()]


def make_clips(out: Path, sentences: list[dict]) -> None:
    clips = out / "clips"
    clips.mkdir(parents=True, exist_ok=True)
    for s in sentences:
        aiff = clips / f"{s['id']}.aiff"
        wav = clips / f"{s['id']}.wav"
        subprocess.run(["say", "-v", s["voice"], "-o", str(aiff), s["say"]], check=True)
        if aiff.stat().st_size < 4096:
            raise SystemExit(f"say wrote an empty file for {s['id']} (voice {s['voice']})")
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)], check=True)
        aiff.unlink()
        if s.get("noise") is not None:
            # Pink noise mixed in at roughly `noise` dB SNR below the speech level.
            clean = wav.with_suffix(".clean.wav")
            wav.rename(clean)
            amp = 10 ** (-s["noise"] / 20) * 0.25
            subprocess.run([
                "ffmpeg", "-loglevel", "error", "-y", "-i", str(clean),
                "-f", "lavfi", "-i", f"anoisesrc=color=pink:amplitude={amp:.4f}:sample_rate=16000",
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first:normalize=0",
                "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", str(wav),
            ], check=True)
            clean.unlink()
        print(f"  {wav.name}", file=sys.stderr)


def wav_seconds(path: Path) -> float:
    return max(path.stat().st_size - 44, 0) / (16000 * 2)


# ---------------------------------------------------------------------------
# Requests


def multipart(fields: list[tuple[str, str]], file_name: str, file_field: str, audio: bytes) -> tuple[bytes, str]:
    boundary = uuid.uuid4().hex
    parts = [(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{file_field}\"; "
              f"filename=\"{file_name}\"\r\nContent-Type: audio/wav\r\n\r\n").encode() + audio + b"\r\n"]
    for name, value in fields:
        parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n".encode())
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def form_fields(cfg: dict, lang: str, vocabulary: list[str]) -> list[tuple[str, str]]:
    kind, model = cfg["kind"], cfg["model"]
    if kind == "whisper":  # GroqWhisperSTT.formFields
        fields = [("model", model), ("response_format", "text"), ("language", lang)]
        if vocabulary:
            fields.append(("prompt", ", ".join(vocabulary)))
        return fields
    if kind == "openai":  # OpenAISTT.formFields, keyword shape
        return [("model", model), ("languages[]", lang), *[("keywords[]", v) for v in vocabulary]]
    if kind == "mistral":  # MistralSTT.formFields
        return [("model", model), ("language", lang), *[("context_bias", v) for v in vocabulary]]
    if kind == "elevenlabs":  # ElevenLabsSTT.transcribe
        fields = [("model_id", model), ("file_format", "pcm_s16le_16"), ("language_code", lang)]
        if vocabulary:
            fields.append(("biased_keywords", "[" + ",".join(f'"{v}":2.0' for v in vocabulary) + "]"))
        return fields
    raise ValueError(kind)


def transcribe(provider: str, clip: Path, lang: str, vocabulary: list[str]) -> dict:
    cfg = PROVIDERS[provider]
    key = os.environ.get(cfg["key_env"])
    if not key:
        return {"error": f"{cfg['key_env']} not set"}
    fields = form_fields(cfg, lang, vocabulary)
    if cfg["kind"] == "elevenlabs":
        # The app sends the whole WAV file with file_format=pcm_s16le_16; mirror it.
        body, ctype = multipart(fields, clip.name, "file", clip.read_bytes())
        headers = {"xi-api-key": key}
    else:
        body, ctype = multipart(fields, "audio.wav", "file", clip.read_bytes())
        headers = {"Authorization": f"Bearer {key}"}
    headers.update({"Content-Type": ctype, "User-Agent": USER_AGENT})
    for attempt in range(5):
        req = urllib.request.Request(cfg["url"], data=body, method="POST", headers=headers)
        started = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=90) as resp:
                raw = resp.read()
                latency = time.monotonic() - started
        except urllib.error.HTTPError as err:
            detail = err.read().decode(errors="replace")[:300]
            if err.code == 429 or err.code >= 500:
                time.sleep(min(2 ** attempt * 2, 30))
                continue
            return {"error": f"HTTP {err.code}: {detail}"}
        except (urllib.error.URLError, TimeoutError) as err:
            time.sleep(min(2 ** attempt, 15))
            last = str(err)
            continue
        if cfg["kind"] == "whisper":
            text = raw.decode("utf-8", errors="replace").strip()
        else:
            text = (json.loads(raw).get("text") or "").strip()
        return {"text": text, "latency": latency}
    return {"error": "gave up after retries"}


# ---------------------------------------------------------------------------
# Scoring

ONES = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
        "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
TENS = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]


def en_number(n: int) -> str:
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    if n < 1000:
        return ONES[n // 100] + " hundred" + ("" if n % 100 == 0 else " " + en_number(n % 100))
    if n < 1_000_000:
        return en_number(n // 1000) + " thousand" + ("" if n % 1000 == 0 else " " + en_number(n % 1000))
    return " ".join(ONES[int(d)] for d in str(n))


def spell_digits(match: re.Match) -> str:
    digits = match.group(0).replace(",", "")
    if digits.startswith("0") and len(digits) > 1:
        return " ".join(ONES[int(d)] for d in digits)  # phone numbers, codes
    return en_number(int(digits))


COMPOUNDS = [("standup", "stand up"), ("changelog", "change log"), ("offsite", "off site")]


def normalize(text: str, lang: str) -> list[str]:
    """Lowercase, strip punctuation; spoken forms for @, dots in addresses, %, and (English) digits."""
    text = unicodedata.normalize("NFC", text).lower().replace("a.i.", "ai")
    at, dot = ("arroba", "punto") if lang == "es" else ("at", "dot")
    # Formatting choices, not recognition errors: "$4,500" = "4,500 dollars",
    # "at 3.30" = "at 3:30", "0.24" = "0 point 24", compounds written either way.
    text = re.sub(r"\$\s?(\d[\d,.]*)", r"\1 dollars", text)
    text = re.sub(r"\b(at|las|a las) (\d{1,2})\.(\d{2})\b", r"\1 \2:\3", text)
    text = re.sub(r"(\d)\.(\d)", r"\1 point \2" if lang == "en" else r"\1 coma \2", text)
    for joined, split in COMPOUNDS:
        text = re.sub(rf"\b{joined}\b", split, text)
    text = text.replace("@", f" {at} ")
    text = re.sub(r"(?<=\w)\.(?=\w)", f" {dot} ", text)
    text = re.sub(r"(?<=\w)/(?=\w)", " slash ", text)
    text = text.replace("%", " percent" if lang == "en" else " por ciento")
    if lang == "en":
        text = re.sub(r"(\d{1,2}):(\d{2})", lambda m: f"{m.group(1)} {m.group(2)}", text)
        # Phone-number style groups ("0412 345 678") are read digit by digit.
        text = re.sub(r"\b0\d*(?:[\s-]+\d+)+", lambda m: " ".join(ONES[int(d)] for d in re.sub(r"\D", "", m.group(0))), text)
        text = re.sub(r"\d+(,\d{3})*", spell_digits, text)
        text = re.sub(r"\b(\d+)(am|pm)\b", r"\1 \2", text)
    text = text.replace("-", " ").replace("'", "").replace("’", "")
    text = re.sub(r"[^\w\s]", " ", text)
    return text.split()


def edit_distance(a: list[str], b: list[str]) -> int:
    prev = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        cur = [i] + [0] * len(b)
        for j, y in enumerate(b, 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x != y))
        prev = cur
    return prev[-1]


def term_hits(ref: str, hyp: str) -> tuple[int, int]:
    """Vocabulary terms in the reference, and how many appear spelled exactly in the hypothesis."""
    wanted = [t for t in VOCABULARY if re.search(rf"\b{t}\b", ref)]
    return len(wanted), sum(bool(re.search(rf"\b{t}\b", hyp, re.IGNORECASE)) for t in wanted)


def pct(values: list[float], q: float) -> float:
    if not values:
        return float("nan")
    values = sorted(values)
    k = (len(values) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (k - lo)


def summarize(rows: list[dict]) -> dict:
    ok = [r for r in rows if "error" not in r]
    errs = sum(r["errors"] for r in ok)
    words = sum(r["ref_words"] for r in rows)
    terms = sum(r["terms"] for r in ok)
    lat = [r["latency"] for r in ok]
    return {
        "clips": len(rows), "failed_requests": len(rows) - len(ok),
        # A failed request counts as every reference word wrong.
        "wer": (errs + sum(r["ref_words"] for r in rows if "error" in r)) / words if words else float("nan"),
        "terms": terms, "term_hits": sum(r["term_hits"] for r in ok),
        "latency_p50": pct(lat, 0.5), "latency_p95": pct(lat, 0.95),
        "audio_seconds": sum(r["seconds"] for r in rows),
    }


def score_rows(results: dict, sentences: list[dict]) -> dict:
    by_id = {s["id"]: s for s in sentences}
    out = {}
    for provider, rows in results.items():
        for r in rows:
            s = by_id[r["id"]]
            ref = normalize(s["ref"], s["lang"])
            r["ref_words"] = len(ref)
            if "error" in r:
                continue
            r["errors"] = edit_distance(ref, normalize(r["text"], s["lang"]))
            r["terms"], r["term_hits"] = term_hits(s["ref"], r["text"])
        groups = {
            "all": rows,
            "en": [r for r in rows if by_id[r["id"]]["lang"] == "en"],
            "es": [r for r in rows if by_id[r["id"]]["lang"] == "es"],
            "noisy": [r for r in rows if by_id[r["id"]].get("noise") is not None],
            "groq-subset": [r for r in rows if by_id[r["id"]].get("groq")],
        }
        out[provider] = {name: summarize(g) for name, g in groups.items() if g}
    return out


def print_table(summary: dict) -> None:
    print(f"\n{'provider':15} {'subset':12} {'clips':>5} {'WER':>7} {'terms':>7} {'p50 s':>6} {'p95 s':>6} {'fail':>4}")
    for provider, groups in summary.items():
        for name, s in groups.items():
            print(f"{provider:15} {name:12} {s['clips']:>5} {s['wer'] * 100:>6.1f}% "
                  f"{s['term_hits']:>3}/{s['terms']:<3} {s['latency_p50']:>6.2f} {s['latency_p95']:>6.2f} "
                  f"{s['failed_requests']:>4}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default="/tmp/whispur-bench/stt", help="clip + report directory")
    ap.add_argument("--make-clips", action="store_true", help="synthesize clips with say/afconvert/ffmpeg")
    ap.add_argument("--providers", default="", help=f"comma-separated: {','.join(PROVIDERS)}")
    ap.add_argument("--groq-subset-only", action="store_true", default=True,
                    help="send Groq providers only the clips marked groq:true (default on; keeps audio usage small)")
    ap.add_argument("--all-clips-groq", dest="groq_subset_only", action="store_false")
    ap.add_argument("--no-vocabulary", action="store_true", help="send no vocabulary terms")
    ap.add_argument("--rescore", metavar="REPORT", help="re-score a saved report (no API calls)")
    args = ap.parse_args()

    out = Path(args.out)
    sentences = load_sentences()
    if args.make_clips:
        make_clips(out, sentences)
    if args.rescore:
        report = json.loads(Path(args.rescore).read_text())
        summary = score_rows(report["results"], sentences)
        print_table(summary)
        return 0
    providers = [p for p in args.providers.split(",") if p]
    if not providers:
        return 0
    unknown = set(providers) - set(PROVIDERS)
    if unknown:
        raise SystemExit(f"unknown providers: {', '.join(sorted(unknown))}")
    vocabulary = [] if args.no_vocabulary else VOCABULARY

    def run_provider(provider: str) -> list[dict]:
        rows = []
        for s in sentences:
            if PROVIDERS[provider].get("groq") and args.groq_subset_only and not s.get("groq"):
                continue
            clip = out / "clips" / f"{s['id']}.wav"
            r = transcribe(provider, clip, s["lang"], vocabulary)
            r.update(id=s["id"], seconds=wav_seconds(clip))
            rows.append(r)
            print(f"  {provider} {s['id']}: {'ERR ' + r['error'] if 'error' in r else r['text']}", file=sys.stderr)
        return rows

    # Providers in parallel, clips sequential within a provider (cleaner latency).
    with ThreadPoolExecutor(max_workers=len(providers)) as pool:
        results = dict(zip(providers, pool.map(run_provider, providers)))
    summary = score_rows(results, sentences)
    print_table(summary)
    path = out / f"report-{time.strftime('%Y%m%d-%H%M%S')}.json"
    path.write_text(json.dumps({
        "vocabulary": vocabulary,
        "models": {p: PROVIDERS[p]["model"] for p in providers},
        "summary": summary, "results": results,
    }, indent=2, ensure_ascii=False))
    print(f"report: {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
