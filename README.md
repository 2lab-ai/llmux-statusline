# llmux-statusline

A single-file Claude Code statusline with [llmux](https://github.com/2lab-ai/llmux) fleet
awareness.

```bash
curl -fsSL https://2lab-ai.github.io/llmux-statusline/install.sh | bash
```

One compact line:

```
Fable 5 high | ctx 66% left 658k/1.0M | ~/2lab.ai/zbrain | main* ↑5 +313,-120 | CLD(10) 5h: 269% 7d: 212% 7df: 292% | CDX(3) 7d: 243%
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

  - Numbers are **remaining capacity, summed** across accounts: `CLD(8)` = 8 claude
    accounts; 3 accounts with 50% left each shows 150%. Ceiling = N×100%, 0% = fleet
    exhausted.
  - `5h` and `7df` are effective remaining — the windows are coupled: a full 5h window
    costs ~20% of the 7d budget and a full 7df (Fable weekly) window ~50% of it, so per
    account `rem5h_eff = min(rem5h, 5 × rem7d)` and `rem7df_eff = min(rem7df, 2 × rem7d)`.
    A 7d-exhausted account contributes 0% on all three windows even when its own 5h
    window looks fresh.
  - A **cold** (never-used) account has no window data yet and counts as 100% remaining.
  - `CDX(2)` — codex accounts, 7-day window only.
  - Colors follow the fleet average (sum/N) of remaining: green ≥30%, yellow <30%,
    red <10%.

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
