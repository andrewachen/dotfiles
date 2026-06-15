#!/usr/bin/env bash
# ABOUTME: A/B harness comparing local Ollama models on the Handy dictation post-processing prompt.
# ABOUTME: Calls each model via the OpenAI-compatible endpoint (reasoning_effort:none, like Handy),
# ABOUTME: primes the cached prefix per model, and reports exact-match rule-following + warm latency.
set -uo pipefail
ENDPOINT=http://localhost:11434/v1/chat/completions
NATIVE=http://localhost:11434/api/chat   # native path exposes prompt_eval_duration for the cache check
PROMPT_FILE="$(dirname "$0")/handy_prompt.txt"
template="$(cat "$PROMPT_FILE")"
marker='${output}'        # transcript placeholder in handy_prompt.txt (also Handy's variable)
models=(qwen2.5:7b)       # add models to compare, e.g. (qwen2.5:7b qwen3:8b qwen2.5:3b)

inputs=(
"um uh"
"um so the API call to AWS returned a five hundred error"
"did the deploy finish? question mark"
"the dns server at eight dot eight dot eight dot eight is slow"
"the latency dropped to fifty milliseconds period"
"it saved us about ten dollars"
"is the cache warm question mark"
"hello"
"hey"
"ok thanks"
"let me think"
)
expected=(
""
"so the api call to aws returned a 500 error"
"did the deploy finish?"
"the dns server at 8.8.8.8 is slow"
"the latency dropped to 50 milliseconds"
"it saved us about \$10"
"is the cache warm?"
"hello"
"hey"
"ok thanks"
"let me think"
)

# connectivity check
if ! curl -sf "$ENDPOINT" -H 'Content-Type: application/json' \
     -d "$(jq -n --arg m "${models[0]}" '{model:$m,messages:[{role:"user",content:"hi"}],stream:false}')" >/dev/null 2>&1; then
  echo "ERROR: cannot reach $ENDPOINT — is ollama running?"; exit 1
fi

# Warm cache check: send the full primed prompt twice via native /api/chat, report 2nd
# prompt_eval_duration (ms). A working prefix cache collapses this to single-digit ms; a hybrid-SSM
# or small-window-SWA model can't reuse the prefix and stays at full re-eval (~hundreds of ms).
# Measure DURATION, not prompt_eval_count — the count is cosmetic (full context size even on a hit).
cache_ms() {
  local m="$1" full="$2" resp dur payload
  for _ in 1 2; do
    payload="$(jq -n --arg m "$m" --arg c "$full" \
      '{model:$m,messages:[{role:"user",content:$c}],think:false,stream:false,options:{temperature:0,num_predict:1}}')"
    resp="$(curl -s --max-time 60 "$NATIVE" -d "$payload")"
    if printf '%s' "$resp" | jq -e '.error' >/dev/null 2>&1; then   # non-thinking models reject think param
      payload="$(jq -n --arg m "$m" --arg c "$full" \
        '{model:$m,messages:[{role:"user",content:$c}],stream:false,options:{temperature:0,num_predict:1}}')"
      resp="$(curl -s --max-time 60 "$NATIVE" -d "$payload")"
    fi
  done
  dur="$(printf '%s' "$resp" | jq -r '.prompt_eval_duration // 0')"
  awk -v d="$dur" 'BEGIN{printf "%.0f", d/1e6}'
}

# Prime a model with the FULL prompt (dummy transcript) so the static prefix is KV-cached before timing.
prime() {
  local m="$1" full="${template//"$marker"/priming}"
  jq -n --arg m "$m" --arg c "$full" \
    '{model:$m,messages:[{role:"user",content:$c}],temperature:0,reasoning_effort:"none",stream:false,max_tokens:1}' \
  | curl -s --max-time 60 "$ENDPOINT" -H 'Content-Type: application/json' -d @- >/dev/null
}

for m in "${models[@]}"; do
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "MODEL: $m"
  echo "════════════════════════════════════════════════════════════"
  # free VRAM so THIS model loads fully on GPU when comparing several at once
  for other in "${models[@]}"; do [ "$other" = "$m" ] || ollama stop "$other" 2>/dev/null; done
  prime "$m"; prime "$m"   # load model + cache static prefix on this endpoint/template
  cm="$(cache_ms "$m" "${template//"$marker"/priming}")"
  if [ "$cm" -lt 60 ]; then echo "  CACHE (warm prompt_eval): ${cm}ms  ✅ reuses prefix"
  else echo "  CACHE (warm prompt_eval): ${cm}ms  ❌ full re-eval — wrong architecture for this use"; fi
  pass=0; total=0
  for i in "${!inputs[@]}"; do
    in="${inputs[$i]}"; exp="${expected[$i]}"
    full="${template//"$marker"/$in}"
    payload="$(jq -n --arg m "$m" --arg c "$full" '{model:$m,messages:[{role:"user",content:$c}],temperature:0,reasoning_effort:"none",stream:false,max_tokens:128}')"
    resp="$(curl -s --max-time 60 -w $'\n%{time_total}' "$ENDPOINT" -H 'Content-Type: application/json' -d "$payload")"; rc=$?
    if [ "$rc" -ne 0 ]; then echo "  [$((i+1))] TIMEOUT/curl-err (rc=$rc, >60s)"; total=$((total+1)); continue; fi
    t="$(printf '%s' "$resp" | tail -n1)"
    body="$(printf '%s' "$resp" | sed '$d')"
    err="$(printf '%s' "$body" | jq -r '.error.message // .error // empty' 2>/dev/null)"
    if [ -n "$err" ]; then echo "  [$((i+1))] ERROR: $err"; continue; fi
    out="$(printf '%s' "$body" | jq -r '.choices[0].message.content // empty')"
    think=""; case "$out" in *"<think"*) think=" ⚠THINK-LEAK";; esac
    got_trim="$(printf '%s' "$out" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    total=$((total+1))
    if [ "$got_trim" = "$exp" ]; then mark="PASS"; pass=$((pass+1)); else mark="FAIL"; fi
    printf '  [%d] %5.2fs  %s%s\n' "$((i+1))" "$t" "$mark" "$think"
    printf '      in:  %s\n' "$in"
    printf '      exp: %s\n' "${exp:-(empty)}"
    printf '      got: %s\n' "${out:-(empty)}"
  done
  echo "  ---- $m: $pass/$total exact-match | cache ${cm}ms"
done