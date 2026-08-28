# llmux-statusline

A single-file Claude Code statusline with [llmux](https://github.com/2lab-ai/llmux) fleet
awareness.

```bash
curl -fsSL https://2lab-ai.github.io/llmux-statusline/install.sh | bash
```

One compact line:

```
Fable 5 high | ctx 66% left 658k/1.0M | ~/2lab.ai/zbrain | main* ↑5 +313,-120 | CLD(10) 5h: 97% 7d: 781% 7df: 666% | CDX(3) 7d: 54%
```

## Segments

| Segment | Example | Meaning |
|---|---|---|
| Model | `Fable 5 high` / `sol[1m] max fast` | Model + effort level + `fast` when fast mode is on |
| Context | `ctx 66% left 658k/1.0M` | Remaining context %, colored (green/yellow/red by usage), + remaining/total tokens |
| Directory | `~/2lab.ai/zbrain` | cwd, `~`-relative, truncated to last 2 components when deep |
| Git | `main* ↑5 ↓6 +313,-120` | Branch, `*` dirty, ahead/behind upstream, diff line stats vs HEAD (staged+unstaged) |
| Rate limits | see below | llmux fleet sums, or the session's own 5h window |

## The llmux segment (rightmost)

The script detects whether the session is routed through an llmux daemon by looking at
`ANTHROPIC_BASE_URL`:

- **Routed through llmux** → it asks the daemon (`llmux status --json`, local or `--remote`)
  and shows **fleet-wide sums** of window utilization per account group:

  ```
  CLD(8) 5h: 375% 7d: 720% 7df: 320% | CDX(2) 7d: 213%
  ```

  - `CLD(8)` — 8 claude accounts; `5h` / `7d` / `7df` (7-day Fable window) are the **sum**
    across all of them. 3 accounts at 50% each shows 150%. Ceiling = N×100%.
  - `5h` and `7df` are **effective** usage, not the raw window value — the windows are
    coupled: a full 5h window costs ~20% of the 7d budget, and a full 7df window costs
    ~50% of it. So per account, usable 5h capacity is `min(rem5h, 5 × rem7d)` and usable
    7df capacity is `min(rem7df, 2 × rem7d)`; a 7d-exhausted account counts as 100% used
    on all three windows even when its own 5h window looks fresh. This keeps the sums
    honest about how much fleet capacity is actually left.
  - `CDX(2)` — codex accounts, 7-day window only.
  - Colors follow the fleet average (sum/N): green <70%, yellow ≥70%, red ≥90%.

- **Plain Claude session** (no llmux) → the session's own usage as reported by
  Claude Code: `5h:12%`.

The llmux path is strictly best-effort: no llmux binary, daemon down, a non-llmux
`ANTHROPIC_BASE_URL`, or a port mismatch all silently fall back to the plain `5h:NN%`
display — never an error in the statusline.

## Install

```bash
curl -fsSL https://2lab-ai.github.io/llmux-statusline/install.sh | bash
```

Works on macOS, Linux, and WSL. `jq` is auto-installed when a package manager is
available (brew / apt / dnf / pacman / apk); the `llmux` CLI is only needed for the
llmux segment (the script degrades gracefully without it).

From a clone instead:

```bash
git clone https://github.com/2lab-ai/llmux-statusline.git
cd llmux-statusline && ./install.sh
```

`install.sh` copies `statusline.sh` to `~/.claude/statusline-command.sh` and sets in
`~/.claude/settings.json` (a `.bak` backup is written first):

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline-command.sh",
    "refreshInterval": 5,
    "padding": 0
  }
}
```

Manual install is the same two steps done by hand.

## Configuration

| Env var | Default | Meaning |
|---|---|---|
| `LLMUX_STATUSLINE_BIN` | `llmux` | llmux CLI binary to invoke |

Remote daemons work out of the box: when `ANTHROPIC_BASE_URL` points at a non-local host,
the script queries it via `llmux status --json --remote host:port`.

## Try it without installing

```bash
echo '{"model":{"display_name":"Fable 5"},"effort":{"level":"high"},"fast_mode":false,
      "context_window":{"used_percentage":34,"remaining_percentage":66,"context_window_size":1000000},
      "workspace":{"current_dir":"'"$PWD"'"},
      "rate_limits":{"five_hour":{"used_percentage":12}}}' | bash statusline.sh
```

## License

MIT — see [LICENSE](LICENSE).
