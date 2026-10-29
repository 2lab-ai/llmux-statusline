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

# Private cache dir: never read or write the user's ~/.cache from tests.
LLMUX_STATUSLINE_CACHE_DIR="$(mktemp -d)"
export LLMUX_STATUSLINE_CACHE_DIR
trap 'rm -rf "$LLMUX_STATUSLINE_CACHE_DIR"' EXIT

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
  if [[ "$2" == *"$3"* && "$2" != *"STDERR:"* ]]; then
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
DIRECT4='{"model":{"display_name":"T"},"workspace":{"current_dir":"/tmp"},"rate_limits":{"five_hour":{"used_percentage":58,"resets_at":9010},"seven_day":{"used_percentage":45,"resets_at":100010}}}'
out=$(echo "$DIRECT4" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent LLMUX_STATUSLINE_NOW=10 bash "$SCRIPT" | sed "$STRIP")
expect_contains "direct 5h countdown" "$out" "5h: 42% ↻2h30m 7d: 55% ↻1d3h"
out=$(echo "$DIRECT3" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent LLMUX_STATUSLINE_NOW=10 bash "$SCRIPT" | sed "$STRIP")
expect_contains "direct <1h format"      "$out" "↻17m10s"

# 4. No llmux -> silent fallback, no fleet segment, exit 0, empty stderr.
err=$(mktemp)
out=$(echo "$INPUT" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent bash "$SCRIPT" 2>"$err" | sed "$STRIP")
if [[ "$out" != *CLD* && ! -s "$err" ]]; then echo "ok   no-llmux fallback"; else echo "FAIL no-llmux fallback: $out / stderr=$(cat "$err")"; fail=1; fi

# 5. Shared cache. Sessions in the same cwd / on the same llmux target share
#    one computation per TTL. Hits are detected by side effect, not timing:
#    the llmux stub counts its calls, and a git repo is changed between runs.
#    LLMUX_STATUSLINE_NOW drives the cache clock as well as the blink phase.
expect_eq() { # $1 name, $2 got, $3 want
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1"; echo "  expected: $3"; echo "  got:      $2"; fail=1; fi
}
CD="$LLMUX_STATUSLINE_CACHE_DIR/fleet-case"
COUNTER="$(mktemp)"
STUB="$(mktemp -d)/llmux"
printf '#!/bin/bash\necho call >> "%s"\ncat "%s"\n' "$COUNTER" "$PWD/fixture-coupling.json" > "$STUB"
chmod +x "$STUB"
run_cached() { # $1 = NOW -> stripped line; stderr must stay empty
  echo "$INPUT" | ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$STUB" \
    LLMUX_STATUSLINE_NOW="$1" LLMUX_STATUSLINE_CACHE_DIR="$CD" LLMUX_STATUSLINE_CACHE_TTL="${TTL:-10}" \
    bash "$SCRIPT" 2>"$err" | sed "$STRIP"
  if [ -s "$err" ]; then echo "STDERR: $(cat "$err")"; fi
}
calls() { wc -l < "$COUNTER" | tr -d ' '; }
fleet_file() { local f; for f in "$CD"/fleet-*; do case "$f" in *.lock) ;; *) printf '%s' "$f" ;; esac; done; }
FLEET="CLD(3) 5h: 150% 7d: 110% 7df: 120%"

out=$(run_cached 1000)
expect_contains "cache miss renders fleet"   "$out" "$FLEET ↻17h10m"
expect_eq       "cache miss asks llmux once" "$(calls)" 1
out=$(run_cached 1005)
expect_eq       "cache hit inside TTL: no llmux call" "$(calls)" 1
expect_contains "cache hit: same sums, countdowns moved by entry age" "$out" "$FLEET ↻17h9m"
expect_contains "cache hit: <1h countdown moved too" "$out" "CDX(1) 7d: 75% ↻17m5s"
out=$(run_cached 1010)
expect_eq       "cache expiry at TTL: llmux asked again" "$(calls)" 2
expect_contains "cache expiry: fresh countdown" "$out" "$FLEET ↻17h10m"
f=$(fleet_file)
expect_eq       "cache entry published, no lock left" "$(ls "$CD" | grep -c '\.lock$')" 0

# Corrupt entries are misses: recompute, correct line, entry rewritten.
for kind in garbage truncated wrongkey future empty; do
  case "$kind" in
    garbage)   printf 'not a cache entry\n\x01\x02\n' > "$f" ;;
    truncated) head -n 2 "$f" > "$f.t" && mv "$f.t" "$f" ;;
    wrongkey)  sed '3s/.*/someone-else|local/' "$f" > "$f.t" && mv "$f.t" "$f" ;;
    future)    sed '1s/.*/99999/' "$f" > "$f.t" && mv "$f.t" "$f" ;;
    empty)     : > "$f" ;;
  esac
  before=$(calls)
  out=$(run_cached 1011)
  expect_eq       "corrupt entry ($kind) -> recomputed" "$(calls)" $((before + 1))
  expect_contains "corrupt entry ($kind) -> correct line" "$out" "$FLEET ↻17h10m"
  expect_eq       "corrupt entry ($kind) -> rewritten" "$(head -n 1 "$f"),$(tail -n 1 "$f")" "1011,end"
done

# Refresh lock: while another run refreshes (fresh lock), a stale entry is
# served instead of a second llmux call; a lock left by a killed run
# (older than 30 s) is broken.
before=$(calls)
printf '1030\n' > "$f.lock"
out=$(run_cached 1030)
expect_eq       "fresh lock + stale entry: no duplicate llmux call" "$(calls)" "$before"
expect_contains "fresh lock + stale entry: stale entry served, countdown aged" "$out" "CDX(1) 7d: 75% ↻16m51s"
printf '990\n' > "$f.lock"
out=$(run_cached 1030)
expect_eq       "dead lock (40 s old) broken: recomputed" "$(calls)" $((before + 1))
expect_eq       "dead lock broken: entry republished at 1030" "$(head -n 1 "$f")" 1030
expect_eq       "dead lock broken: lock released" "$(ls "$CD" | grep -c '\.lock$')" 0

# A real race: 20 sessions refresh one expired entry at the same moment
# (llmux answers slowly). One refreshes; the rest serve the stale entry.
# Tolerance 2: a racer that reads the lock between its O_EXCL create and its
# ts write treats it as dead and refreshes too. Breaking an unreadable lock
# is deliberate: honoring it could wedge the cache if a holder died there.
race() { # $1 = NOW; 20 concurrent runs -> $RD/out.*
  local i
  rm -f "$RD"/out.*
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    run_cached "$1" > "$RD/out.$i" &
  done
  wait
}
all_render() { # every concurrent output is the full, error-free line
  local f
  for f in "$RD"/out.*; do
    [[ "$(cat "$f")" == *"$FLEET"* && "$(cat "$f")" != *STDERR:* ]] || return 1
  done
}
RD="$(mktemp -d)"
STUB="$(mktemp -d)/llmux"
printf '#!/bin/bash\necho call >> "%s"\nsleep 0.5\ncat "%s"\n' "$COUNTER" "$PWD/fixture-coupling.json" > "$STUB"
chmod +x "$STUB"
CD="$LLMUX_STATUSLINE_CACHE_DIR/race"
run_cached 5000 >/dev/null
before=$(calls)
race 5020
got=$(( $(calls) - before ))
expect_eq "race on an expired entry: 1-2 refreshes, not 20" "$([ "$got" -ge 1 ] && [ "$got" -le 2 ] && echo ok || echo "$got calls")" ok
expect_eq "race on an expired entry: every session renders" "$(all_render && echo ok)" ok
run_cached 5021 >/dev/null
f=$(fleet_file)
expect_eq "race on an expired entry: valid entry afterwards" "$(tail -n 1 "$f"),$(ls "$CD" | grep -c '\.lock$')" "end,0"
# Cold start (fresh install, reboot that wiped the cache): no entry to serve,
# so every racer computes once; one publishes.
CD="$LLMUX_STATUSLINE_CACHE_DIR/race-cold"
before=$(calls)
race 6000
expect_eq "cold-start race: each session computes once" "$(( $(calls) - before ))" 20
expect_eq "cold-start race: every session renders" "$(all_render && echo ok)" ok
run_cached 6001 >/dev/null
f=$(fleet_file)
expect_eq "cold-start race: valid entry afterwards" "$(tail -n 1 "$f"),$(ls "$CD" | grep -c '\.lock$')" "end,0"
STUB="$(mktemp -d)/llmux"
printf '#!/bin/bash\necho call >> "%s"\ncat "%s"\n' "$COUNTER" "$PWD/fixture-coupling.json" > "$STUB"
chmod +x "$STUB"

# TTL=0 turns caching off: every run asks llmux, nothing is written.
CD="$LLMUX_STATUSLINE_CACHE_DIR/ttl0"
before=$(calls)
TTL=0 run_cached 2000 >/dev/null; TTL=0 run_cached 2001 >/dev/null
expect_eq "TTL=0: no caching" "$(calls)" $((before + 2))
expect_eq "TTL=0: no cache dir" "$([ -e "$CD" ] && echo exists || echo absent)" absent

# Unusable cache dir: same line, silent.
CD=/dev/null/llmux-statusline
out=$(run_cached 2000)
expect_contains "unwritable cache dir: still renders" "$out" "$FLEET ↻17h10m"

# 6. Git segment cache, per cwd: a change inside the TTL is not seen (hit),
#    one after it is (expiry).
REPO="$(mktemp -d)"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
GITIN='{"model":{"display_name":"T"},"workspace":{"current_dir":"'"$REPO"'"}}'
run_git() { # $1 = NOW
  echo "$GITIN" | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent LLMUX_STATUSLINE_NOW="$1" \
    bash "$SCRIPT" 2>"$err" | sed "$STRIP"
  if [ -s "$err" ]; then echo "STDERR: $(cat "$err")"; fi
}
expect_contains "git miss: clean branch" "$(run_git 3000)" "| main"
echo change > "$REPO/file"
out=$(run_git 3009)
expect_contains "git hit inside TTL: cached clean segment" "$out" "| main"
[[ "$out" == *"main*"* ]] && { echo "FAIL git hit served a recomputed segment"; fail=1; }
expect_contains "git expiry: change visible" "$(run_git 3010)" "| main*"

exit $fail
