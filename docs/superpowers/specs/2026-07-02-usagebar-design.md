# UsageBar — macOS menu bar app for Claude Code + Codex usage

**Date:** 2026-07-02
**Status:** Implemented.

## Purpose

Always-visible menu bar readout of the current rate-limit session usage for
Claude Code and Codex, with a click-open panel showing full details
(session %, time to reset, weekly %, per-model limits, plan).

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Stack | Native Swift/SwiftUI, SwiftPM executable + scripted `.app` bundle | Tiny footprint, native look, no Xcode project needed (CLT-only machine) |
| Claude data | Anthropic OAuth usage endpoint `https://api.anthropic.com/api/oauth/usage` | Exact same numbers as `/usage`; credential already in Keychain |
| Codex data | Latest `rate_limits` event in newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | Codex CLI records exact primary (5h) / secondary (weekly) percentages locally; no network needed |
| Menu bar | Compact `CC 12% · CX 42%` | Session % per tool always visible; details on click |
| Details | Session + weekly per tool, progress bars, time left, reset times, per-model scoped limits when present, plan badge | Core ask + what the APIs give for free |

## Data source details

### Claude Code
- Credential: Keychain generic password, service `Claude Code-credentials`,
  JSON with `claudeAiOauth.accessToken`, `expiresAt` (ms), `subscriptionType`.
- Read via `/usr/bin/security find-generic-password -w` subprocess — the ACL
  is on the calling binary, and `security` is already authorized, so no
  Keychain prompt and no re-prompt after each rebuild. Token never logged.
- Request: `GET /api/oauth/usage` with `Authorization: Bearer <token>`,
  `anthropic-beta: oauth-2025-04-20`, and Claude Code's client identity
  headers `User-Agent: claude-cli/<version> (external, cli)` + `x-app: cli`
  (version read from the `~/.local/bin/claude` symlink target). Anonymous
  clients land in a far stricter rate-limit bucket and get persistent 429s.
- Polling: every 5 min; on 429 back off exponentially 10→20→40 min (cap 1 h),
  keep showing the last good data with a note.
- Parse the `limits` array (`kind`: `session`, `weekly_all`, `weekly_scoped`
  with `percent`, `resets_at` ISO8601-with-fractional-seconds, `severity`,
  `scope.model.display_name`); fall back to `five_hour` / `seven_day`.
- Read-only: no token refresh, no Keychain writes. If the token is expired or
  the API returns 401, show "token expired — open Claude Code to refresh"
  (Claude Code refreshes it itself).

### Codex
- Newest few `rollout-*.jsonl` by mtime; tail-read last 256 KB; last line
  containing `"rate_limits"` → `payload.rate_limits`:
  `primary` = 5h window (`used_percent`, `window_minutes`, `resets_at` epoch s),
  `secondary` = weekly, plus `plan_type`.
- Snapshot is only as fresh as the last Codex request → show "as of N min ago".
- If `resets_at` has passed, treat that window as 0% (limit reset).

## Architecture

SwiftPM executable `UsageBar`, macOS 14+.

- `UsageBarApp.swift` — `@main`, `MenuBarExtra` (`.window` style), label bound to store.
- `Models.swift` — `ToolUsage` (list of `LimitInfo`: kind, label, percent, resetsAt, severity), `plan`, `asOf`, error message. All `Sendable`.
- `ClaudeProvider.swift` / `CodexProvider.swift` — stateless async fetchers returning `ToolUsage`.
- `UsageStore.swift` — `@MainActor ObservableObject`; refreshes both providers every 60 s and on demand; publishes snapshots + menu title.
- `DetailsView.swift` — popover: one card per tool (progress bars colored by severity: ≥90 red, ≥70 orange, else green), time-left + reset time, plan badge, refresh + quit buttons, error states.

Build: `build.sh` → `swift build -c release`, assemble `dist/UsageBar.app`
(`Info.plist` with `LSUIElement=true`), ad-hoc codesign.

## Error handling
- No Keychain entry / expired token / HTTP error → Claude card shows message, menu shows `CC --`.
- No Codex sessions or no `rate_limits` found → `CX --`.
- Network timeout 15 s; failures never crash the app, previous snapshot retained with its timestamp.

## Verification
- `UsageBar --check` runs both providers headlessly and prints what the UI
  would show — used to verify data end-to-end without the GUI.

## Out of scope (v1)
- OAuth token refresh / Keychain writes
- Historical usage charts
- Launch-at-login automation (documented manually in README)
- Notifications on threshold
