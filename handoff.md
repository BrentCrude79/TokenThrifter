# TokenThrifter — handoff notes

For whoever (human or agent) picks this up next: what it is, how it's wired, what's fragile, and how to test.

## Shape

| File | Role |
|---|---|
| `TokenThrifter.ps1` | The whole widget: data fetch + WPF UI + lifecycle. Windows PowerShell 5.1, no dependencies. |
| `install.ps1` | Copies the widget to `~/.claude/tokenthrifter/`, merges a `SessionStart` hook into `~/.claude/settings.json` (idempotent, backs up first), starts the widget. `-Uninstall` reverses it. |
| `docs/screenshot.png` | Rendered with `-Demo -Snapshot` — no real account data. |

## Lifecycle

1. Every Claude Code session start (desktop app Code tab or CLI) fires the `SessionStart` hook, which runs
   `powershell -Command Start-Process ...` so the widget **detaches** and the hook returns immediately.
   The hook uses the exec form (`command` + `args`) so no shell quoting is involved.
2. A named mutex (`Local\TokenThrifter_Singleton`) makes every launch after the first a no-op.
3. Every 15 s the widget checks for Claude Code processes (`Test-ClaudeCode`): any `claude.exe` under a
   `\claude-code\` directory (the engine the desktop app spawns per session), the CLI `claude.exe`
   (`~\.local\bin` or whatever `Get-Command claude` resolves), or an npm-installed CLI under `node.exe`.
   The desktop app's own `Claude.exe` shell does **not** count. After 3 consecutive misses (~45 s) it exits.
   Users can switch this off from the right-click menu (`CloseWithClaude` in `%APPDATA%\TokenThrifter\config.json`).

## Data fetch

Runs in a separate runspace every 120 s (`$Fetch`), so the UI never blocks. Output per provider:
`@{ ok; plan; five; week; asOf?; err? }` where each window is `@{ used(0-100); resets(DateTimeOffset|null); state = active|idle|reset }`.
A window whose reset time has already passed is shown as full (`reset`) — important for Codex, whose data is only as fresh as the last Codex run.

### Claude Code
- `GET https://api.anthropic.com/api/oauth/usage`, headers `Authorization: Bearer <accessToken>`, `anthropic-beta: oauth-2025-04-20`.
  Response: `five_hour.utilization` / `seven_day.utilization` (0–100) and `*.resets_at` (ISO 8601).
- Token: `~/.claude/.credentials.json` → `claudeAiOauth.accessToken` / `expiresAt` (ms) / `subscriptionType`. Lives ~8 h.
- **Re-auth:** the desktop app keeps its own credentials and doesn't necessarily update this file, so it goes stale.
  When `expiresAt` is within 5 min, the widget runs `claude -p /usage --no-session-persistence` hidden
  (at most once per 10 min; stamp file `%APPDATA%\TokenThrifter\last-reauth.txt`). `/usage` is a local slash
  command: `num_turns: 0`, zero tokens, zero cost — verified — but Claude Code refreshes the OAuth token as a side effect.
- **Sleep/wake:** a 1 s tick arriving >60 s late means the PC slept; the widget then fetches ~20 s after wake.
  Re-auth is skipped while no network is available, a failed re-auth (expiry didn't move) shortens the
  cooldown to ~1 min, and a failed Claude row triggers a re-fetch after 60 s instead of 120 s.
- **Deliberately not done:** refreshing the token directly with the refresh token. That rotates the refresh token
  and can sign out a running CLI. Let Claude Code own its credentials.
- Note: that `claude -p` call itself fires `SessionStart`; harmless because of the mutex.

### Z.ai (GLM Coding Plan)
- `GET https://api.z.ai/api/monitor/usage/quota/limit`, `Authorization: Bearer <key>` (the China endpoint
  `open.bigmodel.cn` is used when Claude Code's base URL points there — untested).
- Response `data.limits[]`: entries with `unit`/`number` describing the window (`unit 3, number 5` = 5 hours;
  `unit 6, number 1` = 1 week), `percentage` used, `nextResetTime` (ms, absent until the window starts). `data.level` = plan.
  Older plans reported `type: TOKENS_LIMIT` for the 5 h window — also handled.
- Key lookup order: `ZAI_API_KEY` (process, then user env) → `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_API_KEY` when
  `ANTHROPIC_BASE_URL` contains `z.ai`/`bigmodel.cn` → same keys inside `~/.claude/settings.json` `env`.

### Codex
- Newest `*.jsonl` under `$CODEX_HOME/sessions` (default `~/.codex`), last line matching `"rate_limits":{`.
  `payload.rate_limits.primary` / `.secondary` each carry `used_percent`, `window_minutes` (300 = 5 h, 10080 = week),
  `resets_at` (epoch s). `plan_type` = plan. No network.

## Fragile bits / ideas

- Both usage endpoints are undocumented — first thing to check when a row errors.
- `Test-ClaudeCode` relies on install paths; a new Claude Code packaging layout would need a new pattern.
- Hook exec form (`args`) requires a recent Claude Code. Older versions would need a `command` string instead.
- Ideas: tray icon mode, per-provider hide toggles, a notification when a window crosses into red, a Claude
  "extra usage" row (the usage endpoint also returns `extra_usage` for some plans).

## Testing

```powershell
# Render without touching the live widget (works alongside it):
powershell -ExecutionPolicy Bypass -STA -File .\TokenThrifter.ps1 -Snapshot out.png          # real data
powershell -ExecutionPolicy Bypass -STA -File .\TokenThrifter.ps1 -Demo -Snapshot out.png    # demo data
```

To exercise re-auth: back up `~/.claude/.credentials.json`, set `claudeAiOauth.expiresAt` to a past epoch-ms,
delete `%APPDATA%\TokenThrifter\last-reauth.txt`, run a snapshot, and confirm `expiresAt` moved forward.
Then **delete the backup** — after the refresh it holds a revoked refresh token.

Screen-capture tools that don't pass `CAPTUREBLT` won't see the widget (it's a layered window) — use `-Snapshot`.
