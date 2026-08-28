#!/bin/bash
# Golden tests for llmux-statusline. The llmux segment MUST report summed
# REMAINING capacity ("3 accounts with 50% left each => 150%"), with the
# window-coupling caps. These fixtures fail if the semantics regress to
# usage-sums, drop the coupling, or stop treating cold accounts as 100%.
set -euo pipefail
cd "$(dirname "$0")"

SCRIPT=../statusline.sh
STRIP=$'s/\033\\[[0-9;]*m//g'
INPUT='{"model":{"display_name":"T"},"workspace":{"current_dir":"/tmp"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}'
fail=0

run_with_fixture() { # $1 fixture file -> statusline output (colors stripped)
  local stub
  stub="$(mktemp -d)/llmux"
  printf '#!/bin/bash\ncat "%s"\n' "$PWD/$1" > "$stub"
  chmod +x "$stub"
  echo "$INPUT" | ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$stub" \
    bash "$SCRIPT" | sed "$STRIP"
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

# 3. No llmux -> silent fallback, no fleet segment, exit 0, empty stderr.
err=$(mktemp)
out=$(echo "$INPUT" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent bash "$SCRIPT" 2>"$err" | sed "$STRIP")
if [[ "$out" != *CLD* && ! -s "$err" ]]; then echo "ok   no-llmux fallback"; else echo "FAIL no-llmux fallback: $out / stderr=$(cat "$err")"; fail=1; fi

exit $fail
