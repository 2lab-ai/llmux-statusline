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
trap 'chmod -R u+rwx "$LLMUX_STATUSLINE_CACHE_DIR" 2>/dev/null; rm -rf "$LLMUX_STATUSLINE_CACHE_DIR"' EXIT

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
fleet_file() { local f; for f in "$CD"/fleet-*; do case "$f" in *.lock|*.tmp.*) ;; *) printf '%s' "$f" ;; esac; done; }
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

# Refresh lock: advisory, a directory holding "<ts>.<pid>.<random>". While a
# live holder refreshes, a stale entry is served instead of a second llmux
# call; a holder's lock 30 s old is broken.
lock_as() { # $1 = owner token: a lock held by another run
  rm -rf "$f.lock"; mkdir "$f.lock"; printf '%s\n' "$1" > "$f.lock/owner"
}
locks() { ls "$CD" | grep -c '\.lock$'; }
before=$(calls)
lock_as 1030.1.1
out=$(run_cached 1030)
expect_eq       "live lock + stale entry: no duplicate llmux call" "$(calls)" "$before"
expect_contains "live lock + stale entry: stale entry served, countdown aged" "$out" "CDX(1) 7d: 75% ↻16m51s"
lock_as 1000.1.1
out=$(run_cached 1030)
expect_eq       "dead lock (30 s old) broken: recomputed" "$(calls)" $((before + 1))
expect_eq       "dead lock broken: entry republished at 1030, lock released" "$(head -n 1 "$f"),$(locks)" "1030,0"

# Stale serving is bounded: an entry 100 s old (> TTL + LOCK_STALE = 40) is
# not served even when the lock can be neither honored nor removed.
lock_as 1030.1.1; chmod 555 "$f.lock" # holder's lock this user cannot remove
before=$(calls)
out=$(run_cached 1130)
expect_eq       "unremovable lock + entry 100 s old: computed inline" "$(calls)" $((before + 1))
expect_contains "unremovable lock + entry 100 s old: fresh value" "$out" "CDX(1) 7d: 75% ↻17m10s"
expect_eq       "unremovable lock: inline result published (newest data wins)" "$(head -n 1 "$f")" 1130
chmod 755 "$f.lock"; rm -rf "$f.lock"
printf 'junk\n' > "$f.lock"; chmod 444 "$f.lock" # not a lock dir of ours
before=$(calls)
out=$(run_cached 1230)
expect_eq       "read-only junk lock file + entry 100 s old: computed inline" "$(calls)" $((before + 1))
expect_contains "read-only junk lock file: fresh value" "$out" "CDX(1) 7d: 75% ↻17m10s"
expect_eq       "read-only junk lock file: left untouched" "$(cat "$f.lock")" junk
rm -f "$f.lock"

# Deterministic interleavings: an llmux stub that blocks until a signal file
# appears lets the test act while a refresher holds the lock.
SIG="$(mktemp -d)"
BSTUB="$(mktemp -d)/llmux"
printf '#!/bin/bash\necho call >> "%s"\n: > "%s/started"\nn=0\nwhile [ ! -e "%s/go" ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done\ncat "%s"\n' \
  "$COUNTER" "$SIG" "$SIG" "$PWD/fixture-coupling.json" > "$BSTUB"
chmod +x "$BSTUB"
wait_for() { local n=0; while [ ! -e "$1" ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; [ -e "$1" ]; }
bg_refresh() { # $1 = NOW: a refresher that blocks inside llmux; sets BG_PID
  rm -f "$SIG/started" "$SIG/go"
  echo "$INPUT" > "$SIG/in"
  ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$BSTUB" LLMUX_STATUSLINE_NOW="$1" \
    LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" < "$SIG/in" > "$SIG/out" 2> "$SIG/err" &
  BG_PID=$!
  wait_for "$SIG/started"
}
FAST_STUB="$STUB"; STUB="$BSTUB"
CD="$LLMUX_STATUSLINE_CACHE_DIR/interleave"
: > "$SIG/go"; run_cached 1000 >/dev/null; f=$(fleet_file)

stamp() { sed "1s/.*/$1/" "$f" > "$f.t" && mv "$f.t" "$f"; } # entry with data read at $1

put_entry() { # $1 = ts, $2 = summary tuple: a valid entry with other data
  { echo "$1"; sed -n '2,4p' "$f"; echo "$2"; echo end; } > "$f.t" && mv "$f.t" "$f"
}
OTHER="9 900 900 900 61800 1 75 1030"

# (a) Equal data time (same second): the lock breaks the tie. The holder
#     publishes over an entry stamped the same second; a run whose lock was
#     taken over does not. (Same-second stamps are what a fixed clock really
#     represents; different-second ordering is tested on the real clock below.)
bg_refresh 1015
held=$(cat "$f.lock/owner")
put_entry 1015 "$OTHER"
: > "$SIG/go"; wait "$BG_PID"
expect_eq       "refresher held the lock while blocked" "${held%%.*}" 1015
expect_eq       "tie, lock holder: publishes" "$(head -n 1 "$f")|$(sed -n 5p "$f" | cut -d' ' -f1)" "1015|3"
expect_eq       "tie, lock holder: lock released, staging gone" "$(ls "$CD" | grep -c '\.lock$\|\.tmp\.')" 0
stamp 1000
bg_refresh 1015
lock_as 1015.1.1
put_entry 1015 "$OTHER"
: > "$SIG/go"; wait "$BG_PID"
expect_eq       "tie, lock taken over: does not publish" "$(head -n 1 "$f")|$(sed -n 5p "$f")" "1015|$OTHER"
expect_eq       "tie, lock taken over: staging dropped, other holder's lock left alone" "$(ls "$CD" | grep -c '\.tmp\.'),$(cat "$f.lock/owner")" "0,1015.1.1"
expect_contains "tie, lock taken over: the run still shows its own fresh value" "$(sed "$STRIP" "$SIG/out")" "CDX(1) 7d: 75% ↻17m10s"
expect_eq       "tie, lock taken over: no stderr" "$(cat "$SIG/err")" ""

# (b) Superseded refresher whose data is NEWER than the entry: publishes.
rm -rf "$f.lock"; stamp 1000
bg_refresh 1015
lock_as 1015.1.1
: > "$SIG/go"; wait "$BG_PID"
expect_eq       "superseded publisher with newer data: published" "$(head -n 1 "$f"),$(tail -n 1 "$f")" "1015,end"
expect_eq       "superseded publisher: staging file gone" "$(ls "$CD" | grep -c '\.tmp\.')" 0
expect_eq       "superseded publisher: the other holder's lock left alone" "$(cat "$f.lock/owner")" 1015.1.1

# (b2) Lock with no token yet (its creator between mkdir and the token
#      write): not taken over until the entry is TTL + LOCK_STALE old.
rm -rf "$f.lock"; mkdir "$f.lock"; stamp 1000
before=$(calls)
out=$(run_cached 1015)
expect_eq       "tokenless lock, entry 15 s old: not taken over" "$(calls),$(ls "$f.lock" | wc -l | tr -d ' ')" "$before,0"
expect_contains "tokenless lock, entry 15 s old: stale entry served" "$out" "CDX(1) 7d: 75% ↻16m55s"
run_cached 1039 >/dev/null
expect_eq       "tokenless lock, entry 39 s old: not taken over" "$(calls)" "$before"
run_cached 1040 >/dev/null
expect_eq       "tokenless lock, entry 40 s old: taken over and refreshed" "$(calls)" $((before + 1))
expect_eq       "tokenless lock taken over: republished, lock released" "$(head -n 1 "$f"),$(locks)" "1040,0"

# (c) Killed holder: its lock is honored for LOCK_STALE, then expires.
bg_refresh 1055
kill -9 "$BG_PID"; wait "$BG_PID" 2>/dev/null || true; : > "$SIG/go"
expect_eq       "killed holder: its lock is left behind" "$(cut -d. -f1 "$f.lock/owner")" 1055
before=$(calls)
run_cached 1070 >/dev/null
expect_eq       "killed holder's lock 15 s old: honored" "$(calls)" "$before"
run_cached 1085 >/dev/null
expect_eq       "killed holder's lock 30 s old: expired, refreshed" "$(calls)" $((before + 1))
expect_eq       "killed holder's lock expired: republished, lock released" "$(head -n 1 "$f"),$(locks)" "1085,0"
STUB="$FAST_STUB"

# Newest data wins on the real clock: the lock holder read llmux, then (while
# it parses: a jq stub blocks the fleet parse) another run publishes data
# read 2 s later. The holder's older data must not replace it.
CD="$LLMUX_STATUSLINE_CACHE_DIR/newest-real"
JQB="$(mktemp -d)"; JQSIG="$(mktemp -d)"
printf '#!/bin/bash\nif [ "$1" = -r ]; then : > "%s/started"; n=0; while [ ! -e "%s/go" ] && [ $n -lt 400 ]; do sleep 0.05; n=$((n+1)); done; fi\nexec %s "$@"\n' \
  "$JQSIG" "$JQSIG" "$(command -v jq)" > "$JQB/jq"
chmod +x "$JQB/jq"
FS2="$(mktemp -d)/llmux"
printf '#!/bin/bash\ncat "%s"\n' "$PWD/fixture-coupling.json" > "$FS2"
chmod +x "$FS2"
echo "$INPUT" > "$JQSIG/in"
PATH="$JQB:$PATH" ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$FS2" \
  LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" < "$JQSIG/in" > "$JQSIG/out" 2> "$JQSIG/err" &
pid=$!
wait_for "$JQSIG/started"
sleep 2
lk=$(ls -d "$CD"/fleet-*.lock); f="${lk%.lock}"
T1=$(date +%s)
printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$T1" llmux-statusline-fleet-v1 "$FS2|local" 3456 "$OTHER" end > "$f.new" && mv "$f.new" "$f"
: > "$JQSIG/go"; wait "$pid" || true
expect_eq "real clock: lock holder with older data keeps the newer entry" "$(head -n 1 "$f")|$(sed -n 5p "$f")" "$T1|$OTHER"
expect_eq "real clock: lock holder released its lock, dropped its staging" "$(ls "$CD" | grep -c '\.lock$\|\.tmp\.')" 0
expect_eq "real clock: no stderr" "$(cat "$JQSIG/err")" ""

# Read-only cache dir after one write: stale entry served while bounded,
# then computed inline; never an error, nothing written.
CD="$LLMUX_STATUSLINE_CACHE_DIR/ro"
run_cached 2000 >/dev/null
listing=$(ls -A "$CD")
chmod 555 "$CD"
before=$(calls)
out=$(run_cached 2015)
expect_eq       "read-only cache dir, entry 15 s old: stale served" "$(calls)" "$before"
expect_contains "read-only cache dir, entry 15 s old: aged countdown" "$out" "CDX(1) 7d: 75% ↻16m55s"
out=$(run_cached 2100)
expect_eq       "read-only cache dir, entry 100 s old: computed inline" "$(calls)" $((before + 1))
expect_contains "read-only cache dir, entry 100 s old: fresh value" "$out" "CDX(1) 7d: 75% ↻17m10s"
expect_eq       "read-only cache dir: nothing written" "$(ls -A "$CD")" "$listing"
chmod 755 "$CD"

# A symlink at the lock path is never followed, written or removed.
CD="$LLMUX_STATUSLINE_CACHE_DIR/symlock"
run_cached 3000 >/dev/null; f=$(fleet_file)
VICTIM="$(mktemp)"; printf 'VICTIM\n' > "$VICTIM"
ln -s "$VICTIM" "$f.lock"
out=$(run_cached 3015)
expect_contains "symlinked lock, entry 15 s old: stale served" "$out" "CDX(1) 7d: 75% ↻16m55s"
out=$(run_cached 3100)
expect_contains "symlinked lock, entry 100 s old: fresh value" "$out" "CDX(1) 7d: 75% ↻17m10s"
expect_eq       "symlinked lock: victim file untouched" "$(cat "$VICTIM")" VICTIM
expect_eq       "symlinked lock: symlink left in place" "$([ -L "$f.lock" ] && echo link)" link
rm -f "$f.lock"; GHOST="$(mktemp -u)"; ln -s "$GHOST" "$f.lock"
run_cached 3200 >/dev/null
expect_eq       "dangling symlinked lock: target never created" "$([ -e "$GHOST" ] && echo created || echo absent)" absent

# Only regular files are read: a FIFO at the entry or the owner path is a
# miss / an unknown-age lock, never opened (a read would block forever).
CD="$LLMUX_STATUSLINE_CACHE_DIR/fifo"
WD="$(mktemp -d)"
bounded() { # $1 = NOW: one run, killed after 10 s -> its stripped line or "HUNG"
  local pid n=0
  echo "$INPUT" > "$WD/in"
  # the statusline itself is the background child, every fd on a file, so a
  # hung run is killed directly and leaves nothing holding the test's pipes
  ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$STUB" LLMUX_STATUSLINE_NOW="$1" \
    LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" < "$WD/in" > "$WD/out" 2> "$WD/err" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ $n -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
    echo HUNG; return 0
  fi
  wait "$pid" 2>/dev/null || true
  sed "$STRIP" "$WD/out"
  if [ -s "$WD/err" ]; then echo "STDERR: $(cat "$WD/err")"; fi
}
run_cached 8000 >/dev/null; f=$(fleet_file)
rm -f "$f"; mkfifo "$f"
out=$(bounded 8005)
expect_contains "FIFO at the entry path: no hang, correct line" "$out" "$FLEET ↻17h10m"
expect_eq       "FIFO at the entry path: replaced by a regular entry" "$([ -f "$f" ] && [ ! -p "$f" ] && head -n 1 "$f")" 8005
rm -rf "$f.lock"; mkdir "$f.lock"; mkfifo "$f.lock/owner"
before=$(calls)
out=$(bounded 8020)
expect_contains "FIFO as the lock's owner file: no hang, stale entry served" "$out" "CDX(1) 7d: 75% ↻16m55s"
expect_eq       "FIFO as the lock's owner file: lock not taken over yet" "$(calls)" "$before"
rm -rf "$f.lock"

# A cache dir that is not this user's, or is a symlink, disables the cache.
if [ ! -O /usr/share ]; then
  CD=/usr/share
  before=$(calls)
  out=$(run_cached 4000); out2=$(run_cached 4000)
  expect_eq       "cache dir owned by another user: uncached" "$(calls)" $((before + 2))
  expect_contains "cache dir owned by another user: still renders" "$out$out2" "$FLEET ↻17h10m"
fi
REAL="$(mktemp -d)"
ln -s "$REAL" "$LLMUX_STATUSLINE_CACHE_DIR/linked"
CD="$LLMUX_STATUSLINE_CACHE_DIR/linked"
before=$(calls)
out=$(run_cached 4000); out2=$(run_cached 4000)
expect_eq       "symlinked cache dir: uncached" "$(calls)" $((before + 2))
expect_eq       "symlinked cache dir: nothing written through it" "$(ls -A "$REAL" | wc -l | tr -d ' ')" 0
expect_contains "symlinked cache dir: still renders" "$out$out2" "$FLEET ↻17h10m"

# The fleet entry is keyed on the executable llmux resolves to: two PATHs,
# two daemons' answers, no cross-talk inside the TTL.
CD="$LLMUX_STATUSLINE_CACHE_DIR/resolve"
DA="$(mktemp -d)"; DB="$(mktemp -d)"
printf '#!/bin/bash\ncat "%s"\n' "$PWD/fixture-fleet.json" > "$DA/llmux"
printf '#!/bin/bash\ncat "%s"\n' "$PWD/fixture-coupling.json" > "$DB/llmux"
chmod +x "$DA/llmux" "$DB/llmux"
run_path() { # $1 = dir first on PATH
  echo "$INPUT" | PATH="$1:$PATH" ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN=llmux \
    LLMUX_STATUSLINE_NOW=7000 LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" 2>"$err" | sed "$STRIP"
  if [ -s "$err" ]; then echo "STDERR: $(cat "$err")"; fi
}
expect_contains "llmux resolved in dir A: A's fleet"           "$(run_path "$DA")" "CLD(3) 5h: 150% 7d: 150% 7df: 150%"
expect_contains "llmux resolved in dir B: B's fleet, not A's"  "$(run_path "$DB")" "$FLEET"
expect_contains "llmux resolved in dir A again: A's (cached)"  "$(run_path "$DA")" "CLD(3) 5h: 150% 7d: 150% 7df: 150%"
expect_eq       "two resolutions: two fleet entries" "$(ls "$CD" | grep -c '^fleet-[0-9]*$')" 2

# The fleet entry is stamped when llmux answered, not when the run started
# (real clock; the stub takes 3 s).
CD="$LLMUX_STATUSLINE_CACHE_DIR/stamp"
SSTUB="$(mktemp -d)/llmux"
printf '#!/bin/bash\nsleep 3\ncat "%s"\n' "$PWD/fixture-coupling.json" > "$SSTUB"
chmod +x "$SSTUB"
t0=$(date +%s)
echo "$INPUT" | ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$SSTUB" \
  LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" >/dev/null 2>"$err"
ts=$(head -n 1 "$(fleet_file)")
expect_eq "fleet entry stamped at llmux's answer (>= start + 2 s)" "$([ $((ts - t0)) -ge 2 ] && echo ok || echo "ts-start=$((ts - t0))")" ok

# NUL inside a field: dropped, as main's command substitutions did.
want=$'\033[36mAB\033[0m \033[2mhi\033[0m\033[2m | \033[0m\033[2mctx --\033[0m\033[2m | \033[0m\033[34m/tmp\033[0m\033[2m | \033[0m\033[2mno-git\033[0m'
got=$(echo '{"model":{"display_name":"A\u0000B"},"cwd":"/tmp","effort":{"level":"hi"}}' \
  | ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent bash "$SCRIPT" 2>"$err")
expect_eq "NUL in a field: full line byte-identical to main@8b4fc1e" "$got" "$want"
expect_eq "NUL in a field: no stderr" "$(cat "$err")" ""

# Smoke: 20 sessions refresh one expired entry at the same moment (llmux
# answers slowly). Exactly one refreshes; the rest serve the stale entry.
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
expect_eq "race on an expired entry: one refresh, not 20" "$(( $(calls) - before ))" 1
expect_eq "race on an expired entry: every session renders" "$(all_render && echo ok)" ok
f=$(fleet_file)
expect_eq "race on an expired entry: valid entry, no lock or staging left" "$(head -n 1 "$f"),$(tail -n 1 "$f"),$(ls "$CD" | grep -c '\.lock$\|\.tmp\.')" "5020,end,0"
# Cold start (fresh install, reboot that wiped the cache): no entry to serve,
# so every racer computes once; the lock holder publishes.
CD="$LLMUX_STATUSLINE_CACHE_DIR/race-cold"
before=$(calls)
race 6000
expect_eq "cold-start race: each session computes once" "$(( $(calls) - before ))" 20
expect_eq "cold-start race: every session renders" "$(all_render && echo ok)" ok
f=$(fleet_file)
expect_eq "cold-start race: valid entry, no lock or staging left" "$(head -n 1 "$f"),$(tail -n 1 "$f"),$(ls "$CD" | grep -c '\.lock$\|\.tmp\.')" "6000,end,0"
STUB="$FAST_STUB"

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

# The git entry is stamped when git was read, not when the run started, so a
# refresh slower than the TTL still yields a fresh entry (real clock; a git
# stub makes `git diff` take 3 s).
SLOWGIT="$(mktemp -d)"
printf '#!/bin/bash\n[ "$4" = diff ] && sleep 3\nexec %s "$@"\n' "$(command -v git)" > "$SLOWGIT/git"
chmod +x "$SLOWGIT/git"
CDG="$LLMUX_STATUSLINE_CACHE_DIR/slowgit"
t0=$(date +%s)
echo "$GITIN" | PATH="$SLOWGIT:$PATH" ANTHROPIC_BASE_URL= LLMUX_STATUSLINE_BIN=/nonexistent \
  LLMUX_STATUSLINE_CACHE_DIR="$CDG" bash "$SCRIPT" >/dev/null 2>"$err"
ts=$(head -n 1 "$CDG"/git-*)
expect_eq "git entry stamped when git was read (>= start + 2 s)" "$([ $((ts - t0)) -ge 2 ] && echo ok || echo "ts-start=$((ts - t0))")" ok

# Cache decisions use the time of the decision, not script start: a fleet
# hit that comes after a slow git refresh (git stub: diff takes 3 s) is aged
# by the post-git clock (real clock).
CD="$LLMUX_STATUSLINE_CACHE_DIR/postgit"
REPO2="$(mktemp -d)"
git -C "$REPO2" init -q
FS="$(mktemp -d)/llmux"
printf '#!/bin/bash\ncat "%s"\n' "$PWD/fixture-coupling.json" > "$FS"
chmod +x "$FS"
# TTL 100 keeps the fleet entry a hit even on a loaded machine.
echo "$INPUT" | ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$FS" \
  LLMUX_STATUSLINE_CACHE_TTL=100 LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" >/dev/null 2>"$err"
out=$(echo '{"model":{"display_name":"T"},"workspace":{"current_dir":"'"$REPO2"'"}}' \
  | PATH="$SLOWGIT:$PATH" ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$FS" \
    LLMUX_STATUSLINE_CACHE_TTL=100 LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" 2>"$err" | sed "$STRIP")
cdx="${out##*CDX(1) 7d: 75% ↻}"; m="${cdx%%m*}"; sec="${cdx#*m}"; sec="${sec%%s*}"
aged=$((1030 - (m * 60 + sec)))
expect_eq "fleet hit after a 3 s git refresh: aged by post-git time (>= 2 s)" "$([ "$aged" -ge 2 ] && [ "$aged" -lt 100 ] && echo ok || echo "aged $aged s: $out")" ok

# Invariant 3 at print time (real clock; TTL 3 s + LOCK_STALE 1 s = a 4 s
# bound): a git hit is chosen first, then an llmux call takes 5 s. The git
# segment would be printed 5 s old, so it is computed again before printing.
CD="$LLMUX_STATUSLINE_CACHE_DIR/printbound"
REPO3="$(mktemp -d)"
git -C "$REPO3" init -q -b main
git -C "$REPO3" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
FA="$(mktemp -d)/llmux"; FB="$(mktemp -d)/llmux"
printf '#!/bin/bash\ncat "%s"\n' "$PWD/fixture-coupling.json" > "$FA"
printf '#!/bin/bash\nsleep 5\ncat "%s"\n' "$PWD/fixture-coupling.json" > "$FB"
chmod +x "$FA" "$FB"
run3() { # $1 = llmux stub
  echo '{"model":{"display_name":"T"},"workspace":{"current_dir":"'"$REPO3"'"}}' \
    | ANTHROPIC_BASE_URL=http://localhost:3456 LLMUX_STATUSLINE_BIN="$1" LLMUX_STATUSLINE_CACHE_TTL=3 \
      LLMUX_STATUSLINE_LOCK_STALE=1 LLMUX_STATUSLINE_CACHE_DIR="$CD" bash "$SCRIPT" 2>"$err" | sed "$STRIP"
  if [ -s "$err" ]; then echo "STDERR: $(cat "$err")"; fi
}
expect_contains "print-time bound: setup run sees a clean repo" "$(run3 "$FA")" "| main |"
echo change > "$REPO3/file"
out=$(run3 "$FB")
expect_contains "print-time bound: git hit computed again after a 5 s llmux call" "$out" "| main* |"
expect_contains "print-time bound: fleet segment shown" "$out" "$FLEET"

exit $fail
