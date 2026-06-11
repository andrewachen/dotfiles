# Handy dictation: local transcription + cloud post-processing

My speech-to-text setup. [Handy](https://handy.computer) transcribes locally with
**Parakeet V3** (CPU — no usable GPU/NPU acceleration on the Snapdragon Windows-on-ARM
box, which is expected), then runs the transcript through an LLM "post-processing" step
that restyles it into my writing style.

## Settings

- **Transcription:** Handy, local Parakeet V3, GPU toggle OFF (auto / CPU). Install the
  native `arm64` Handy build, not x64.
- **Post-processing model:** `gpt-5.4-nano`, `reasoning_effort: none`.
- **Endpoint:** a custom OpenAI-compatible endpoint, configured locally in Handy. The URL
  and token are machine-local and intentionally **not** tracked in this (public) repo.

### Why these choices

- **`reasoning_effort: none` is mandatory.** Handy hard-sends `reasoning_effort: "none"` on
  every post-processing call (see [cjpais/Handy#1342](https://github.com/cjpais/Handy/issues/1342),
  unmerged fix as of 0.8.x). Endpoints/models that reject that value fail with 400/404. Only a
  model that *accepts* `"none"` works without running a param-stripping proxy/shim.
- **`gpt-5.4-nano`** is the fastest model that accepts `reasoning_effort: none` (~0.6s median,
  tight variance). `gpt-5.4-mini` is the drop-in fallback if nano ever slips on odd phrasing;
  a larger model (e.g. `gpt-5.5`) is more robust but noticeably slower.
- **All-lowercase style.** Everything lowercase — names, brands, acronyms included — and no
  trailing period. That makes this a mechanical transform a small/fast model handles reliably.

## The prompt

Paste into Handy's post-processing prompt field. `${output}` is Handy's transcript variable.

```
Clean up and restyle my dictated transcript.

FIRST, before anything else: if the transcript is empty, only whitespace, only
punctuation/symbols, or contains only filler words (um, uh) with no real spoken content,
output NOTHING — a completely empty response with zero characters. No quotes, no spaces,
no explanation, no placeholder. This happens when I tap the key without speaking.

Otherwise, clean up and restyle. Preserve exact meaning and word order — do not paraphrase
or reorder. The ONLY word-level changes allowed are removing filler words, converting number
words to digits, and formatting IP addresses.

Cleanup:
1. Fix spelling errors.
2. Convert number words to digits: twenty-five → 25, ten percent → 10%, five dollars → $5.
3. Render spoken IP addresses in dotted-decimal notation: "ten dot zero dot one dot one" → 10.0.1.1.
4. Spoken punctuation words are COMMANDS, not literal text: period → ., comma → ,,
   question mark → ?, exclamation point → !, new line → a line break. Always delete the
   literal word(s). If the transcriber already placed that symbol nearby, keep exactly ONE
   symbol — never output both the symbol and the word, and never double the symbol.
5. Remove filler words used as filler (um, uh, and "like" only when it's filler).
6. Keep the original language (if I spoke French, keep it in French).
7. I control punctuation by voice — do NOT add commas, periods, or question marks I didn't speak.

Style:
8. Make the ENTIRE text lowercase — names, brands, acronyms, everything.
9. Always remove the period at the very end of the result (even right after a number). Keep a trailing "?" or "!".

Return only the cleaned, restyled transcript — no quotes or commentary.

Examples:
Input: (empty, only silence, only punctuation, or only filler like um/uh)
Output: (nothing at all — a completely empty response)

Input: um, can you send the report to Sarah by Friday question mark
Output: can you send the report to sarah by friday?

Input: Is this working now? question mark.
Output: is this working now?

Input: I think the API integration with Stripe is still broken on Android, and it is failing like twenty-five percent of the time.
Output: i think the api integration with stripe is still broken on android, and it is failing 25% of the time

Input: hey Maria comma the gateway at ten dot zero dot one dot one is down period
Output: hey maria, the gateway at 10.0.1.1 is down

Input: the rollout cost about five dollars period
Output: the rollout cost about $5

Transcript:
${output}
```

## Notes on the prompt (don't trim it)

- **The few-shot examples are load-bearing.** They teach trailing-period removal (including
  right after a number like `$5`/`10%`) and the all-lowercase behavior. Dropping them regresses
  the output — the number-ending example in particular fixes a stray `.` the model otherwise leaves.
- **Empty-tap guard** (the top rule): returns a completely empty response for
  empty/whitespace/punctuation/filler-only input, so a stray key-tap pastes nothing. It's
  conservative by design — real short inputs like "ok" still pass through.
- **Spoken-punctuation dedup** (rule 4): the transcriber often inserts a `?`/`,` from intonation
  *and* transcribes the spoken word ("question mark"), yielding `now? question mark`. Rule 4
  collapses that to a single symbol.
- I dictate punctuation by voice, so the prompt is told never to *add* punctuation I didn't speak.
