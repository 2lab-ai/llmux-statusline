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

input=$(cat)

# Hard requirement is jq only; degrade to a static line instead of erroring.
if ! command -v jq >/dev/null 2>&1; then
  printf 'Claude (statusline: jq not installed)\n'
  exit 0
fi

DIM=$'\033[2m'
RESET=$'\033[0m'
CYAN=$'\033[36m'
MAGENTA=$'\033[35m'
BLUE=$'\033[34m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

LLMUX_BIN="${LLMUX_STATUSLINE_BIN:-llmux}"

# --- Model (+ effort level + fast mode): e.g. "Fable 5 high" / "sol[1m] max fast" ---
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
effort=$(echo "$input" | jq -r '.effort.level // empty')
fast=$(echo "$input" | jq -r '.fast_mode // empty')
model_seg="${CYAN}${model}${RESET}"
[ -n "$effort" ] && model_seg="${model_seg} ${DIM}${effort}${RESET}"
[ "$fast" = "true" ] && model_seg="${model_seg} ${YELLOW}fast${RESET}"

# --- Context window: used % (colored) + exact remaining tokens in k/M ---
# Token math is done from current_usage (input+output+cache) rather than the
# integer-rounded remaining_percentage, which is off by up to ~1% of the window.
win_size=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
usage_sum=$(echo "$input" | jq -r '
  .context_window.current_usage // empty
  | [.input_tokens, .output_tokens, .cache_creation_input_tokens, .cache_read_input_tokens]
  | map(. // 0) | add')
used_pct_reported=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

human_k() {
  awk -v n="$1" 'BEGIN {
    if (n >= 1000000) printf "%.1fM", n/1000000
    else if (n >= 1000) printf "%dk", int(n/1000)
    else printf "%d", n
  }'
}

ctx=""
if [ -n "$win_size" ] && [ "$win_size" != "0" ] && [ -n "$usage_sum" ]; then
  read -r used_pct rem_pct rem_tokens <<< "$(awk -v w="$win_size" -v u="$usage_sum" 'BEGIN {
    if (u > w) u = w
    up = 100 * u / w
    printf "%d %d %d", (up == int(up)) ? up : int(up) + 1, int(100 - up), w - u
  }')"
elif [ -n "$used_pct_reported" ]; then
  # Older payloads without current_usage: fall back to reported percentages
  used_pct=$(printf '%.0f' "$used_pct_reported")
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
    ctx="${ctx}${DIM} $(human_k "$rem_tokens")/$(human_k "$win_size")${RESET}"
  fi
else
  ctx="${DIM}ctx --${RESET}"
fi

# --- Current directory (compact, ~ relative under $HOME) ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
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
if git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  [ -z "$branch" ] && branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
    git_color="$YELLOW"; dirty="*"
  else
    git_color="$GREEN"; dirty=""
  fi
  ab=$(git -C "$cwd" --no-optional-locks rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)
  ab_str=""
  if [ -n "$ab" ]; then
    behind=$(echo "$ab" | awk '{print $1}')
    ahead=$(echo "$ab" | awk '{print $2}')
    [ "$ahead" != "0" ] && ab_str="${ab_str} ↑${ahead}"
    [ "$behind" != "0" ] && ab_str="${ab_str} ↓${behind}"
  fi
  # diff line stats vs HEAD (staged+unstaged), GitHub-style +ins,-del
  diff_seg=""
  ds=$(git -C "$cwd" --no-optional-locks diff HEAD --shortstat 2>/dev/null)
  if [ -n "$ds" ]; then
    ins=$(echo "$ds" | awk '{for(i=1;i<=NF;i++) if($i ~ /insertion/) print $(i-1)}')
    del=$(echo "$ds" | awk '{for(i=1;i<=NF;i++) if($i ~ /deletion/) print $(i-1)}')
    if [ -n "$ins" ] && [ -n "$del" ]; then
      diff_seg=" ${GREEN}+${ins}${RESET},${RED}-${del}${RESET}"
    elif [ -n "$ins" ]; then
      diff_seg=" ${GREEN}+${ins}${RESET}"
    elif [ -n "$del" ]; then
      diff_seg=" ${RED}-${del}${RESET}"
    fi
  fi
  git_seg="${git_color}${branch}${dirty}${RESET}${ab_str}${diff_seg}"
else
  git_seg="${DIM}no-git${RESET}"
fi

# --- Rate limits (rightmost): llmux fleet sums when routed through llmux,
# --- else the session's own 5h usage ---

# pct_color <remaining-sum> <n>: color by average remaining across n accounts.
# Same levels as the llmux TUI gauges (format.rs GAUGE_YELLOW_AT=0.70,
# GAUGE_RED_AT=0.90, inverted to remaining): rem<=10 red, rem<=30 yellow.
pct_color() {
  awk -v s="$1" -v n="$2" 'BEGIN {
    avg = (n > 0) ? s / n : 0
    if (avg <= 10) print "red"; else if (avg <= 30) print "yellow"; else print "green"
  }'
}
paint() { # paint <color-name>
  case "$1" in red) printf '%s' "$RED";; yellow) printf '%s' "$YELLOW";; *) printf '%s' "$GREEN";; esac
}

llmux_target() {
  # Decide whether this session is routed through an llmux daemon.
  # Prints "local" or "host:port" for remote; prints nothing when not llmux.
  local url="${ANTHROPIC_BASE_URL:-}"
  [ -z "$url" ] && return 1
  local hostport="${url#*://}"
  hostport="${hostport%%/*}"
  local host="${hostport%%:*}"
  local port="${hostport##*:}"
  [ "$port" = "$host" ] && port=3456
  case "$host" in
    localhost|127.0.0.1|::1) echo "local" ;;
    *) echo "${host}:${port}" ;;
  esac
}

rate_seg=""
target=$(llmux_target || true)
if [ -n "$target" ] && command -v "$LLMUX_BIN" >/dev/null 2>&1; then
  if [ "$target" = "local" ]; then
    fleet_json=$("$LLMUX_BIN" status --json 2>/dev/null || true)
    # Guard: the local daemon we asked must be the one the session points at.
    if [ -n "$fleet_json" ]; then
      url_port="${ANTHROPIC_BASE_URL#*://}"; url_port="${url_port%%/*}"
      case "$url_port" in *:*) url_port="${url_port##*:}" ;; *) url_port=3456 ;; esac
      daemon_port=$(echo "$fleet_json" | jq -r '.port // empty' 2>/dev/null)
      [ "$daemon_port" = "$url_port" ] || fleet_json=""
    fi
  else
    fleet_json=$("$LLMUX_BIN" status --json --remote "$target" 2>/dev/null || true)
  fi
  if [ -n "$fleet_json" ]; then
    # REMAINING capacity per account, summed per group (3 accounts with 50%
    # left each => 150%). Windows are coupled: a full 5h window costs ~20% of
    # 7d, a full 7df window ~50% of 7d, so per account
    #   rem5h_eff  = min(rem5h,  5 * rem7d)
    #   rem7df_eff = min(rem7df, 2 * rem7d)
    # A cold (never-used) account has null windows => 100% remaining.
    # auth-failed and operator-paused accounts serve nothing: excluded from
    # both the sums and the (N) count.
    read -r cl_n cl5 cl7 clf cx_n cx7 <<< "$(echo "$fleet_json" | jq -r '
      def c01: if . < 0 then 0 elif . > 1 then 1 else . end;
      def usable: select(.status != "auth_failed" and .blocked != "paused");
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
          ($cx | length),
          (([$cx[] | (1 - ((.seven_day.utilization // 0) | c01)) * 100]
            | add // 0) | round) ]
      | join(" ")' 2>/dev/null || true)"
    if [ -n "${cl_n:-}" ]; then
      if [ "$cl_n" -gt 0 ] 2>/dev/null; then
        c5=$(paint "$(pct_color "$cl5" "$cl_n")")
        c7=$(paint "$(pct_color "$cl7" "$cl_n")")
        cf=$(paint "$(pct_color "$clf" "$cl_n")")
        rate_seg="${MAGENTA}CLD(${cl_n})${RESET} ${DIM}5h:${RESET} ${c5}${cl5}%${RESET} ${DIM}7d:${RESET} ${c7}${cl7}%${RESET} ${DIM}7df:${RESET} ${cf}${clf}%${RESET}"
      fi
      if [ "$cx_n" -gt 0 ] 2>/dev/null; then
        x7=$(paint "$(pct_color "$cx7" "$cx_n")")
        cdx="${CYAN}CDX(${cx_n})${RESET} ${DIM}7d:${RESET} ${x7}${cx7}%${RESET}"
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
human_dur() { # $1 = seconds -> "3d4h" / "7h22m" / "45m"
  awk -v s="$1" 'BEGIN {
    if (s < 0) s = 0
    d = int(s / 86400); h = int((s % 86400) / 3600); m = int((s % 3600) / 60)
    if (d > 0) printf "%dd%dh", d, h
    else if (h > 0) printf "%dh%dm", h, m
    else printf "%dm", m
  }'
}
if [ -z "$rate_seg" ]; then
  read -r u5 u7 r7at uf <<< "$(echo "$input" | jq -r '
    .rate_limits // {} |
    [ (.five_hour.used_percentage // "-"),
      (.seven_day.used_percentage // "-"),
      (.seven_day.resets_at // "-"),
      ((.fable_weekly // .seven_day_fable // .seven_day_opus).used_percentage // "-") ]
    | join(" ")' 2>/dev/null || true)"
  rem7=""
  if [ -n "${u7:-}" ] && [ "$u7" != "-" ]; then
    rem7=$(awk -v u="$u7" 'BEGIN{ r=100-u; if (r<0) r=0; printf "%d", r }')
  fi
  parts=()
  if [ -n "${u5:-}" ] && [ "$u5" != "-" ]; then
    rem5=$(awk -v u="$u5" -v r7="${rem7:-100}" 'BEGIN{
      r=100-u; if (r<0) r=0; cap=5*r7; if (r>cap) r=cap; printf "%d", r }')
    parts+=("${DIM}5h:${RESET} $(paint "$(pct_color "$rem5" 1)")${rem5}%${RESET}")
  fi
  if [ -n "$rem7" ]; then
    seg7="${DIM}7d:${RESET} $(paint "$(pct_color "$rem7" 1)")${rem7}%${RESET}"
    if [ "$r7at" != "-" ] && [ -n "$r7at" ]; then
      now_s=$(date +%s)
      seg7="${seg7}${DIM} ↻$(human_dur $((r7at - now_s)))${RESET}"
    fi
    parts+=("$seg7")
  fi
  if [ -n "${uf:-}" ] && [ "$uf" != "-" ]; then
    remf=$(awk -v u="$uf" -v r7="${rem7:-100}" 'BEGIN{
      r=100-u; if (r<0) r=0; cap=2*r7; if (r>cap) r=cap; printf "%d", r }')
    parts+=("${DIM}7df:${RESET} $(paint "$(pct_color "$remf" 1)")${remf}%${RESET}")
  fi
  if [ ${#parts[@]} -gt 0 ]; then
    rate_seg=$(IFS=' '; echo "${parts[*]}")
  fi
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
