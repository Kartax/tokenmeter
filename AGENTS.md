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
- Layout: `TokenMeter/App` (entry point, `AppDelegate` owning status item, popover, cached Settings window), `TokenMeter/Popover`, `TokenMeter/Settings` (Accounts/General tabs). Domain types and Providers go in `TokenMeter/Core`. The app is `LSUIElement` and not sandboxed (ADR 0002); keep it an AppKit status-item app, not a SwiftUI window app.

## Agent skills

### Issue tracker

Issues and specs live in GitHub Issues on `Kartax/tokenmeter`, managed with the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default five-role vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: root `CONTEXT.md` plus `docs/adr/`. See `docs/agents/domain.md`.
