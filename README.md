# TokenMeter

[![Latest version](https://img.shields.io/github/v/release/Kartax/tokenmeter?label=version&color=4c8dff&labelColor=15181d&style=flat)](https://github.com/Kartax/tokenmeter/releases/latest)
[![Release date](https://img.shields.io/github/release-date/Kartax/tokenmeter?label=released&color=4c8dff&labelColor=15181d&style=flat)](https://github.com/Kartax/tokenmeter/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/Kartax/tokenmeter/total?label=downloads&color=4c8dff&labelColor=15181d&style=flat)](https://github.com/Kartax/tokenmeter/releases)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-4c8dff?labelColor=15181d&style=flat)](https://kartax.github.io/tokenmeter/)

A macOS **menu-bar app** that shows, at a glance, how much of each AI
subscription's usage allowance is left before it resets — Claude, Codex,
GitHub Copilot, Nous Portal, Ollama Cloud, Venice.ai, Z.ai, xAI, Cursor,
OpenCode, Alibaba Cloud, Gemini, Antigravity, MiniMax, Kimi, Synthetic,
DeepSeek, Mistral and Xiaomi MiMo in one popover.

**Download & info:** https://kartax.github.io/tokenmeter/ — a notarized
`.dmg` for macOS 14+. This repo holds everything: the source, the download
page (`docs/`, served via GitHub Pages) and the release binaries (GitHub
Releases).

```sh
brew install --cask kartax/tap/tokenmeter
```

## What it does

- One popover with every account's usage: percent used per Window (5-hour
  session, week, billing month) and when each resets ("in 2 h 14 m" or the
  date), plus remaining credits where a Provider meters by money.
- Adds Accounts for several Providers and keeps their Readings fresh in the
  background (configurable poll interval), backing off politely when a
  Provider rate-limits.
- Notarized and signed; update checks are built in and can be turned off.

## Providers and authentication

| Provider | How it authenticates | Notes |
|----------|----------------------|-------|
| Claude | Borrows **Claude Code's** login (its Keychain token, read per fetch) | No Claude sign-in of its own; tokens are never stored or refreshed — [ADR 0001](docs/adr/0001-claude-credentials-borrowed-from-claude-code.md). Stale when Claude Code hasn't run for ~8 h. |
| Codex | **Sign-in** in TokenMeter (device-code browser flow) | Own OAuth grant, stored and rotated in the Keychain — [ADR 0003](docs/adr/0003-own-device-code-oauth-for-codex-and-nous.md). |
| GitHub Copilot | **Sign-in** in TokenMeter (GitHub device-code browser flow) | Reads the monthly AI-credit allowance; Free plans show chat and completion limits, and org-managed seats show their plan plus any personal credits GitHub reports. Token stored in the Keychain. |
| Nous Portal | **Sign-in** in TokenMeter (device-code browser flow) | Same flow as Codex. |
| Ollama Cloud | **API key**, pasted in Settings | Create a key on your Ollama dashboard. |
| Venice.ai | **Admin API key**, pasted in Settings | Inference keys cannot read billing; create an **Admin** key at [venice.ai/settings/api](https://venice.ai/settings/api). Reads the daily DIEM epoch (resets 00:00 UTC) plus bundled, earned and USD credit balances. |
| Z.ai | **API key**, pasted in Settings | Reads the GLM Coding Plan's 5-hour and weekly token quotas plus the monthly web-search/reader call quota. |
| xAI | **Management API key + team ID**, pasted in Settings | Reads the team's prepaid USD credit balance (and the postpaid remaining estimate when returned). Inference keys are rejected; create a Management key in the xAI Console. |
| Cursor | Borrows **Cursor's** local login (desktop `state.vscdb` or the `cursor-agent` Keychain item) | Reads the billing-cycle percentage plus Auto and API sub-windows. Tokens are read per fetch and never stored or refreshed. |
| OpenCode | **API key**, pasted in Settings | Reads OpenCode Go/Zen rolling 5-hour, weekly and monthly usage percentages. |
| Alibaba Cloud | **Coding Plan API key** (`sk-sp-…`) + region, pasted in Settings | Reads the Coding Plan's 5-hour, weekly and monthly request quotas from the Model Studio console endpoint. |
| Gemini | Borrows the **Gemini CLI** login (`~/.gemini/oauth_creds.json`) | Reads per-model remaining quota through Google's Code Assist API. Tokens are refreshed in memory only and never stored; the free Code Assist tier has been retired by Google. |
| Antigravity | Borrows the **Antigravity / `agy`** login (CLI token file or Keychain) | Reads per-model remaining quota. Tokens are refreshed in memory only and never stored. |
| MiniMax | **API key** + region (Global or China), pasted in Settings | Reads the Token Plan's current session window from `/v1/token_plan/remains`. |
| Kimi | Borrows the **Kimi Code** login (`~/.kimi/credentials/kimi-code.json`) | Reads the plan usage plus each windowed limit (5-hour, weekly, …). Tokens are refreshed in memory only and never stored. |
| Synthetic | **API key**, pasted in Settings | Reads the rolling 5-hour request limit, weekly budget and optional legacy subscription/search quotas. |
| DeepSeek | **API key**, pasted in Settings | Reads the account's USD/CNY balance (total, granted and topped-up amounts as reported). |
| Mistral | **Admin API key**, pasted in Settings | Reads the Organization's monthly spend against its spend limit. Admin keys require an Enterprise plan; standard inference keys are rejected. |
| Xiaomi MiMo | **Browser cookies**, pasted in Settings | Reads the console balance plus Token Plan credits from `platform.xiaomimimo.com`. Copy the `Cookie` header while signed in; the two required cookies are `api-platform_serviceToken` and `userId`. |

## Privacy

- Provider secrets (tokens, API keys) live **only in the macOS Keychain**,
  never in the config file, never in logs.
- **Borrowed logins are never stored**: Claude Code, Cursor, Gemini CLI,
  Antigravity and Kimi Code tokens are read at fetch time, used for the
  request, and discarded.
- **No telemetry**, no analytics.

## Build & run

Prerequisites: full Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```sh
xcodegen generate          # creates TokenMeter.xcodeproj from project.yml
open TokenMeter.xcodeproj  # pick the TokenMeter scheme and Run (⌘R)
```

To compile-check from the command line without signing:

```sh
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Unit tests (provider parsers are replayed against anonymised fixtures):

```sh
xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

Smoke runs without real accounts: DEBUG builds read
`TOKENMETER_<PROVIDER>_BASE_URL` (e.g.
`TOKENMETER_OLLAMA_BASE_URL=http://127.0.0.1:8765`) to point a Provider at a
local stub server, and `CFFIXED_USER_HOME=/tmp/…` keeps the config out of
`~/Library/Application Support/TokenMeter`. See [AGENTS.md](AGENTS.md).

### Cleaning up development copies

Every build registers its `TokenMeter.app` with LaunchServices, so DerivedData
and worktree builds can fill the app drawer with duplicate icons. List and
remove them with:

```sh
./scripts/clean-dev-apps.sh          # dry run: show registrations and paths
./scripts/clean-dev-apps.sh --apply  # unregister and delete disposable builds
```

`--apply` removes TokenMeter's DerivedData and registered `.app` bundles under
`build/`, `tmp/` and `.xcarchive` (all regenerated by the next build).
`/Applications/TokenMeter.app` is never touched; use `--keep-build-artifacts`
to unregister without deleting files.

## Layout

| Path | Purpose |
|------|---------|
| `TokenMeter/App/` | Entry point, status item + popover, Settings window, update checker |
| `TokenMeter/Popover/`, `TokenMeter/Settings/` | The two SwiftUI surfaces |
| `TokenMeter/Core/` | Domain types, Provider interface + registry, AccountStore, config and Keychain stores |
| `TokenMeter/Providers/<Name>/` | One folder per Provider (reader, credentials, Settings forms) |
| `TokenMeterTests/` | Tests (fixtures contain no real tokens, emails or org ids) |
| `docs/` | The homepage served via GitHub Pages, plus ADRs |

## Releases

`./scripts/release.sh vX.Y.Z[bN] ["notes"]` (maintainer-only) builds a
notarized, stapled `TokenMeter.dmg` and publishes it with
`gh release create`; stable tags also update the Homebrew cask in
`Kartax/homebrew-tap`. Agents and contributors never publish releases.

## Limitations

- Claude data goes stale when Claude Code has not run within the access
  token's lifetime (~8 h) — TokenMeter deliberately never refreshes those
  tokens ([ADR 0001](docs/adr/0001-claude-credentials-borrowed-from-claude-code.md)).
- Providers are **compiled in**; adding one means a code change and a
  release — no runtime plugins
  ([ADR 0004](docs/adr/0004-compiled-in-providers.md)).
- One Claude Account per Claude Code config directory (several accounts
  require several `CLAUDE_CONFIG_DIR`s).
- Cursor, Gemini, Antigravity and Kimi require that app or CLI to be signed in
  on the same Mac; TokenMeter never signs in for them.
- Mistral's Admin API is Enterprise-only; xAI needs a Management key and team
  ID; Xiaomi MiMo needs cookies copied from a signed-in browser session.
- The usage endpoints of Claude, Codex, GitHub Copilot, Cursor, Gemini,
  Antigravity, Z.ai, Kimi, Alibaba Cloud Coding Plan and Xiaomi MiMo are
  undocumented and may change; unusual responses surface as "unavailable"
  rather than wrong numbers.

## Docs

- [Homepage](https://kartax.github.io/tokenmeter/) — screenshots, providers
  table, privacy note
- [Spec thread (#1)](https://github.com/Kartax/tokenmeter/issues/1) — the
  v0.1 plan this repo implements
- [ADRs](docs/adr/): [0001](docs/adr/0001-claude-credentials-borrowed-from-claude-code.md)
  borrowed Claude credentials ·
  [0002](docs/adr/0002-non-sandboxed-app.md) non-sandboxed app ·
  [0003](docs/adr/0003-own-device-code-oauth-for-codex-and-nous.md)
  device-code OAuth · [0004](docs/adr/0004-compiled-in-providers.md)
  compiled-in providers
- [CONTEXT.md](CONTEXT.md) — domain vocabulary