# Maki → Herdr Desktop status bridge

An experimental Maki package that reports one aggregate status for all live Maki tabs to the current Herdr Desktop pane using OSC 7501. This is an agent-side bridge, not a Desktop mod or launcher.

**Verification:** A clean remote install of commit `891daf3af3d94a042b7946d3d0ef4fcd950dfed7` passed the source and permission approval flow in an isolated Maki 0.7.1 / Herdr core 0.1.18 session. Core observed `idle` at startup and a clear on clean exit; no model request was made. A `/reload` test observed a clear but exited when the UI was recreated without credentials, so successful reload is unverified. Desktop GUI rendering and the real model/turn lifecycle are also unverified. Do not rely on this bridge for critical status.

## Requirements and limits

| Environment | Status |
| --- | --- |
| Interactive Maki 0.7.1+, Herdr core 0.1.18, direct Linux/WSL Desktop pane | Target; Desktop GUI acceptance pending |
| Headless/ACP, no controlling TTY, native Windows output, nested tmux | Unsupported |

The manifest requires Maki 0.7.1 or newer; newer versions have not been verified. The reporter checks for nonempty `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` and a focused live session before writing to `/dev/tty`. It retries unavailable or unfocused snapshots up to 20 times at 100 ms intervals, then waits for a future event. Exhaustion is silent for an initial valid snapshot without a focused session; otherwise it logs a warning. Environment variables alone do not establish correct pane routing, especially through multiplexers. The TTY write is not a documented synchronized Maki terminal-output API: it can interleave with the renderer. A hard kill can leave stale status.

## Installation and updates

Review the source and add this entry to your global `~/.config/maki/init.lua` alongside existing configuration. For reproducible installs, add a reviewed commit or tag as `version`:

```lua
maki.pack.add({
  { src = "https://github.com/jluzny/maki-herdr-app" },
})
```

Start Maki interactively in a direct Herdr pane, approve the source and the requested permissions only after review, and use `/reload` or restart if needed. The package auto-loads; no manual `require` is needed. Change `version` only after reviewing a newer commit or release. Maki records the selected commit in the global config directory's `pack-lock.json`; an existing lock entry takes precedence over a later `version` change. To update, use `/packupdate maki-herdr-app` and review the proposed revision, or remove only this package's lock entry and restart to resolve the declared version. Avoid committing machine-local approvals or credentials.

## Status behavior

The implementation reconciles lifecycle events with live session snapshots and emits only changed aggregate states. Priority is:

| Status | Implemented condition |
| --- | --- |
| `blocked` | Any live tab is `needs_input`; the reason is not reported. |
| `working` | Otherwise, any live tab is `working`, including background work represented by that status. |
| `done` | Otherwise, at least one idle tab has a recorded finished turn, and no live tab has an unknown status. |
| `idle` | Otherwise, including when an unknown status prevents `done`. |

A `TurnEnd` with reason `finished` records `done` only if the bridge observed that tab's `TurnStart`. It is shown when that tab is idle and no higher-priority or unknown status masks it. The outcome stays recorded until that tab starts a new turn, is reset or removed, or disappears from the live snapshot; focusing a tab does not acknowledge it. Other turn-end reasons clear that tab's outcome rather than inventing success or failure. The encoder accepts `error`, but the runtime does **not** implement or emit error status. Real event ordering, cancellation, background drain and multi-tab lifecycle behavior still need live verification.

Each report is a root OSC 7501 record with fixed `app=maki`, no child ID, and an ST terminator. Root reports replace the pane record; root clear also removes child records. Avoid competing reporters in the same pane. After snapshot retries are exhausted, the bridge makes one best-effort clear if it has emitted a status, then waits for a future event; a valid snapshot can re-emit even the same status.

On `shutdown`, `reload`, `replaced` or `completed`, the bridge stops intake and cancels its timers. If no append is in flight, it attempts a clear only if it emitted a status. Otherwise, inside the `SessionEnd` callback it polls the in-flight append with 1 ms sleeps, up to 20 sleeps and at most one quarter of the reported deadline above a 100 ms reserve. It declines to wait if the deadline is missing, invalid or at most 100 ms, or sleep is unavailable. If a status append returns in time, it attempts one clear, even if that append reported failure; an already in-flight clear is not repeated. On timeout or sleep failure it abandons the clear, including when the old append later returns. Non-teardown close and failure paths retain their deferred-clear behavior.

This is best effort, not a shutdown guarantee. Maki reports the shared grace period remaining at dispatch, not at this callback; it may already be stale, and the API provides no remaining-deadline clock or bounded/cancellable append. Sleeps can resume late and the host can cancel the callback or the clear. A blocked `spawn_blocking` filesystem operation may continue after cancellation or timeout, including after a new plugin generation starts; Lua-side serialization cannot prevent cross-generation writes. A failed clear, late append or hard kill can leave stale status.

## Orchestration guidance

When both `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` are nonempty strings, the package adds a prompt hint to run the exact bash command `hc --skill` and read its output before coordinating terminals or agents. It also registers an allow rule for that exact bash scope only; other commands and variants remain subject to normal permissions. User configuration and session deny rules override the plugin allow. For repeated `hc` blocked notifications, the hint advises notifying the user once per unresolved prompt, inspecting a changed prompt again and notifying as needed, and never bypassing approvals. The hint is guidance, not a registered Maki skill or an enforcement mechanism. The package does not launch agents or run `hc` automatically. Inherited variables do not prove that a terminal is correctly routed to Herdr.

The rule is active for the plugin host while it is loaded, after the environment check. Maki checks parsed shell command scopes: an allowed `hc --skill` segment can appear in a compound command while other segments are checked separately. The rule matches the command name, not the executable's resolved path; make sure the `hc` found on `PATH` is trusted.

## Privacy and permissions

The bridge emits only the aggregate state and fixed app identifier, not prompts, answers, titles, paths, credentials or conversation content. It requests `env` to read the two Herdr variables, `fs_write` to append fixed sequences to `/dev/tty`, and `run` to register the exact `hc --skill` bash allow rule. These grants are broader than those uses: `env` can expose environment secrets, `fs_write` can modify files, and `run` permits the plugin to start processes. Review the package and manifest before approving them. Existing installations updating to this version may be prompted to approve the additional `run` permission. It does not request conversation-content permissions or network access.

## Verification and troubleshooting

In a disposable direct Herdr pane, check the Agents panel and exercise startup idle, working, input-needed, completion after background work, cancellation, multiple tabs, reset/delete, reload and exit. Confirm rendering remains intact and other panes are unaffected. Do not inject probe or clear sequences into unrelated panes. If status is absent, check the direct pane, controlling TTY, both environment variables, package approval and Maki version; inspect Maki's logs for package or permission warnings without sharing sensitive data. The reporter disables itself on write failure or loss of the interactive session; cleanup may fail as described above.

When reporting a bug, include versions, setup and minimal reproduction steps; omit prompts, credentials, terminal transcripts and private session data. Automated Lua tests use mock host APIs and cannot establish host or GUI compatibility.

## Uninstall

Remove only this package's declaration from global `init.lua`, then `/reload` or restart. Removing the declaration stops loading but leaves the checkout and lock entry. Once inactive in all Maki processes, use `/packdel maki-herdr-app` and review the removal; Maki removes its approval when its files are gone. Preserve unrelated packages and configuration.

## Architecture and development

`plugin/herdr.lua` starts the Maki adapter in `lua/maki_herdr_app/`. The host-independent reducer and OSC encoder live under `lua/herdr_status/`; the runtime uses the supplied host for output. These are internal boundaries, not a stable public module API. Future Desktop integrations, if implemented, belong in separate, independently installable directories under `integrations/herdr-desktop/<plugin-name>/`; none is currently included or enabled by this package.

From the repository root, run `lua tests/run.lua` and `stylua --check .` with Lua 5.4 and StyLua 2.1.0 as used in CI. These checks are separate from real-host smoke tests and user-assisted GUI acceptance. Maki 0.7.1 has no `maki test` command.

## Catalogs

The [Maki plugin catalog](https://maki.sh/plugins/) discovers public, non-archived GitHub repositories with both `maki` and `plugin` topics; direct package installation does not require a listing. Discovery can be delayed or limited and is not an endorsement. The published repository has both topics and appears in GitHub search; its rendered catalog listing has not been verified.

Herdr Desktop's [mods gallery](https://herdr.dev/gallery/?type=mods), Desktop launcher entries and agent-side OSC bridges are separate things. This package is only the latter; it does not install a mod or launcher. Herdr TUI's plugin system is also separate, so its manifest and install commands do not install this Desktop status bridge.

MIT licensed; see [LICENSE](LICENSE).
