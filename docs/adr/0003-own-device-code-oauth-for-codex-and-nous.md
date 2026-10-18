# Codex and Nous Portal Accounts use TokenMeter's own device-code OAuth login

Codex and Nous Portal Accounts sign in through TokenMeter's own OAuth device-code flow, reusing the public client IDs of the Codex CLI and Hermes Agent, and TokenMeter stores and rotates the resulting tokens in its own Keychain items. This gives each Account an independent grant that stays fresh without the CLI installed or running, and never races the CLI's single-use refresh tokens.

## Considered Options

- Reading `~/.codex/auth.json` / `~/.hermes/auth.json` read-only: no login step, but Readings go stale whenever the CLI is idle (Nous access tokens last ~1 h), and refreshing those tokens ourselves would revoke the CLI's session.

## Consequences

Neither provider documents third-party client registration; if either blocks the borrowed client ID, that Provider needs a new auth path.
