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
  - **auth-failed** and operator-**paused** accounts serve nothing and are excluded from
    both the sums and the `(N)` count.
  - `CDX(2)` — codex accounts, 7-day window only.
  - `↻1d2h` after each group = time until the **soonest 7-day reset** among that
    group's usable accounts. Tiers: `1d2h` (dim), `17h10m` (<1 day, bright),
    `17m10s` (<1 hour, red — and the text inverts on alternating refreshes as a
    blink; the phase comes from the wall clock, `(epoch/5s) parity`, so any number
    of concurrent sessions polling every ~5s blink in step with zero shared state).
  - Colors mirror the llmux TUI: group labels use llmux's group colors (CLD magenta,
    CDX cyan) and the percentages use its gauge levels on the fleet average (sum/N) of
    remaining — yellow ≤30%, red ≤10%, green otherwise.

- **Plain Claude session** (no llmux) → the session's own windows as reported by
  Claude Code, in the same remaining terms, with reset countdowns on both
  windows:

  ```
  5h: 42% ↻2h30m 7d: 55% ↻3d4h
  ```

  The 5h coupling cap and the countdown urgency/blink tiers are the same in both
  modes. The cap applies here too (`rem5h_eff = min(rem5h, 5 × rem7d)`). The
  harness currently reports only the 5h and 7d windows; a fable weekly window is
  shown automatically if it ever appears in the payload.

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
