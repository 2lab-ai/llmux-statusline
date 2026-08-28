#!/bin/bash
# Golden tests for llmux-statusline. The llmux segment MUST report summed
# REMAINING capacity ("3 accounts with 50% left each => 150%"), with the
# window-coupling caps. These fixtures fail if the semantics regress to
# usage-sums, drop the coupling, or stop treating cold accounts as 100%.
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT=../statusline.sh
STRIP=$'s/\033\\[[0-9;]*m//g'
REV=$'\033[7m'
INPUT='{"model":{"display_name":"T"},"workspace":{"current_dir":"/tmp"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
fail=0

run_with_fixture() { # $1 fixture file [$2 keep-colors] -> statusline output
  local stub filter
  stub="$(mktemp -d)/llmux"
  printf '#!/bin/bash\ncat "%s"\n' "$PWD/$1" > "$stub"
  chmod +x "$stub"
  if [ "${2:-}" = "raw" ]; then filter=cat; else filter=(sed "$STRIP"); fi
  echo "$INPUT" | ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$stub" \
    LLMUX_STATUSLINE_NOW="${FAKE_NOW:-}" \
    bash "$SCRIPT" | "${filter[@]}"
}

expect_contains() { # $1 name, $2 haystack, $3 needle
  if [[ "$2" == *"$3"* ]]; then
    echo "ok   $1"
  else
    echo "FAIL $1"; echo "  expected: $3"; echo "  got:      $2"; fail=1
  fi
}

# 1. The canonical spec: 3 claude accounts with 50% left on every window => 150%.
#    (coupling caps don't bite: rem5h=50 <= 5*rem7d=250, rem7df=50 <= 2*rem7d=100)
out=$(run_with_fixture fixture-fleet.json)
expect_contains "remaining-sum 150%" "$out" "CLD(3) 5h: 150% 7d: 150% 7df: 150%"
expect_contains "codex remaining"    "$out" "CDX(1) 7d: 96%"

# 2. Coupling + cold:
#    exhausted: rem7d=0  -> 5h/7df forced to 0 despite fresh windows
#    tight7d:   rem7d=10 -> rem5h_eff=min(90,50)=50, rem7df_eff=min(100,20)=20
#    cold:      null windows -> 100 everywhere
#    sums: 5h 0+50+100=150, 7d 0+10+100=110, 7df 0+20+100=120
out=$(run_with_fixture fixture-coupling.json)
expect_contains "coupling caps + cold" "$out" "CLD(3) 5h: 150% 7d: 110% 7df: 120%"
expect_contains "codex coupling fixture" "$out" "CDX(1) 7d: 75%"

# 2b. Reset countdowns: soonest 7d reset among USABLE accounts per group
#     (excluded accounts carry a 5s decoy reset that must be ignored),
#     duration tiers 1d2h / 17h10m / 17m10s, and the <1h red countdown
#     inverts on alternating invocations.
out=$(run_with_fixture fixture-fleet.json)
expect_contains "countdown >=1d format" "$out" "7df: 150% ↻1d2h"
expect_contains "codex countdown"       "$out" "CDX(1) 7d: 96% ↻1d2h"
out=$(run_with_fixture fixture-coupling.json)
expect_contains "countdown <1d format + decoy ignored" "$out" "7df: 120% ↻17h10m"
expect_contains "countdown <1h format" "$out" "↻17m10s"
# Blink phase is wall-clock derived ((epoch/5) parity) so 20 concurrent
# sessions polling every ~5s agree on the phase — no shared mutable state.
a=$(FAKE_NOW=10 run_with_fixture fixture-coupling.json raw)  # bucket 2 -> even -> off
b=$(FAKE_NOW=15 run_with_fixture fixture-coupling.json raw)  # bucket 3 -> odd  -> on
c=$(FAKE_NOW=20 run_with_fixture fixture-coupling.json raw)  # bucket 4 -> even -> off
if [[ "$b" == *"${REV}"*17m10s* ]] && [[ "$a" != *"${REV}"*17m10s* ]] && [[ "$c" != *"${REV}"*17m10s* ]]; then
  echo "ok   <1h blink follows wall-clock parity"
else
  echo "FAIL <1h blink follows wall-clock parity"; fail=1
fi

# (both fixtures also carry auth_failed and paused accounts with fresh
#  windows; the expectations above pass only if they are excluded from
#  sums AND the (N) count)

# 3. Direct mode (no llmux): the session windows in REMAINING terms with the
#    5h coupling cap and a reset countdown on 7d.
DIRECT='{"model":{"display_name":"T"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":58},"seven_day":{"used_percentage":45,"resets_at":RESETS}}}'
out=$(echo "${DIRECT/RESETS/$(( $(date +%s) + 274000 ))}" \
  | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent bash "$SCRIPT" | sed "$STRIP")
expect_contains "direct remaining"      "$out" "5h: 42% 7d: 55% "
expect_contains "direct 7d countdown"   "$out" "↻3d4h"
COUPLED='{"model":{"display_name":"T"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":92}}}'
out=$(echo "$COUPLED" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent bash "$SCRIPT" | sed "$STRIP")
expect_contains "direct 5h coupling cap" "$out" "5h: 40% 7d: 8%"

# 3b. Countdown urgency/blink rules are COMMON to direct mode: <1h reset
#     renders red and inverts on the odd wall-clock bucket, same as fleet.
DIRECT3='{"model":{"display_name":"T"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"seven_day":{"used_percentage":45,"resets_at":1040}}}'
out=$(echo "$DIRECT3" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent LLMUX_STATUSLINE_NOW=15 bash "$SCRIPT")
expect_contains "direct blink phase on"  "$out" "${REV}"
out=$(echo "$DIRECT3" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent LLMUX_STATUSLINE_NOW=10 bash "$SCRIPT" | sed "$STRIP")
expect_contains "direct <1h format"      "$out" "↻17m10s"

# 4. No llmux -> silent fallback, no fleet segment, exit 0, empty stderr.
err=$(mktemp)
out=$(echo "$INPUT" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent bash "$SCRIPT" 2>"$err" | sed "$STRIP")
if [[ "$out" != *CLD* && ! -s "$err" ]]; then echo "ok   no-llmux fallback"; else echo "FAIL no-llmux fallback: $out / stderr=$(cat "$err")"; fail=1; fi

exit $fail
