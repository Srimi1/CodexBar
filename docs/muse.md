---
summary: "Meta Muse (Muse Code) provider notes: local session log scanning, token cost tracking, and rate limits."
read_when:
  - Debugging Meta Muse local session scanning or rate limits
  - Updating Muse token pricing or model rates
  - Adjusting Muse provider settings or CLI behavior
---

# Meta Muse (Muse Code)

CodexBar tracks [Meta Muse](https://developer.meta.com/ai) usage, rate limits, and token costs
locally from session logs.

## Data source

- Local Muse Code runtime logs in `~/.local/share/muse/sessions/` (also `~/.config/muse/sessions/` and `~/.muse/sessions/`). Each `model_completed` event carries the model name and token usage; matching `goal_usage_attribution` records are only used as a fallback so calls are never double counted.
- Local settings in `~/.config/muse/settings.json` or environment variables `META_API_KEY` / `MUSE_API_KEY`.
- CLI detection via the `muse` binary (`~/.local/bin`, Homebrew, or PATH); version from `muse --version`.
- Daily/weekly percentages are estimates against approximate per-plan token budgets (Meta does not publish hard quotas); token counts and USD cost are exact from the logs.

## What It Shows

CodexBar maps Muse usage into standard rate windows and token cost tracking:

| CodexBar field | Muse source | Notes |
| --- | --- | --- |
| Provider id | `muse` | Used by config, CLI, and settings. |
| Display name | `Meta Muse` | Visible in Settings and menus. |
| Identity / plan | `settings.json` `plan` or `tier` | Standard ($5–$50/mo) or Contributor ($0.10/$0.20 per 1M tokens). |
| Primary window | Daily token limit | Resets at midnight. |
| Secondary window | Weekly token quota | 7-day rolling quota window. |
| Token costs | Local session logs | Aggregates prompt, completion, and cache tokens with standard/contributor rates. |

## Models & Pricing

- `muse-spark-1.3`: Input $1.25 / 1M, Output $4.25 / 1M, Cache read $0.125 / 1M.
- `muse-code`: Input $1.25 / 1M, Output $4.25 / 1M, Cache read $0.125 / 1M.
- Contributor tier: Input $0.10 / 1M, Output $0.20 / 1M, Cache read $0.01 / 1M.
