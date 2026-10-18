# AGENTS.md

## Build and validation

- `project.yml` is the source of truth; `TokenMeter.xcodeproj` is generated and gitignored. Run `xcodegen generate` after changing `project.yml` or adding/removing Swift files.
- Unsigned build (scheme `TokenMeter`):
  ```sh
  xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
    -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
  ```
- Unit tests (`TokenMeterTests`, hosted in the app):
  ```sh
  xcodebuild -project TokenMeter.xcodeproj -scheme TokenMeter \
    -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
  ```
- Logs: `log stream --level debug --predicate 'subsystem == "org.kartax.TokenMeter"'` (or `log show --last 5m --info --debug --predicate …` after the fact).
- Layout: `TokenMeter/App` (entry point, `AppDelegate` owning status item, popover, cached Settings window), `TokenMeter/Popover`, `TokenMeter/Settings` (Accounts/General tabs). Domain types, the Provider interface and registry, `AccountStore`, config and Keychain stores go in `TokenMeter/Core`; each Provider is one folder `TokenMeter/Providers/<Name>` (Provider, credentials, Settings forms) plus one case in `ProviderRegistry`. The app is `LSUIElement` and not sandboxed (ADR 0002); keep it an AppKit status-item app, not a SwiftUI window app.
- Provider tests (seam A) replay anonymised JSON from `TokenMeterTests/Fixtures` through `HTTPStub` (a `URLProtocol`); fixtures must contain no real tokens, emails or org ids.
- Smoke runs without real accounts: DEBUG builds read `TOKENMETER_<PROVIDER>_BASE_URL` (e.g. `TOKENMETER_OLLAMA_BASE_URL=http://127.0.0.1:8765`) to point a Provider at a local stub; launch the binary in `TokenMeter.app/Contents/MacOS/` directly so the variable is inherited.
- Smoke-run process hygiene: multiple TokenMeter instances can run side by side (sibling agents' worktrees). Always target **your** instance by its exact pid; never `pkill` by name — `pkill -f TokenMeter` from one agent kills every ticket's smoke run, including ours.
- Smoke runs that need an Account (and must not touch the Keychain, which would trigger a consent prompt): DEBUG builds also read `TOKENMETER_DEBUG_INSECURE_SECRETS=1` (together with `CFFIXED_USER_HOME`); Provider credentials (Ollama, Codex, Nous) are then stored as files under `<CFFIXED_USER_HOME>/secrets/` instead of the Keychain. Never in release.
- Claude smoke runs without touching the real login: add a Claude Account for a temp config directory containing a `.credentials.json` with a fake token (`{"claudeAiOauth":{"accessToken":"fake","expiresAt":<ms>,"subscriptionType":"max"}}`; it is read when no `Claude Code-credentials-<hash>` Keychain item exists) and set `TOKENMETER_CLAUDE_BASE_URL`. Reading the real `Claude Code-credentials` item from an unsigned or re-signed build triggers a macOS Keychain consent prompt.
- Refresh scheduling is logged by `AccountStore` (category `core`): `Polling every N min`, `Refresh (launch|scheduled|popover|manual) of N Accounts`, `Refresh (popover) skipped: …`, `Skipping <id>: backed off …`. Use the 1-minute poll interval to watch the cadence. To keep a smoke run off the shared `~/Library/Application Support/TokenMeter`, launch with `CFFIXED_USER_HOME=/tmp/<dir>` (the config moves under it; the Keychain is unaffected).

## Architecture invariants

- Secrets live only in the Keychain (generic password, service `org.kartax.TokenMeter`, account = Account id, value = Provider-specific JSON). Never write a secret to the config file (`~/Library/Application Support/TokenMeter/config.json`) or to logs; don't interpolate tokens or keys into `Logger` messages. Removing an Account deletes its Keychain item. DEBUG-only exception (smoke runs, see above): with `TOKENMETER_DEBUG_INSECURE_SECRETS=1` set, Provider credentials are file-backed under `<CFFIXED_USER_HOME>/secrets/` instead; the variable is read only in DEBUG builds, never in release.
- Claude Code tokens are borrowed (ADR 0001): read from Claude Code's Keychain item (or `<config dir>/.credentials.json`) fresh on every fetch, held in memory only for that request, and never stored, copied (Keychain, config, logs) or refreshed. TokenMeter has no Claude sign-in; an expired token shows "Login expired — run `claude`" without a request. Removing a Claude Account never touches Claude Code's item. `ClaudeCredentials` is intentionally not `Encodable`.
- Windows are identified by their data (e.g. window length or the response field that names them), never by a response's slot position (primary/secondary, array index).
- Config fields are optional and decoded leniently (immich `AppConfig` pattern); never require a migration.
- All fetches outside Account setup go through `AccountStore.refreshAll(_:)`/`refresh(_:)`, which never duplicate an in-flight fetch and skip an Account while it backs off after a rate limit (`Retry-After`, else 60 s). The last Reading per Account is persisted in the config file (no secrets) and shown stale after launch until refreshed.

## Icon and releases

- The app icon is generated: `swift scripts/icon/make-app-icon.swift` renders `TokenMeter/Assets.xcassets/AppIcon.appiconset/icon_*.png` and the homepage logo `docs/logo.png`/`docs/logo@2x.png`. Change the design in the script, re-run it, and commit the PNGs; don't edit them by hand. The DMG volume icon is built from the asset-catalog PNGs at release time.
- `./scripts/release.sh` builds a notarized, stapled `build/TokenMeter.dmg` locally (xcodegen, archive, Developer ID export via `ExportOptions.plist`, `create-dmg` with the background from `scripts/dmg/make-background.swift`, Developer ID signature on the DMG, `notarytool` with keychain profile `NOTARY` or `NOTARY_PROFILE`, staple, `stapler validate` + `spctl`). It needs `create-dmg`, `xcodegen`, the "Developer ID Application" certificate (team `8HAG9JU2ZK`) and the `NOTARY` profile. It never tags or publishes; `build/` is gitignored, never commit DMGs.
- `./scripts/release.sh vX.Y.Z[bN] ["notes"]` additionally publishes: pre-flight refuses a dirty tree (`ALLOW_DIRTY=1` overrides), an existing tag (local or origin) and an existing release, then `gh release create` creates the tag at the built commit with the single asset `TokenMeter.dmg`. Stable tags then run `scripts/update-homebrew-cask.sh`, which dispatches and watches `update-tokenmeter.yml` in `Kartax/homebrew-tap` (its `run-name` must be `Update TokenMeter <tag>`); `bN` pre-releases skip the tap.
- `PREFLIGHT_ONLY=1 ./scripts/release.sh vX.Y.Z` runs only the pre-flight checks and exits before building or publishing; use it to check the guards.
- **Agents never publish releases**: never run `release.sh` with a version argument (except with `PREFLIGHT_ONLY=1`), never run `gh release create`, `update-homebrew-cask.sh`, or create/push tags. Releases are published by the maintainer.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `Kartax/tokenmeter`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.
