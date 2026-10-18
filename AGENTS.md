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

## Icon and releases

- The app icon is generated: `swift scripts/icon/make-app-icon.swift` renders `TokenMeter/Assets.xcassets/AppIcon.appiconset/icon_*.png` and the homepage logo `docs/logo.png`/`docs/logo@2x.png`. Change the design in the script, re-run it, and commit the PNGs; don't edit them by hand. The DMG volume icon is built from the asset-catalog PNGs at release time.
- `./scripts/release.sh` builds a notarized, stapled `build/TokenMeter.dmg` locally (xcodegen, archive, Developer ID export via `ExportOptions.plist`, `create-dmg` with the background from `scripts/dmg/make-background.swift`, `notarytool` with keychain profile `NOTARY` or `NOTARY_PROFILE`, staple, `stapler validate` + `spctl`). It needs `create-dmg`, `xcodegen`, the "Developer ID Application" certificate (team `8HAG9JU2ZK`) and the `NOTARY` profile. It never tags or publishes; `build/` is gitignored, never commit DMGs.
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
