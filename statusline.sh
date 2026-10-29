#!/bin/bash
# llmux-statusline — Claude Code statusline with llmux fleet awareness
# https://github.com/2lab-ai/llmux-statusline
#
# Segments: model | ctx remaining | cwd | git (branch, dirty, ahead/behind, +ins,-del)
#           | effort | rate limits
#
# Rate-limit segment (rightmost) is llmux-aware:
#   - Session routed through llmux (ANTHROPIC_BASE_URL -> llmux daemon):
#       CLD(8) 5h: 375% 7d: 720% 7df: 320% | CDX(2) 7d: 213%
#     = SUM of utilization across all llmux accounts per group
#       (claude: 5h + 7d + 7d-fable windows; codex: 7d only).
#       3 accounts at 50% each => 150%.
#   - Direct Anthropic session: the session's own 5h usage (5h:12%).
#
# Requirements: jq. llmux CLI only needed for the llmux segment.
#
# Spawn budget. Claude Code runs this every ~5 s in every open session, so the
# cost that matters is process creation, not CPU: macOS refuses new bootstrap
# lookups once the machine-wide pidversion counter (+1 per fork, +1 per exec)
# crosses 2^31. Under /bin/bash 3.2 every $(...) forks, and an external command
# inside it forks again unless it is exec'd. Hence:
#   - ONE jq call reads every stdin field (NUL-separated, read by builtins);
#   - integer math runs in builtins; awk only for non-integer inputs;
#   - every captured external is $(exec ...) / <(exec ...): one process;
#   - the git segment (per cwd) and the llmux fleet status (per daemon target)
#     are cached for LLMUX_STATUSLINE_CACHE_TTL seconds (default 10, 0 = off)
#     in LLMUX_STATUSLINE_CACHE_DIR (default
#     ${XDG_CACHE_HOME:-$HOME/.cache}/llmux-statusline), shared by every
#     session. A cache hit costs no extra process.

# Hard requirement is jq only; degrade to a static line instead of erroring.
if ! command -v jq >/dev/null 2>&1; then
  IFS= read -r -d '' _ # drain stdin
  printf 'Claude (statusline: jq not installed)\n'
  exit 0
fi

DIM=$'\033[2m'
RESET=$'\033[0m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'
REVERSE=$'\033[7m'
BOLD=$'\033[1m'
BLUE=$'\033[34m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'
US=$'\037' # field separator inside jq outputs and cache keys

LLMUX_BIN="${LLMUX_STATUSLINE_BIN:-llmux}"

CACHE_TTL="${LLMUX_STATUSLINE_CACHE_TTL:-10}"
case "$CACHE_TTL" in ''|*[!0-9]*|0?*) CACHE_TTL=10 ;; esac
CACHE_DIR="${LLMUX_STATUSLINE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/llmux-statusline}"
LOCK_STALE=30 # seconds: a refresh lock older than this belongs to a killed run

# is_int <s>: a plain decimal integer that bash arithmetic reads exactly as awk
# does (no octal-looking leading zeros, no overflow). Anything else takes the
# original awk path, so the printed line is unchanged for odd inputs too.
is_int() {
  case "$1" in
    ''|-|*[!0-9-]*|?*-*|0?*|-0*|????????????????*) return 1 ;;
  esac
  return 0
}

llmux_target() {
  # Decide whether this session is routed through an llmux daemon.
  # Sets target to "local" or "host:port" for remote; empty when not llmux.
  local url="${ANTHROPIC_BASE_URL:-}" hostport host port
  target=""
  [ -z "$url" ] && return 0
  hostport="${url#*://}"
  hostport="${hostport%%/*}"
  host="${hostport%%:*}"
  port="${hostport##*:}"
  [ "$port" = "$host" ] && port=3456
  case "$host" in
    localhost|127.0.0.1|::1) target="local" ;;
    *) target="${host}:${port}" ;;
  esac
}
llmux_target

llmux_exe() {
  # Sets LLMUX_EXE to the absolute path of the file "$LLMUX_BIN" executes as
  # (the PATH search exec does; `type -P` without its comsub fork), or "".
  local p="" d rest
  LLMUX_EXE=""
  case "$LLMUX_BIN" in
    */*) [ -f "$LLMUX_BIN" ] && [ -x "$LLMUX_BIN" ] && p="$LLMUX_BIN" ;;
    *)
      rest="$PATH:"
      while [ -n "$rest" ]; do
        d="${rest%%:*}"; rest="${rest#*:}"
        [ -z "$d" ] && d=.
        if [ -f "$d/$LLMUX_BIN" ] && [ -x "$d/$LLMUX_BIN" ]; then p="$d/$LLMUX_BIN"; break; fi
      done ;;
  esac
  case "$p" in
    '') ;;
    /*) LLMUX_EXE="$p" ;;
    *) LLMUX_EXE="$PWD/$p" ;;
  esac
}
# Fleet cache key: the executable that answers + the daemon it asks. Unknown
# executable -> no key -> uncached.
LLMUX_KEY=""
if [ -n "$target" ]; then
  llmux_exe
  [ -n "$LLMUX_EXE" ] && LLMUX_KEY="$LLMUX_EXE|$target"
fi

# --- Every stdin field in one jq call -------------------------------------
# Each field reproduces `$(echo "$input" | jq -r '<expr>')` of the original
# script: errors isolated per field, non-strings JSON-encoded, multiple
# outputs newline-joined, trailing newlines stripped, NULs dropped (as bash
# command substitution drops them). Also: the wall clock, the cache keys +
# djb2 hashes, and the direct-mode remaining % computed in double arithmetic
# exactly as awk did ("?" = an input awk would coerce; the script then runs
# that awk itself).
JQ_STDIN='
def s: (if type == "string" then . else tojson end) | split("\u0000") | join("");
def rs: if endswith("\n") then .[:-1] | rs else . end;
def f(e): [e | s] | join("\n") | rs;
def h: try (reduce explode[] as $c (5381; (. * 33 + $c) % 4294967296) | tostring) catch "";
def rem(u; cap): (100 - u) | (if . < 0 then 0 else . end)
  | (if cap == null then . else ([., cap] | min) end) | floor;
(try f(.workspace.current_dir // .cwd) catch "") as $cwd
| ($cwd + "\u001f" + $gd + "\u001f" + $gwt) as $gk
| (try (.rate_limits // {} |
    [ (.five_hour.used_percentage // "-"),
      (.five_hour.resets_at // "-"),
      (.seven_day.used_percentage // "-"),
      (.seven_day.resets_at // "-"),
      ((.fable_weekly // .seven_day_fable // .seven_day_opus).used_percentage // "-") ])
   catch null) as $t
| (if $t != null and ($t | all(type == "number" or . == "-")) then
     ($t[2] | if type == "number" then rem(.; null) else null end) as $r7
     | [ $r7,
         ($t[0] | if type == "number" then rem(.; 5 * ($r7 // 100)) else null end),
         ($t[4] | if type == "number" then rem(.; 2 * ($r7 // 100)) else null end) ]
     | map(if . == null then "" else tostring end)
   else ["?", "?", "?"] end) as $rem
| [ (now | floor | tostring),
    (try f(.model.display_name // "Claude") catch ""),
    (try f(.effort.level // empty) catch ""),
    (try f(.fast_mode // empty) catch ""),
    (try f(.context_window.context_window_size // empty) catch ""),
    (try f(.context_window.current_usage // empty
        | [.input_tokens, .output_tokens, .cache_creation_input_tokens, .cache_read_input_tokens]
        | map(. // 0) | add) catch ""),
    (try f(.context_window.used_percentage // empty) catch ""),
    $cwd, $gk, ($gk | h), (if $lk == "" then "" else ($lk | h) end),
    (try f($t | join(" ")) catch ""),
    $rem[] ]
| join("\u0000") + "\u0000"'
{
  IFS= read -r -d '' J_NOW; IFS= read -r -d '' model; IFS= read -r -d '' effort
  IFS= read -r -d '' fast; IFS= read -r -d '' win_size; IFS= read -r -d '' usage_sum
  IFS= read -r -d '' used_pct_reported; IFS= read -r -d '' cwd; IFS= read -r -d '' git_key
  IFS= read -r -d '' git_hash; IFS= read -r -d '' fleet_hash; IFS= read -r -d '' rl_tuple
  IFS= read -r -d '' j_rem7; IFS= read -r -d '' j_rem5; IFS= read -r -d '' j_remf
} < <(exec jq -j --arg gd "${GIT_DIR-}" --arg gwt "${GIT_WORK_TREE-}" \
        --arg lk "$LLMUX_KEY" "$JQ_STDIN" 2>/dev/null)

# Wall clock (LLMUX_STATUSLINE_NOW fixes it, for tests). It drives the blink
# phase, the reset countdowns and cache ages. S0 + $SECONDS (a builtin)
# tell how far the real clock has moved since; a fixed clock does not move.
CLOCK_FIXED=""
NOW_S="${LLMUX_STATUSLINE_NOW:-}"
if is_int "$NOW_S"; then CLOCK_FIXED=1; else NOW_S="$J_NOW"; fi
is_int "$NOW_S" || NOW_S=$(exec date +%s)
S0=$SECONDS
now_s() { # -> NOW_T = wall clock now, no fork (+-1 s)
  if [ -n "$CLOCK_FIXED" ]; then NOW_T=$NOW_S; else NOW_T=$((NOW_S + SECONDS - S0)); fi
}

# --- Shared cache ----------------------------------------------------------
# INVARIANT (the contract every change here must keep):
#   1. A published entry is always complete.
#   2. Its timestamp truthfully records when its data was read.
#   3. A value is never shown once its age is >= TTL + LOCK_STALE.
# The refresh lock is advisory: it only spares duplicate refreshes. The
# windows between an owner/age check and the mv/rm that follows are accepted:
# their only possible effects are a duplicate refresh or, briefly, an older
# but truthfully stamped entry replacing a newer one.
#
# One entry file per key: ts, magic, key, A, B, "end", one per line. Every
# computing run writes its own staging file and publishes it with one `mv`
# (atomic rename) when it holds the lock or its data is newer than what is
# there (newest data wins). Only regular files are read; anything else, or
# anything that does not parse, is a miss. The lock (<entry>.lock) is a
# directory holding the owner's token "<ts>.<pid>.<random>". The cache is used
# only in a real directory owned by this user. Ages are taken at the moment
# of each decision (now_s), not at script start.
is_file() { [ -f "$1" ] && [ ! -L "$1" ]; } # never open a FIFO, device or symlink

cache_get() { # <file> <magic> <key> -> C_TS C_A C_B; 0 = well-formed entry
  local m k e
  C_TS=""; C_A=""; C_B=""
  is_file "$1" || return 1
  {
    IFS= read -r C_TS; IFS= read -r m; IFS= read -r k
    IFS= read -r C_A; IFS= read -r C_B; IFS= read -r e
  } 2>/dev/null < "$1" || return 1
  [ "$m" = "$2" ] && [ "$k" = "$3" ] && [ "$e" = "end" ] && is_int "$C_TS"
}

TOKEN="" # owner token of the lock this run took last

lock_token() { # <lockdir> -> TOK = its owner token ("" = none / unreadable)
  TOK=""
  is_file "$1/owner" || return 0
  { IFS= read -r TOK < "$1/owner"; } 2>/dev/null
}

lock_owned() { # <lockdir>: 0 = the lock exists and holds this run's token
  [ -n "$TOKEN" ] && [ -d "$1" ] && [ ! -L "$1" ] || return 1
  lock_token "$1"
  [ "$TOK" = "$TOKEN" ]
}

lock_take() { # <lockdir> <entry age, "" = no entry>: 0 = this run holds the lock
  local lk="$1" lts
  [ -L "$lk" ] && return 1 # never act on a symlink
  if [ -e "$lk" ]; then
    [ -d "$lk" ] && [ -O "$lk" ] || return 1 # not a lock of ours: leave it alone
    lock_token "$lk"
    lts="${TOK%%.*}"
    if is_int "$lts"; then
      # the holder's token: live until LOCK_STALE old
      [ $((NOW_T - lts)) -lt "$LOCK_STALE" ] && [ $((lts - NOW_T)) -le 5 ] && return 1
    else
      # no token (its holder sits between mkdir and the token write, or died
      # there): age unknown, so it is broken only once the entry has gone
      # unrefreshed for LOCK_STALE past its TTL, or when there is no entry
      [ -n "$2" ] && [ "$2" -lt $((CACHE_TTL + LOCK_STALE)) ] && return 1
    fi
    rm -rf "$lk" 2>/dev/null # a dead holder's lock: break it, retry once
  fi
  mkdir -m 700 "$lk" 2>/dev/null || return 1
  TOKEN="$NOW_T.$$.$RANDOM"
  set -C
  { printf '%s\n' "$TOKEN" > "$lk/owner"; } 2>/dev/null
  set +C
  return 0
}

# publish <file> <lockdir> <magic> <key>: C_TS_NEW/C_A/C_B as an entry, via
# this run's own staging file, if this run holds the lock or the entry there
# is missing, invalid, stamped from the future, or older than C_TS_NEW.
publish() {
  ( umask 077
    stage="$1.tmp.$$.$RANDOM"
    { [ -e "$stage" ] || [ -L "$stage" ]; } && exit 1
    set -C
    printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$C_TS_NEW" "$3" "$4" "$C_A" "$C_B" end > "$stage" || exit 1
    now_s
    if lock_owned "$2" || ! cache_get "$1" "$3" "$4" ||
       [ "$C_TS" -lt "$C_TS_NEW" ] || [ "$C_TS" -gt $((NOW_T + 5)) ]; then
      exec mv -f "$stage" "$1"
    fi
    exec rm -f "$stage" # a newer entry is there already
  ) 2>/dev/null
}

# cached <name> <key> <hash> <compute-fn>: C_A/C_B from a fresh entry, else
# from <compute-fn>. While another run holds the lock, a stale entry is
# served, but only while it is younger than TTL + LOCK_STALE; past that this
# run computes inline. C_AGE = age in seconds of what is served.
# <compute-fn> sets C_TS_NEW to when its data was read (default: now).
cached() {
  local file="$CACHE_DIR/$1-$3" magic="llmux-statusline-$1-v1" key="$2" fn="$4" lk age=""
  now_s
  C_AGE=0; C_TS_NEW="$NOW_T"
  if [ "$CACHE_TTL" -eq 0 ] || [ -z "$3" ]; then "$fn"; return 0; fi
  if [ ! -e "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ]; then
    ( umask 077; exec mkdir -p "$CACHE_DIR" ) 2>/dev/null
  fi
  if ! { [ -d "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ]; }; then
    "$fn"; return 0
  fi
  if cache_get "$file" "$magic" "$key"; then
    age=$((NOW_T - C_TS))
    # stamped up to 5 s ahead: clock granularity between concurrent runs
    [ "$age" -lt 0 ] && [ "$age" -ge -5 ] && age=0
    if [ "$age" -ge 0 ]; then
      C_AGE=$age
      [ "$age" -lt "$CACHE_TTL" ] && return 0
    else
      age="" # from the future: a miss
    fi
  fi
  lk="$file.lock"
  if lock_take "$lk" "$age"; then
    C_AGE=0
    "$fn"
    publish "$file" "$lk" "$magic" "$key"
    lock_owned "$lk" && rm -rf "$lk" 2>/dev/null
    return 0
  fi
  [ -n "$age" ] && [ "$age" -lt $((CACHE_TTL + LOCK_STALE)) ] && return 0 # stale, bounded
  C_AGE=0
  "$fn"
  publish "$file" "$lk" "$magic" "$key" # newest data wins
}

# --- Model (+ effort level + fast mode): e.g. "Fable 5 high" / "sol[1m] max fast" ---
model_seg="${CYAN}${model}${RESET}"
[ -n "$effort" ] && model_seg="${model_seg} ${DIM}${effort}${RESET}"
[ "$fast" = "true" ] && model_seg="${model_seg} ${YELLOW}fast${RESET}"

# --- Context window: used % (colored) + exact remaining tokens in k/M ---
# Token math is done from current_usage (input+output+cache) rather than the
# integer-rounded remaining_percentage, which is off by up to ~1% of the window.

human_k() { # $1 tokens -> HK ("1.2M" / "658k" / "999")
  local n="$1" t
  if is_int "$n" && [ "$n" -ge 0 ]; then
    if [ "$n" -lt 1000 ]; then
      HK="$n"; return
    elif [ "$n" -lt 1000000 ]; then
      HK="$((n / 1000))k"; return
    elif [ $((n % 100000)) -ne 50000 ]; then
      # not an exact .x5 tie, so rounding the exact decimal == awk's %.1f
      t=$(((n + 50000) / 100000))
      HK="$((t / 10)).$((t % 10))M"; return
    fi
  fi
  HK=$(exec awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000
    else if (n >= 1000) printf "%dk", int(n/1000)
    else printf "%d", n
  }')
}

ctx=""
if [ -n "$win_size" ] && [ "$win_size" != "0" ] && [ -n "$usage_sum" ]; then
  if is_int "$win_size" && is_int "$usage_sum" && [ "$usage_sum" -ge 0 ] &&
     [ "$win_size" -gt 0 ] && [ "$win_size" -lt 10000000000000 ]; then
    # exact integer form of the awk below: ceil(100u/w), floor(100-100u/w), w-u
    u=$usage_sum
    [ "$u" -gt "$win_size" ] && u=$win_size
    used_pct=$(((100 * u + win_size - 1) / win_size))
    rem_pct=$((100 - used_pct))
    rem_tokens=$((win_size - u))
  else
    read -r used_pct rem_pct rem_tokens <<< "$(exec awk -v w="$win_size" -v u="$usage_sum" 'BEGIN {
      if (u > w) u = w
      up = 100 * u / w
      printf "%d %d %d", (up == int(up)) ? up : int(up) + 1, int(100 - up), w - u
    }')"
  fi
elif [ -n "$used_pct_reported" ]; then
  # Older payloads without current_usage: fall back to reported percentages
  printf -v used_pct '%.0f' "$used_pct_reported"
  rem_pct=$((100 - used_pct))
  rem_tokens=""
fi
if [ -n "${used_pct:-}" ]; then
  if [ "$used_pct" -ge 90 ]; then
    ctx_color="$RED"
  elif [ "$used_pct" -ge 70 ]; then
    ctx_color="$YELLOW"
  else
    ctx_color="$GREEN"
  fi
  ctx="${ctx_color}ctx ${rem_pct}% left${RESET}"
  if [ -n "$rem_tokens" ] && [ -n "$win_size" ]; then
    human_k "$rem_tokens"; k_rem="$HK"
    human_k "$win_size"
    ctx="${ctx}${DIM} ${k_rem}/${HK}${RESET}"
  fi
else
  ctx="${DIM}ctx --${RESET}"
fi

# --- Current directory (compact, ~ relative under $HOME) ---
if [ "$cwd" = "$HOME" ]; then
  dir_display="~"
elif [[ "$cwd" == "$HOME"/* ]]; then
  dir_display="~/${cwd#$HOME/}"
else
  dir_display="$cwd"
fi
IFS='/' read -ra _parts <<< "$dir_display"
_n=${#_parts[@]}
if [ "$_n" -gt 3 ]; then
  dir_display=".../${_parts[$((_n-2))]}/${_parts[$((_n-1))]}"
fi

# --- Git: branch + dirty + ahead/behind + diff line stats (vs HEAD) ---
git_compute() { # -> C_A = rendered git segment
  local branch git_color dirty ab ab_str="" behind ahead ds ins="" del="" diff_seg="" i
  local -a w
  C_B=""
  if ! git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    C_A="${DIM}no-git${RESET}"
    return
  fi
  branch=$(exec git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(exec git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$(exec git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    git_color="$YELLOW"; dirty="*"
  else
    git_color="$GREEN"; dirty=""
  fi
  ab=$(exec git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
  if [ -n "$ab" ]; then
    read -r behind ahead <<< "$ab"
    [ "$ahead" != "0" ] && ab_str="${ab_str} ↑${ahead}"
    [ "$behind" != "0" ] && ab_str="${ab_str} ↓${behind}"
  fi
  # diff line stats vs HEAD (staged+unstaged), GitHub-style +ins,-del
  ds=$(exec git -C "$cwd" --no-optional-locks diff HEAD --shortstat 2>/dev/null)
  if [ -n "$ds" ]; then
    read -ra w <<< "$ds"
    for ((i = 1; i < ${#w[@]}; i++)); do
      case "${w[i]}" in
        *insertion*) ins="${w[i-1]}" ;;
        *deletion*) del="${w[i-1]}" ;;
      esac
    done
    if [ -n "$ins" ] && [ -n "$del" ]; then
      diff_seg=" ${GREEN}+${ins}${RESET},${RED}-${del}${RESET}"
    elif [ -n "$ins" ]; then
      diff_seg=" ${GREEN}+${ins}${RESET}"
    elif [ -n "$del" ]; then
      diff_seg=" ${RED}-${del}${RESET}"
    fi
  fi
  C_A="${git_color}${branch}${dirty}${RESET}${ab_str}${diff_seg}"
  # stamped when read, not when the run started: a refresh slower than the
  # TTL would otherwise publish an already-expired entry and refresh nonstop
  now_s; C_TS_NEW=$NOW_T
}
# Cached per cwd (+ GIT_DIR/GIT_WORK_TREE), only for an absolute, single-line
# cwd: a relative one depends on the caller's own working directory.
case "$cwd" in
  /*) case "$git_key" in *$'\n'*) git_hash="" ;; esac ;;
  *) git_hash="" ;;
esac
cached git "$git_key" "$git_hash" git_compute
git_seg="$C_A"

# --- Rate limits (rightmost): llmux fleet sums when routed through llmux,
# --- else the session's own 5h usage ---

# Clock for this segment (blink phase, payload countdowns): read after the
# git work, as the original script's `date` call was.
now_s; NOW_R=$NOW_T

human_dur() { # $1 = seconds -> HD ("1d2h" / "7h15m" / "15m10s")
  local s="$1"
  if is_int "$s"; then
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -ge 86400 ]; then
      HD="$((s / 86400))d$(((s % 86400) / 3600))h"
    elif [ "$s" -ge 3600 ]; then
      HD="$((s / 3600))h$(((s % 3600) / 60))m"
    else
      HD="$((s / 60))m$((s % 60))s"
    fi
    return
  fi
  HD=$(exec awk -v s="$s" 'BEGIN {
    if (s < 0) s = 0
    d = int(s / 86400); h = int((s % 86400) / 3600)
    m = int((s % 3600) / 60); sec = int(s % 60)
    if (d > 0) printf "%dd%dh", d, h
    else if (h > 0) printf "%dh%dm", h, m
    else printf "%dm%ds", m, sec
  }')
}

# reset_span <seconds-or-empty> -> RS = styled " ↻<dur>" segment (empty input -> "").
# Urgency: >=1d dim, <1d bright(bold), <1h red with fg/bg inverted on
# alternating refreshes. The blink phase is WALL-CLOCK derived ((epoch/5s)
# bucket parity), not per-call state: many concurrent Claude Code sessions
# each polling every ~5s all agree on the phase and alternate cleanly,
# where a shared toggle file would race and flicker erratically.
reset_span() {
  local secs="$1"
  RS=""
  { [ -z "$secs" ] || [ "$secs" = "-" ]; } && return 0
  human_dur "$secs"
  if [ "$secs" -lt 3600 ] 2>/dev/null; then
    if [ $(((NOW_R / 5) % 2)) -eq 1 ]; then
      RS=" ${RED}${REVERSE}↻${HD}${RESET}"
    else
      RS=" ${RED}↻${HD}${RESET}"
    fi
  elif [ "$secs" -lt 86400 ] 2>/dev/null; then
    RS=" ${BOLD}↻${HD}${RESET}"
  else
    RS=" ${DIM}↻${HD}${RESET}"
  fi
}
# Countdown to an epoch from the payload. A non-integer epoch keeps the
# original semantics (bash arithmetic in a subshell; an error drops the span).
reset_at_span() {
  local at="$1"
  if is_int "$at"; then
    reset_span $((at - NOW_R))
  else
    RS=$(reset_span $((at - NOW_R)); printf '%s' "$RS")
  fi
}

# pct_paint <remaining-sum> <n> -> PC: color by average remaining across n
# accounts. Same levels as the llmux TUI gauges (format.rs GAUGE_YELLOW_AT=0.70,
# GAUGE_RED_AT=0.90, inverted to remaining): rem<=10 red, rem<=30 yellow.
pct_paint() {
  local s="$1" n="$2" c
  if is_int "$s" && is_int "$n"; then
    if [ "$n" -le 0 ] || [ "$s" -le $((10 * n)) ]; then
      c=red
    elif [ "$s" -le $((30 * n)) ]; then
      c=yellow
    else
      c=green
    fi
  else
    c=$(exec awk -v s="$s" -v n="$n" 'BEGIN {
      avg = (n > 0) ? s / n : 0
      if (avg <= 10) print "red"; else if (avg <= 30) print "yellow"; else print "green"
    }')
  fi
  case "$c" in red) PC="$RED" ;; yellow) PC="$YELLOW" ;; *) PC="$GREEN" ;; esac
}

# REMAINING capacity per account, summed per group (3 accounts with 50%
# left each => 150%). Windows are coupled: a full 5h window costs ~20% of
# 7d, a full 7df window ~50% of 7d, so per account
#   rem5h_eff  = min(rem5h,  5 * rem7d)
#   rem7df_eff = min(rem7df, 2 * rem7d)
# A cold (never-used) account has null windows => 100% remaining.
# auth-failed and operator-paused accounts serve nothing: excluded from
# both the sums and the (N) count.
# Output: "<daemon port>\037cl_n cl5 cl7 clf cl_rs cx_n cx7 cx_rs".
JQ_FLEET='
def s: (if type == "string" then . else tojson end) | split("\u0000") | join("");
def c01: if . < 0 then 0 elif . > 1 then 1 else . end;
def usable: select(.status != "auth_failed" and .blocked != "paused");
(try ([.port // empty | s] | join("\n")) catch "")
+ "\u001f" +
(try (
  [.accounts[] | select(.group == "claude") | usable] as $cl
  | [.accounts[] | select(.group == "codex") | usable] as $cx
  | [ $cl[]
      | ((.seven_day.utilization    // 0) | c01) as $u7
      | ((.five_hour.utilization    // 0) | c01) as $u5
      | ((.fable_weekly.utilization // 0) | c01) as $uf
      | (1 - $u7) as $r7
      | { r5: (([ (1 - $u5), (5 * $r7) ] | min) * 100),
          r7: ($r7 * 100),
          rf: (([ (1 - $uf), (2 * $r7) ] | min) * 100) }
    ] as $rem
  | [ ($cl | length),
      ([$rem[].r5] | add // 0 | round),
      ([$rem[].r7] | add // 0 | round),
      ([$rem[].rf] | add // 0 | round),
      (([$cl[].seven_day.resets_in_secs] | map(select(. != null)) | min) // "-"),
      ($cx | length),
      (([$cx[] | (1 - ((.seven_day.utilization // 0) | c01)) * 100]
        | add // 0) | round),
      (([$cx[].seven_day.resets_in_secs] | map(select(. != null)) | min) // "-") ]
  | join(" ") | s) catch "")'
fleet_fetch() { # -> C_A = daemon port, C_B = summary tuple (both empty: no usable answer)
  local fj parsed
  C_A=""; C_B=""
  if [ "$target" = "local" ]; then
    fj=$(exec "$LLMUX_BIN" status --json 2>/dev/null)
  else
    fj=$(exec "$LLMUX_BIN" status --json --remote "$target" 2>/dev/null)
  fi
  # the countdowns are as of this moment: stamp the entry with it
  now_s; C_TS_NEW=$NOW_T
  [ -n "$fj" ] || return 0
  parsed=$(exec jq -r "$JQ_FLEET" 2>/dev/null <<< "$fj")
  case "$parsed" in
    *"$US"*) C_A="${parsed%%"$US"*}"; C_B="${parsed#*"$US"}" ;;
  esac
}

rate_seg=""
if [ -n "$target" ] && command -v "$LLMUX_BIN" >/dev/null 2>&1; then
  # Cached per resolved executable + target (failures too, so a dead daemon
  # is asked once per TTL, not once per refresh of every session).
  cached fleet "$LLMUX_KEY" "$fleet_hash" fleet_fetch
  daemon_port="$C_A"; fleet_tuple="$C_B"
  if [ "$target" = "local" ]; then
    # Guard: the local daemon we asked must be the one the session points at.
    url_port="${ANTHROPIC_BASE_URL#*://}"; url_port="${url_port%%/*}"
    case "$url_port" in *:*) url_port="${url_port##*:}" ;; *) url_port=3456 ;; esac
    [ "$daemon_port" = "$url_port" ] || fleet_tuple=""
  fi
  if [ -n "$fleet_tuple" ]; then
    read -r cl_n cl5 cl7 clf cl_rs cx_n cx7 cx_rs <<< "$fleet_tuple"
    # A cached answer is C_AGE seconds old: move its countdowns forward.
    if [ "$C_AGE" -gt 0 ]; then
      is_int "${cl_rs:-}" && cl_rs=$((cl_rs - C_AGE))
      is_int "${cx_rs:-}" && cx_rs=$((cx_rs - C_AGE))
    fi
    if [ -n "${cl_n:-}" ]; then
      if [ "$cl_n" -gt 0 ] 2>/dev/null; then
        pct_paint "$cl5" "$cl_n"; c5="$PC"
        pct_paint "$cl7" "$cl_n"; c7="$PC"
        pct_paint "$clf" "$cl_n"; cf="$PC"
        reset_span "${cl_rs:-}"
        rate_seg="${MAGENTA}CLD(${cl_n})${RESET} ${DIM}5h:${RESET} ${c5}${cl5}%${RESET} ${DIM}7d:${RESET} ${c7}${cl7}%${RESET} ${DIM}7df:${RESET} ${cf}${clf}%${RESET}${RS}"
      fi
      if [ "$cx_n" -gt 0 ] 2>/dev/null; then
        pct_paint "$cx7" "$cx_n"
        reset_span "${cx_rs:-}"
        cdx="${CYAN}CDX(${cx_n})${RESET} ${DIM}7d:${RESET} ${PC}${cx7}%${RESET}${RS}"
        if [ -n "$rate_seg" ]; then rate_seg="${rate_seg}${DIM} | ${RESET}${cdx}"; else rate_seg="$cdx"; fi
      fi
    fi
  fi
fi
# Fallback (no llmux, daemon down, port mismatch, parse failure): the
# session's own windows as reported by Claude Code, in REMAINING terms with
# the same coupling cap (rem5h_eff = min(rem5h, 5*rem7d)). The harness
# currently reports only five_hour and seven_day; a fable weekly window is
# picked up automatically if it ever appears. Never an error.
join_parts() { local IFS=' '; rate_seg="${parts[*]}"; }
if [ -z "$rate_seg" ]; then
  read -r u5 r5at u7 r7at uf <<< "$rl_tuple"
  rem7=""
  if [ -n "${u7:-}" ] && [ "$u7" != "-" ]; then
    if [ "$j_rem7" = "?" ]; then
      rem7=$(exec awk -v u="$u7" 'BEGIN{ r=100-u; if (r<0) r=0; printf "%d", r }')
    else
      rem7="$j_rem7"
    fi
  fi
  parts=()
  if [ -n "${u5:-}" ] && [ "$u5" != "-" ]; then
    if [ "$j_rem7" = "?" ]; then
      rem5=$(exec awk -v u="$u5" -v r7="${rem7:-100}" 'BEGIN{
        r=100-u; if (r<0) r=0; cap=5*r7; if (r>cap) r=cap; printf "%d", r }')
    else
      rem5="$j_rem5"
    fi
    pct_paint "$rem5" 1
    seg5="${DIM}5h:${RESET} ${PC}${rem5}%${RESET}"
    if [ "$r5at" != "-" ] && [ -n "$r5at" ]; then
      reset_at_span "$r5at"
      seg5="${seg5}${RS}"
    fi
    parts+=("$seg5")
  fi
  if [ -n "$rem7" ]; then
    pct_paint "$rem7" 1
    seg7="${DIM}7d:${RESET} ${PC}${rem7}%${RESET}"
    if [ "$r7at" != "-" ] && [ -n "$r7at" ]; then
      # same urgency/blink rules as the fleet segment — common to both modes
      reset_at_span "$r7at"
      seg7="${seg7}${RS}"
    fi
    parts+=("$seg7")
  fi
  if [ -n "${uf:-}" ] && [ "$uf" != "-" ]; then
    if [ "$j_rem7" = "?" ]; then
      remf=$(exec awk -v u="$uf" -v r7="${rem7:-100}" 'BEGIN{
        r=100-u; if (r<0) r=0; cap=2*r7; if (r>cap) r=cap; printf "%d", r }')
    else
      remf="$j_remf"
    fi
    pct_paint "$remf" 1
    parts+=("${DIM}7df:${RESET} ${PC}${remf}%${RESET}")
  fi
  [ ${#parts[@]} -gt 0 ] && join_parts
fi

# --- Assemble one compact line ---
segments=("$model_seg" "$ctx" "${BLUE}${dir_display}${RESET}" "$git_seg")
[ -n "$rate_seg" ] && segments+=("$rate_seg")

sep="${DIM} | ${RESET}"
out=""
for seg in "${segments[@]}"; do
  if [ -z "$out" ]; then
    out="$seg"
  else
    out="${out}${sep}${seg}"
  fi
done

printf '%s\n' "$out"
