# Maki → Herdr Desktop status bridge

A Maki package that reports one aggregate status for live Maki tabs to the current Herdr Desktop pane using OSC 7501, and provides `hc_status` and `hc_command`. It is an agent-side bridge, not a Desktop mod or launcher.

**Verification:** An isolated remote-install smoke test observed startup `idle` and clean-exit clear. Real-host lifecycle, model/turn, and Desktop GUI acceptance remain unverified. See [verification details](docs/verification.md). Do not rely on this bridge for critical status.

## Requirements and limits

| Environment | Status |
| --- | --- |
| Interactive Maki 0.7.1+, Herdr core 0.1.18, direct Linux/WSL Desktop pane | Target; Desktop GUI acceptance pending |
| Headless/ACP, no controlling TTY, native Windows output, nested tmux | Unsupported |

The reporter requires nonempty `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` plus a focused live session before writing to `/dev/tty`. Environment variables alone do not establish correct pane routing. See [verification details](docs/verification.md) for runtime cleanup limits.

## Installation and updates

Add this entry to global `~/.config/maki/init.lua` after reviewing the source. Pin a reviewed commit or tag with `version` for reproducible installs:

```lua
maki.pack.add({
  { src = "https://github.com/jluzny/maki-herdr-app" },
})
```

Start Maki interactively in a direct Herdr pane and approve source and requested permissions only after review. The package auto-loads; use `/reload` or restart after changes. Maki stores the selected commit in global `pack-lock.json`; an existing lock entry takes precedence over a later `version` change. Update with `/packupdate maki-herdr-app` and review the proposed source and permissions.

## Status behavior

The bridge reconciles lifecycle events with live session snapshots and emits only changed aggregate states:

| Status | Condition |
| --- | --- |
| `blocked` | Any live tab is `needs_input`. |
| `working` | Otherwise, any live tab is `working`. |
| `done` | Otherwise, an idle tab has a recorded finished turn and no live tab has an unknown status. |
| `idle` | Otherwise, including when an unknown status prevents `done`. |

A finished turn is recorded only after an observed `TurnStart`; it is cleared by a new turn, reset/removal, or disappearance from the live snapshot. The bridge reports root OSC records with fixed `app=maki`; avoid competing reporters in the same pane.

## Using Herdr tools

When both Herdr environment variables are present, the package adds a prompt hint to read `hc --skill` through bash. Prefer `hc_status` and `hc_command` for their supported operations. Use `hc` for terminal work and `herdr-app` only to arrange the Desktop window. Do not substitute the `herdr` TUI or `HERDR_ENV` for Desktop control.

A successful send does not prove an agent launched or is ready. Inspect status and screen before reporting or retrying after a timeout or error. Use `hc help` for syntax. Do not pipe `hc schema` to `head`; use a full consumer and check for truncation.

Direct tool calls, or a batch of independent calls, produce readable UI summaries. Calls through `code_execution` return raw results: parse and filter them before printing.

### `hc_status`

`hc_status` reads terminal state through nested bash:

- `ls` lists terminals.
- `get` requires an explicit terminal name or `machine/name`.
- `wait` requires a target and accepts 1–120 seconds (default 30).

Targets are ASCII letters, digits, `_`, `.`, and `-` in each part, up to 128 bytes. Nested bash commands follow normal permission checks. The summary is filtered and bounded, but it is not a confidentiality boundary: the model receives raw tool output and errors or restored output can appear raw.

### `hc_command`

`hc_command` runs a bounded subset of `hc` through nested bash with the original permission context. It supports `run --bg`, `ls`, `get`, `read`, `wait`, `label`, `keep`, `keys`, `interrupt`, `put`, `schema`, `send`, `kill`, `rm`, `templates`, `exec`, `update`, selected `file`, `machine`, and `server` subcommands, and help/version/skill forms. It is not full `hc` parity; use bash directly, subject to permissions, for unsupported forms.

Arguments are limited to ASCII letters, digits, spaces, and `_ . , / : @ + = - ' ( )`. U+2018 and U+2019 typographic apostrophes normalize to ASCII `'`; all other non-ASCII input is rejected. Double quotes, other shell metacharacters, backslashes, and newlines are rejected. `send --force` and `update --force` are rejected. Interactive commands, streams, stdin-dependent file writes, `exec --stdin`, and foreground `run` are unsupported.

Tool summaries are filtered and bounded; raw model output is unchanged. `schema` gets a UI-only preview of up to 25 method names. For complete schema output, use `hc schema --json` through direct bash in full output mode and check for truncation.

## Privacy, permissions, and safety

The bridge emits only aggregate state and a fixed app identifier, not prompts, answers, titles, paths, credentials, or conversation content. It requests `env`, `fs_write`, and `run`; these grants are broader than the package's intended uses. Review the source and manifest before approval.

Raw tool output and errors can contain sensitive data. The summaries are not a confidentiality boundary, and restore or transcript search can expose raw content. Never bypass approvals or use `--force` to avoid a permission decision. Reuse an existing terminal only when explicitly requested: inspect it, confirm authorization, and ask when intent is ambiguous.

## Troubleshooting and development

If status is absent, verify the direct pane, controlling TTY, both Herdr environment variables, package approval, and Maki version; then inspect Maki logs. For verification scope, safe acceptance guidance, and development checks, see [docs/verification.md](docs/verification.md).

To remove the package, delete only its declaration from global `init.lua`, then `/reload` or restart. Once inactive in all Maki processes, use `/packdel maki-herdr-app`; preserve unrelated configuration.

`plugin/herdr.lua` starts the adapter in `lua/maki_herdr_app/`. The host-independent reducer and OSC encoder are under `lua/herdr_status/`. Future Desktop integrations belong in separate, independently installable directories under `integrations/herdr-desktop/<plugin-name>/`; none is included or enabled.

## Catalogs

The [Maki plugin catalog](https://maki.sh/plugins/) discovers public, non-archived GitHub repositories with both `maki` and `plugin` topics; direct installation does not require a listing. The [Herdr Desktop mods gallery](https://herdr.dev/gallery/?type=mods), Desktop launchers, and this agent-side OSC bridge are separate things.

MIT licensed; see [LICENSE](LICENSE).
