# Handy dictation: local transcription + cloud/local post-processing

My speech-to-text setup. [Handy](https://handy.computer) transcribes locally with
**Parakeet V3** (CPU — no usable GPU/NPU acceleration on the Snapdragon Windows-on-ARM
box, which is expected), then runs the transcript through an LLM "post-processing" step
that restyles it into my writing style. Post-processing can run on a **cloud** model or a
**local** model — pick whichever fits your latency/cost/privacy tradeoff.

## Transcription

- Handy, local **Parakeet V3**, GPU toggle OFF (auto / CPU). Install the native `arm64` Handy
  build, not x64.

## The prompt

The post-processing prompt lives in **[`handy_prompt.txt`](./handy_prompt.txt)** — paste its
contents into Handy's post-processing prompt field. `${output}` is Handy's transcript variable,
which Handy substitutes with the transcribed text. Keeping the prompt in one file means what you
paste is byte-identical to what the benchmark
([`compare-dictation-models.sh`](./compare-dictation-models.sh)) validates — don't inline-edit a
second copy.

## Option A — cloud post-processing (gpt-5.4-nano)

- **Model:** `gpt-5.4-nano`, `reasoning_effort: none`.
- **Endpoint:** a custom OpenAI-compatible endpoint, configured locally in Handy. The URL and
  token are machine-local and intentionally **not** tracked in this (public) repo.
- `gpt-5.4-nano` is the fastest model that accepts `reasoning_effort: none` (~0.6s median, tight
  variance). `gpt-5.4-mini` is the drop-in fallback if nano ever slips on odd phrasing; a larger
  model (e.g. `gpt-5.5`) is more robust but noticeably slower.

## Option B — local post-processing (Ollama)

Same prompt, run against a small local model — faster than cloud on short dictations (no network
round-trip) and fully offline. Chosen model: **`qwen2.5:7b`** via Ollama, on an RTX A2000 12GB box.
Warm latency ~0.27s, comfortably under cloud nano.

> **Model choice is constrained by KV prefix caching.** The ~1k-token prompt is re-sent on every
> dictation, so reusing its cached KV prefix is what keeps latency low. Only **standard-attention**
> models do this. Avoid hybrid-SSM / recurrent models (e.g. `qwen3.5`) and small-window
> sliding-attention models (e.g. `gemma3`): their architectures can't reuse the prefix, forcing a
> full ~390ms prompt re-eval *every* call. See "Choosing a local model" below.

- **Build a deterministic, bounded model** so a request can't ramble or hang: see
  [`handy-qwen.Modelfile`](./handy-qwen.Modelfile) →
  `ollama create handy-qwen -f handy-qwen.Modelfile`, then point Handy at `handy-qwen`.
- **Ollama service env** (systemd drop-in):
  - `OLLAMA_KEEP_ALIVE=-1` — never unload, so the model stays warm and the ~1k-token prompt
    prefix stays KV-cached between dictations (only the short transcript is re-prefilled). This
    only pays off with a standard-attention model (see Option B intro): hybrid/SWA models re-eval
    the whole prefix regardless.
  - `OLLAMA_NUM_PARALLEL=1` — single slot, so every request reuses that cached prefix.
  - `OLLAMA_HOST=0.0.0.0:11434` — reachable from the dictation box over LAN. This exposes an
    **unauthenticated** API, so keep it on a trusted network (or bind a specific LAN IP / firewall).
- Ollama's OpenAI-compatible endpoint **accepts (ignores) `reasoning_effort: none`**, so Handy's
  hard-sent param works with no shim — and locally you're no longer floored by "the smallest cloud
  model that accepts none."

## Why reasoning_effort: none is mandatory

Handy hard-sends `reasoning_effort: "none"` on every post-processing call (see
[cjpais/Handy#1342](https://github.com/cjpais/Handy/issues/1342), unmerged fix as of 0.8.x).
Endpoints/models that reject that value fail with 400/404. Cloud: only a model that *accepts*
`"none"` works without a param-stripping proxy. Local: Ollama ignores it, so any model works.

## All-lowercase style

Everything lowercase — names, brands, acronyms included — and no trailing period. That makes this
a mechanical transform a small/fast model handles reliably.

## Notes on the prompt (don't trim it)

- **The few-shot examples are load-bearing.** They teach trailing-period removal (including right
  after a number like `$5`/`10%`) and the all-lowercase behavior. Dropping them regresses the
  output — the number-ending example in particular fixes a stray `.` the model otherwise leaves.
- **Anti-echo guard.** Small local models would otherwise regurgitate a few-shot example on trivial
  inputs (observed: "hello" → the "hey maria… gateway…" example). The prompt fences the real
  transcript in `>>>BEGIN/END TRANSCRIPT` markers, flags the examples as REFERENCE ONLY, and adds a
  short-phrase guard ("Hello" → "hello"). Necessary for local; harmless for cloud.
- **Empty-tap guard** (the top rule): returns a completely empty response for
  empty/whitespace/punctuation/filler-only input, so a stray key-tap pastes nothing. Cloud models
  honor it; **small local models do not reliably** — see Known gaps.
- **Spoken-punctuation dedup** (the punctuation-command rule): the transcriber often inserts a
  `?`/`,` from intonation *and* transcribes the spoken word ("question mark"), yielding
  `now? question mark`. The rule collapses that to a single symbol.
- I dictate punctuation by voice, so the prompt is told never to *add* punctuation I didn't speak.

## Choosing a local model

[`compare-dictation-models.sh`](./compare-dictation-models.sh) A/B's models against this exact
prompt through Handy's call path (`reasoning_effort: none`, prefix-primed), reporting exact-match
rule-following, warm latency, **and warm prompt-eval (the cache-hit check)**. Edit `models=()` to
compare. Results (June 2026, RTX A2000 12GB):

- **`qwen2.5:7b` — chosen.** 11/11 exact-match, ~0.27s warm, cache reuses the prefix (~19ms warm
  prompt-eval). Correct number/IP/punctuation-dedup handling, no echo, no spurious punctuation, and
  it even handles empty-tap and leading-filler (see Known gaps — still keep the planned code guard;
  one temp-0 run isn't a guarantee on those edge cases).
- `qwen3:8b` — 9/11, ~0.26s, also caches (~22ms). Fine, but no better than the 7b and larger.
- `qwen2.5:3b` — 8/11, ~0.20s (fastest), caches. Drops some number/abbreviation conversions; viable
  only if you want absolute minimum latency.
- **Rejected — broken cache (architectural):** `qwen3.5:4b` (the prior pick) and any `qwen3.5`
  variant. qwen3.5 is a **hybrid SSM + interleaved-attention** model; recurrent state can't be
  prefix-reused, so ollama re-evaluates the full ~1k-token prompt on *every* call (~390ms warm
  prompt-eval vs ~19ms for qwen2.5). That extra ~390ms was roughly half the old ~0.64s latency.
  `gemma3` is out for the same class of reason (small sliding-window attention). NB: the new ollama
  engine itself caches fine (`qwen3:8b` proves it) — it's specifically the hybrid/SWA architecture
  that breaks reuse. Measure `prompt_eval_duration`, not `prompt_eval_count` (the latter is cosmetic,
  reporting full context size even on a cache hit).
- **Rejected — quality:** `llama3.1:8b` (2/11 — prepends "Here is the cleaned transcript:" and leaks
  rule commentary), `llama3.2:3b` (echoes the few-shot examples), `phi4-mini` (paraphrases — violates
  word-order preservation), `gemma3:4b` (hallucinated a sentence on empty-tap).
- Avoid reasoning models whose thinking you can't disable. With `reasoning_effort: none`, qwen2.5
  runs non-thinking cleanly (it has no thinking mode); qwen3.5 also stayed clean, but lost on cache.

## Known gaps (local) — TODO

Two rules no small local model handled reliably; best fixed in **code** (a thin shim in front of
Ollama), not the prompt:

1. **Empty-tap:** filler-only input (`um uh`) should return empty; local models echo it instead.
   Guard: detect empty/whitespace/punctuation/filler-only input and return empty without calling
   the model. (This also saves a model call on stray key-taps.)
2. **Leading filler:** "um so…" should drop the leading "um"; local models keep it. Trivially
   deterministic to strip before sending.