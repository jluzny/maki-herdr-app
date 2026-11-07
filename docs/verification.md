# Verification record

## Observed smoke test

A clean remote install of commit `891daf3af3d94a042b7946d3d0ef4fcd950dfed7` passed source and permission approval in an isolated Maki 0.7.1 / Herdr core 0.1.18 session. The core observed `idle` at startup and a clear on clean exit. No model request was made.

A `/reload` probe observed a clear, but the UI was recreated without credentials and exited. A successful reload was therefore not verified.

## Not yet verified

The smoke test did not verify:

- Delayed UI readiness.
- Lifecycle or reload behavior beyond the incomplete `/reload` probe.
- In-flight append teardown.
- Model and turn lifecycle.
- Desktop GUI rendering.

No supported, repository-owned, validated real-host acceptance harness currently exists. The only tested isolation mechanism is the disposable remote-install session above. Do not assume a local scratch configuration or state root, `maki --print`, ACP, or the installed `hc` and `herdr-app` CLIs provide equivalent isolation. Never automate probes, reloads, or acceptance runs against an active user core or Desktop.

## Automated coverage

The Lua suite uses mock host APIs; it cannot establish Maki host or Desktop GUI compatibility. It covers the status reducer and OSC encoder, tool validation and summaries, delayed startup readiness, snapshot retries, lifecycle teardown reasons, reload semantics, suspended append teardown, bounded polling, and failed or late append behavior. This is host-contract coverage, not real-host acceptance.

Run from the repository root:

```sh
lua tests/run.lua
stylua --check .
git diff --check
```

CI used Lua 5.4 and StyLua 2.1.0. Maki 0.7.1 has no `maki test` command.

## Safe acceptance checklist

Only in a disposable direct Herdr pane:

1. Confirm the Agents panel shows startup `idle`.
2. Exercise `working`, input-needed, completion after background work, and cancellation.
3. Exercise multiple tabs plus reset/delete.
4. Exercise reload and clean exit.
5. Confirm rendering remains intact and unrelated panes are unaffected.

Do not inject probe or clear sequences into unrelated panes. If status is absent, check the direct pane, controlling TTY, both Herdr environment variables, package approval, Maki version, and Maki logs. Bug reports should include versions, setup, and minimal reproduction steps; omit prompts, credentials, terminal transcripts, and private session data.

## Runtime cleanup limits

On `shutdown`, `reload`, `replaced`, or `completed`, the bridge stops intake and cancels timers. If it has emitted a status and no append is in flight, it attempts a clear. During a status append, the `SessionEnd` callback may poll with 1 ms sleeps for up to 20 sleeps and at most one quarter of the reported deadline above a 100 ms reserve; it declines when the deadline or sleep API is unsuitable. If the append completes in time, it attempts a clear; an in-flight clear is retried only if it failed and a prior status remains outstanding.

This is best effort, not a shutdown guarantee. Maki reports the shared grace period at dispatch, which can already be stale. The API has no remaining-deadline clock or bounded, cancellable append. Sleeps can resume late, the host can cancel the callback or clear, and a blocked filesystem operation can continue after cancellation or timeout, including after a new plugin generation starts. A failed clear, late append, or hard kill can leave stale status.
