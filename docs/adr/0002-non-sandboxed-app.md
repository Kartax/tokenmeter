# TokenMeter ships without the App Sandbox

Unlike the sibling immich-desktop-app, TokenMeter is not sandboxed: reading Claude Code's Keychain item (ADR 0001) and honouring `CLAUDE_CONFIG_DIR` paths is impossible from a sandboxed app. Distribution stays Developer ID signed, hardened runtime, and notarized, so Gatekeeper and the Homebrew cask behave the same.
