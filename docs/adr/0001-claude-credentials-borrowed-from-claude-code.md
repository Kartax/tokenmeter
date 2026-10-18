# Claude credentials are borrowed from Claude Code, never obtained by TokenMeter

Anthropic's Claude Code terms forbid third-party apps from offering Claude.ai login or storing Claude.ai session tokens, so TokenMeter has no Claude sign-in of its own. A Claude Account reads Claude Code's OAuth access token from its Keychain item (`Claude Code-credentials`, suffixed per `CLAUDE_CONFIG_DIR`) at fetch time, calls the usage endpoint, and discards it; it never stores or refreshes the token, because Claude Code owns the single-use refresh-token rotation. An expired token surfaces as "Login expired — run `claude`".

## Considered Options

- Own OAuth login with Claude Code's client ID: explicitly prohibited by Anthropic.
- Driving `claude` in a PTY and scraping `/usage`: no token handling, but breaks on every TUI change and takes seconds per refresh.

## Consequences

Claude data goes stale when Claude Code has not run for the access token's lifetime (~8 h). Several Claude Accounts require several Claude Code config directories. The usage endpoint is undocumented and may be closed to non-Claude-Code clients.
