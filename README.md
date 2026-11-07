# Maki → Herdr Desktop status bridge

A Maki package that reports one aggregate status for all live Maki tabs to the current Herdr Desktop pane using OSC 7501, and provides `hc_status` and `hc_command` tools. This is an agent-side bridge, not a Desktop mod or launcher.

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

On `shutdown`, `reload`, `replaced` or `completed`, the bridge stops intake and cancels its timers. If no append is in flight, it attempts a clear only if it emitted a status. Otherwise, inside the `SessionEnd` callback it polls the in-flight append with 1 ms sleeps, up to 20 sleeps and at most one quarter of the reported deadline above a 100 ms reserve. It declines to wait if the deadline is missing, invalid or at most 100 ms, or sleep is unavailable. If a status append returns in time, it attempts one clear, even if that append reported failure; an in-flight clear is retried only if it failed and a prior status remains outstanding. On timeout or sleep failure it abandons the clear, including when the old append later returns. Non-teardown close and failure paths retain their deferred-clear behavior.

This is best effort, not a shutdown guarantee. Maki reports the shared grace period remaining at dispatch, not at this callback; it may already be stale, and the API provides no remaining-deadline clock or bounded/cancellable append. Sleeps can resume late and the host can cancel the callback or the clear. A blocked `spawn_blocking` filesystem operation may continue after cancellation or timeout, including after a new plugin generation starts; Lua-side serialization cannot prevent cross-generation writes. A failed clear, late append or hard kill can leave stale status.

## Orchestration guidance

When both `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` are nonempty strings, the package adds the prompt hint: `For Herdr Desktop, read 'hc --skill' via bash. Prefer hc_status and hc_command for other supported hc calls. Check PATH for 'herdr-app'; if absent in WSL, check 'herdr-app.exe'. Read the available CLI's --skill before Desktop operations. Do not report a missing CLI by itself; report any task you cannot complete.` It also registers an allow rule for that exact bash scope only; other commands and variants remain subject to normal permissions. User configuration and session deny rules override the plugin allow. The hint is guidance, not a registered Maki skill or an enforcement mechanism. The package does not launch agents or run `hc` automatically; `hc_status` invokes it when called. Inherited variables do not prove that a terminal is correctly routed to Herdr.

For Desktop orchestration, use `hc`, not the `herdr` TUI or `HERDR_ENV`. Use Desktop window tooling only when arrangement is necessary; if it is unavailable, do not substitute `herdr` or `HERDR_ENV`. On WSL, `herdr-app.exe` can invoke the Windows Desktop CLI when a trusted executable is exposed on the WSL PATH and interop works. Neither executable name was on this machine's WSL PATH when tested; the hint alone does not add it. Resolve and trust the executable before use. The hint does not search Windows PATH or change configuration. Reuse explicitly requested existing terminals safely: inspect both `hc get` and `hc read` (the screen), confirm authorization before acting, and ask the user if the prompt or intended action is ambiguous. Never bypass approvals or use `--force`.

A successful send is not proof an agent launched or is ready: inspect and verify state before reporting. After a timeout or error, an operation may still be running or have taken effect; inspect state before retrying, rather than retrying blindly. For syntax, use `hc help`; avoid piping `hc schema` to `head`, which can cause a broken pipe. Use a full consumer and check for truncation instead.

The rule is active for the plugin host while it is loaded, after the environment check. Maki checks parsed shell command scopes: an allowed `hc --skill` segment can appear in a compound command while other segments are checked separately. The rule matches the command name, not the executable's resolved path; make sure the `hc` found on `PATH` is trusted.

Direct `hc_status` and `hc_command` calls, or a batch of independent calls, let Maki render their readable UI summaries. If called inside `code_execution`, the script receives raw tool results; printing them can display large or sensitive JSON instead of the summary. Parse and filter in the script and print only needed fields. This guidance is not enforced and does not change raw full/compact output, permissions, or other raw-output fallbacks. Full schema output can be huge: prefer `hc help` for syntax or filter for the needed schema details; check for truncation.

## `hc_status` inspection tool

The agent can call `hc_status` with an `action`:

- `ls` lists terminals; it accepts neither `target` nor `timeout`.
- `get` inspects one terminal; it requires `target` and does not accept `timeout`.
- `wait` waits for one terminal; it requires `target` and accepts an integer `timeout` in seconds (1–120, default 30).

The explicit target is a terminal name or `machine/name`, using only ASCII letters, digits, `_`, `.` and `-` in each part, at most 128 bytes total. The tool invokes `hc ls`, `hc get`, or `hc wait` with JSON output through nested `bash`; it does not run commands in terminals or send messages. Status operations may start the Herdr core or mark child news as seen.

Nested bash calls use normal permission checks and may require approval; the package does not auto-allow these status commands. The separate `hc --skill` rule above does not allow them. Invalid inputs are rejected; nested call errors are returned to the agent.

The UI summary displays filtered status fields, with up to 25 valid terminals and machines for `ls` and 25 children for `wait`; invalid or excess rows are omitted. Wait summaries include available exit codes, signals and message senders. This is not a confidentiality boundary: the model receives the raw tool output, errors may appear raw in the UI, and restoring a session can briefly display raw output before the summary. Output may include sensitive data. Compact output is limited to 16 KiB and may be truncated into incomplete, non-JSON text; bash may impose its own limits or rewrite output. Malformed or oversized output may not produce a summary.

## `hc_command` execution tool

The agent can call `hc_command` with an `argv` array of separate strings, excluding the `hc` executable, for example `{"argv":["ls","--json"]}`. It validates arguments and invokes `hc` through nested `bash` with the original permission context. This is a bounded subset, **not full `hc` parity**; use `bash` directly, subject to its permissions, for unsupported commands, options or argument characters.

Supported command forms are:

- `run` (requires `--bg` before the program), `ls`, `get`, `read`, `wait`, `label`, `keep`, `keys`, `interrupt`, `put`, `schema`, `send`, `kill`, `rm`, `templates`, `exec` and `update`.
- `file read`, `file edit`; `machine ls`, `add`, `update`, `rename`, `rm`; and `server start`, `stop`, `status`, `restart`.
- `help` with up to two lowercase topics, standalone `--help`, `-h`, `--version`, `-V`, `--skill`, `--licenses`, and command or subcommand `--help`/`-h` forms.

Only the implementation's allowlisted options and argument counts are accepted, not every option supported by `hc`; use `hc` help for syntax and check this tool's validation for its subset. `send --force` and `update --force` are rejected. `machine add` requires `--install` and a target or `--via`; `--via` also requires `--name`. Interactive `attach`, `connect` and `machine login`, streaming `events`, `file write` via stdin, `exec --stdin`/`-i` and foreground `run` are not supported. Arguments after the program in `run` or `exec` belong to that program, not to `hc`.

Each argument is restricted to ASCII letters, digits, spaces and `_ . , / : @ + = - ' ( )`. Apostrophes and parentheses are literal characters, not shell syntax; each argument is double-quoted for the nested bash call. Double quotes, other shell metacharacters, backslashes, newlines and non-ASCII text are rejected even inside a single argument. In particular, Windows paths using backslashes and paths containing other unsupported characters cannot be passed; a forward-slash path is not automatically rejected just because it is a Windows path. Input must be a nonempty dense array of at most 128 strings, each at most 16,384 bytes and at most 65,536 bytes total; no other input fields are accepted.

Nested `bash` calls use normal permission checks and may require approval; the package does not auto-allow `hc_command` operations. The separate `hc --skill` rule above is not a general `hc` allow. An approval may be generalized by Maki beyond the exact invocation, depending on the approval choice and host behavior; review its scope before approving. Trust the `hc` on `PATH`.

The tool timeout is 140 seconds, with 130 seconds for the nested bash call; individual `hc` timeout options are separate. A timeout or error does not prove that an operation had no effect: commands can start or change terminals, send messages, edit files, manage machines or servers, or update software. Inspect state before retrying, especially for non-idempotent actions; background work may continue.

Recognized JSON responses for terminal run/list/get/kill/remove/label/keep, send/wait (including wait children, signals and message senders), read, interrupt, keys, put, file read/edit, exec, server start/status/stop/restart, update, templates and machines receive filtered UI summaries. List and child rows are limited to 25 per group; `ls` also shows machine names and states. Read and file read summaries display text, and exec summaries decode base64 stdout and stderr and replace invalid UTF-8; each is limited to 4 KiB and 25 lines with control characters replaced and an indicator when content is omitted. If decoding fails, the raw response is displayed instead; model output is unchanged. These previews can expose sensitive data. Put/file edit summaries omit paths. Server start shows observed status, not whether a new server was started; restart output does not confirm a successful restart. Unrecognized response shapes and plain text use the raw fallback. Other output, errors, malformed or oversized JSON, and summary failures fall back to raw UI output, compacted to 16 KiB with control characters replaced. Summaries are not a privacy boundary: the model receives the tool output, and output or errors may contain sensitive data and may appear raw, including during session restoration or in transcript search. Compact model output is limited to 16 KiB and can be incomplete, non-JSON text; full mode preserves the returned text, but bash may impose its own limits or rewrite it. Restoration renders saved output without rerunning the command.

For `schema`, a recognized OpenRPC JSON response gets a UI-only preview of up to 25 method names, not the complete schema; invalid or excess names are omitted. The model still receives the underlying output, not this preview. In compact mode, nested bash may truncate the schema before the plugin can parse it, and the tool's own 16 KiB limit can also truncate it, leaving incomplete, non-JSON text and potentially omitting methods or details. For the complete schema, use direct `bash` with `hc schema --json` in full output mode; even then, bash may impose its own limits or rewrite output. Check for truncation before relying on the result.

## Privacy and permissions

The OSC bridge emits only the aggregate state and fixed app identifier, not prompts, answers, titles, paths, credentials or conversation content. The package requests `env` to read the two Herdr variables, `fs_write` to append fixed sequences to `/dev/tty`, and `run` for the `hc --skill` bash allow rule, `hc_status` and `hc_command`. These grants are broader than those uses: `env` can expose environment secrets, `fs_write` can modify files, and `run` permits the plugin to start processes. Review the package and manifest before approving them. Existing installations updating to this version may be prompted to approve the additional `run` permission. It does not request conversation-content permissions or network access.

## Verification and troubleshooting

In a disposable direct Herdr pane, check the Agents panel and exercise startup idle, working, input-needed, completion after background work, cancellation, multiple tabs, reset/delete, reload and exit. Confirm rendering remains intact and other panes are unaffected. Do not inject probe or clear sequences into unrelated panes. If status is absent, check the direct pane, controlling TTY, both environment variables, package approval and Maki version; inspect Maki's logs for package or permission warnings without sharing sensitive data. The reporter disables itself on write failure or loss of the interactive session; cleanup may fail as described above.

When reporting a bug, include versions, setup and minimal reproduction steps; omit prompts, credentials, terminal transcripts and private session data. Automated Lua tests use mock host APIs and cannot establish host or GUI compatibility.

No supported, repository-owned, validated real-host acceptance harness currently exists. The isolated remote-install smoke test recorded above verified source and permission approval plus startup `idle` and clean-exit clear in a Maki 0.7.1 / Herdr core 0.1.18 session; it did not validate delayed UI readiness, lifecycle or reload behavior, in-flight append teardown, model/turn lifecycle, or Desktop GUI rendering. The mock lifecycle suite covers delayed UI readiness, teardown reasons, reload semantics, and suspended append teardown, but remains host-contract coverage rather than real-host acceptance. Isolation mechanisms actually tested are limited to that disposable remote-install session; do not assume a local scratch config/state root, `maki --print`, ACP, or the installed `hc`/`herdr-app` CLIs provides equivalent isolation. Do not automate probes, reloads, or acceptance runs against an active user core or Desktop.

## Uninstall

Remove only this package's declaration from global `init.lua`, then `/reload` or restart. Removing the declaration stops loading but leaves the checkout and lock entry. Once inactive in all Maki processes, use `/packdel maki-herdr-app` and review the removal; Maki removes its approval when its files are gone. Preserve unrelated packages and configuration.

## Architecture and development

`plugin/herdr.lua` starts the Maki adapter in `lua/maki_herdr_app/`. The host-independent reducer and OSC encoder live under `lua/herdr_status/`; the runtime uses the supplied host for output. These are internal boundaries, not a stable public module API. Future Desktop integrations, if implemented, belong in separate, independently installable directories under `integrations/herdr-desktop/<plugin-name>/`; none is currently included or enabled by this package.

From the repository root, run `lua tests/run.lua` and `stylua --check .` with Lua 5.4 and StyLua 2.1.0 as used in CI. These checks are separate from real-host smoke tests and user-assisted GUI acceptance. Maki 0.7.1 has no `maki test` command.

## Catalogs

The [Maki plugin catalog](https://maki.sh/plugins/) discovers public, non-archived GitHub repositories with both `maki` and `plugin` topics; direct package installation does not require a listing. Discovery can be delayed or limited and is not an endorsement. The published repository has both topics and appears in GitHub search; its rendered catalog listing has not been verified.

Herdr Desktop's [mods gallery](https://herdr.dev/gallery/?type=mods), Desktop launcher entries and agent-side OSC bridges are separate things. This package is only the latter; it does not install a mod or launcher. Herdr TUI's plugin system is also separate, so its manifest and install commands do not install this Desktop status bridge.

MIT licensed; see [LICENSE](LICENSE).
