---
summary: "OpenCode Go provider entry point: subscription usage, source selection, and local SQLite cost history."
read_when:
  - Configuring OpenCode Go separately from OpenCode
  - Finding OpenCode Go usage and local-history documentation
---

# OpenCode Go

OpenCode Go is registered separately from OpenCode as `opencodego`. It supports `auto`, `api`, and `web` sources,
with five-hour, weekly, and monthly quota windows when reported by the selected source. Local cost history reads
OpenCode Go assistant records from `~/.local/share/opencode/opencode.db`.
Both legacy `message`/`part` history and v2 `session_message` history are supported; migrated messages are counted once.

Auto and API sources can reuse the active OpenCode CLI login without another API key. V2 credentials come from
the CLI's SQLite database; older installs use the `opencode-go` entry in `auth.json`. An active Go credential takes
precedence over the general OpenCode OAuth login. Explicit CodexBar accounts, manual cookies, and workspace overrides
do not borrow an unrelated CLI login. A successful CLI quota read reports `local+cli` when local history is available,
or `cli` without local history. CLI quota reads do not import browser cookies or attach another browser account's balance.
Credentials stay read-only; renew an expired OAuth login through OpenCode. CodexBar rereads the active login on each fetch.

Without a configured API key, a usable CLI login, or a usable browser session, Auto can return `source: "local"` and
`usage.dataConfidence: "estimated"`. Its $12/$30/$60 denominators apply to five-hour, weekly, and monthly
local cost windows; they are fixed estimates, **not detected subscription tiers or Console quotas**. Local history
covers only this device, and its inferred monthly boundary can differ from the billing cycle. Even a low local
percentage cannot establish that the account has headroom. Consumers deciding account availability must check
`dataConfidence` or request `--source api` / `--source web` with valid authentication.

The menu bar prefixes estimated percentages with `~`; the expanded menu and text CLI label them as estimated.
JSON retains numeric percentages and the explicit confidence field. Auto prefers available API meters and overlays
Console meters from cached, manual, or newly discovered browser sessions before returning local estimates.
Discovery uses the provider's default browser order and the shared browser-access gate: background Chromium reads
require an existing no-UI Safe Storage grant, and the actual cookie read disallows Keychain interaction. Missing,
blocked, or rejected discovered sessions leave the local estimate available; Cookie source Off disables discovery.
An invalid manual credential still surfaces its authentication error. No local estimate is used for pace forecasts.

Unchanged database scans are reused within the app/server process, keyed by the database and SQLite `-wal`
sidecar sizes and modification dates. WAL commits, checkpoints, and removal invalidate the cache. One parsed-row
payload of at most 4 MiB (row storage plus model text, excluding allocator overhead) is retained; larger payloads
remain readable but are not cached. Exact row timestamps let quota windows, resets, and requested history ranges
advance on cache hits. Separate CLI invocations each perform their own initial scan.

The shared [OpenCode guide](opencode.md) documents authentication, scoped source selection, usage mapping, and the
boundary between device-local estimates and account quota. Keep those details there so the two guides do not drift.

```bash
codexbar usage --provider opencodego --format json --pretty
```
