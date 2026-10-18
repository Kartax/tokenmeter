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

## Architecture invariants

- Secrets live only in the Keychain (generic password, service `org.kartax.TokenMeter`, account = Account id, value = Provider-specific JSON). Never write a secret to the config file (`~/Library/Application Support/TokenMeter/config.json`) or to logs; don't interpolate tokens or keys into `Logger` messages. Removing an Account deletes its Keychain item.
- Windows are identified by their data (e.g. window length or the response field that names them), never by a response's slot position (primary/secondary, array index).
- Config fields are optional and decoded leniently (immich `AppConfig` pattern); never require a migration.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `Kartax/tokenmeter`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.
