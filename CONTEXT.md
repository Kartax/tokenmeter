# TokenMeter

A macOS menu-bar app that shows, at a glance, how much of each AI subscription's usage allowance is left before it resets.

## Language

**Provider**:
An AI service whose subscription usage TokenMeter knows how to read (Claude, Codex, Ollama Cloud, Nous Portal).
_Avoid_: Vendor, service, integration

**Account**:
One configured login at a Provider, carrying a user-chosen label; a Provider may have several Accounts.
_Avoid_: Profile, connection, provider (when one login is meant)

**Plan**:
The subscription tier an Account is on, as reported by the Provider (e.g. Max 5x, Pro, Ultra).
_Avoid_: Tier, subscription

**Window**:
A period with its own usage limit and reset time, e.g. a 5-hour session, a week, or a billing month.
_Avoid_: Period, block, cycle

**Quota**:
How much of a Window's limit an Account has used, expressed as percent used plus the Window's reset time.
_Avoid_: Contingent, budget, allowance, limit

**Credit balance**:
A monetary amount an Account can still spend, used where a Provider meters by credits rather than by percent.
_Avoid_: Budget, funds, spend

**Reading**:
The Quotas and Credit balance fetched for one Account at one moment, with the time they were taken.
_Avoid_: Snapshot, status, sample
