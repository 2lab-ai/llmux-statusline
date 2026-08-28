#!/bin/bash
# llmux-statusline installer — macOS / Linux / WSL
#
#   curl -fsSL https://raw.githubusercontent.com/2lab-ai/llmux-statusline/main/install.sh | bash
#
# Works both piped (downloads statusline.sh from GitHub) and from a local
# clone (uses the file next to it). Installs to ~/.claude/statusline-command.sh
# and points ~/.claude/settings.json at it (backup written first).
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/2lab-ai/llmux-statusline/main"
DEST="$HOME/.claude/statusline-command.sh"
SETTINGS="$HOME/.claude/settings.json"

log() { printf '%s\n' "$*" >&2; }

ensure_jq() {
  command -v jq >/dev/null 2>&1 && return 0
  log "jq not found — attempting install..."
  local os
  os="$(uname -s)"
  if [ "$os" = "Darwin" ] && command -v brew >/dev/null 2>&1; then
    brew install jq && return 0
  elif [ "$os" = "Linux" ]; then
    # WSL takes this path too (uname -s == Linux)
    if command -v apt-get >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo apt-get update -qq && sudo apt-get install -y -qq jq && return 0
    elif command -v dnf >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo dnf install -y -q jq && return 0
    elif command -v pacman >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo pacman -S --noconfirm --quiet jq && return 0
    elif command -v apk >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
      sudo apk add --quiet jq && return 0
    fi
  fi
  log "error: could not install jq automatically."
  log "  macOS:         brew install jq"
  log "  Debian/Ubuntu: sudo apt-get install jq"
  log "  Fedora:        sudo dnf install jq"
  exit 1
}

fetch_script() {
  # Prefer a statusline.sh sitting next to this installer (local clone);
  # fall back to downloading from GitHub (curl | bash case).
  local here=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  fi
  if [ -n "$here" ] && [ -f "$here/statusline.sh" ]; then
    log "installing from local clone: $here/statusline.sh"
    cp "$here/statusline.sh" "$1"
  else
    log "downloading: $RAW_BASE/statusline.sh"
    curl -fsSL "$RAW_BASE/statusline.sh" -o "$1"
  fi
}

main() {
  ensure_jq

  mkdir -p "$HOME/.claude"
  local tmp
  tmp="$(mktemp)"
  fetch_script "$tmp"
  bash -n "$tmp" # sanity: refuse to install a broken download
  mv "$tmp" "$DEST"
  chmod +x "$DEST"
  log "installed: $DEST"

  if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak"
    log "backup: $SETTINGS.bak"
  else
    echo '{}' > "$SETTINGS"
  fi
  jq '.statusLine = {"type":"command","command":"bash ~/.claude/statusline-command.sh","refreshInterval":5,"padding":0}' \
    "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  log "statusLine configured in: $SETTINGS"

  # Smoke render so the user sees it working immediately
  log ""
  log "sample render:"
  echo '{"model":{"display_name":"Claude"},"effort":{"level":"high"},"fast_mode":false,"context_window":{"used_percentage":10,"remaining_percentage":90,"context_window_size":200000},"workspace":{"current_dir":"'"$HOME"'"},"rate_limits":{"five_hour":{"used_percentage":5}}}' \
    | bash "$DEST" >&2 || true
  log ""
  log "done. Restart Claude Code (or open a new session) to see it."
}

main "$@"
