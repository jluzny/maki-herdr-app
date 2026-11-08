# Maki → Herdr Desktop status bridge

A lightweight Maki integration that brings live agent activity into the Herdr Desktop workspace. Herdr can detect Maki from its terminal screen in a local pane. This package implements Herdr’s OSC 7501 status-reporting protocol to add a direct Maki status signal where screen detection is unavailable or unreliable, including a Desktop client connected to a remote core. It also equips Maki agents with tools to inspect Herdr terminals and run allowlisted `hc` operations, with validated inputs and the existing permission checks. Status is best effort; do not use it as critical operational telemetry.

![Herdr Desktop workspace](assets/herdr-desktop-cover.png)

## What it provides

| Capability | Purpose |
| --- | --- |
| Live activity status | Provides a best-effort view of active Maki work. |
| Terminal visibility | Lets agents inspect known Herdr terminals through a constrained read interface. |
| Controlled terminal operations | Lets agents run allowlisted, noninteractive `hc` operations through a validated execution interface. |

The package is an agent-side bridge. It does not modify, launch, or manage Herdr Desktop itself.

## Deployment

Add this entry to global `~/.config/maki/init.lua` after reviewing the source. Pin a reviewed commit or tag with `version` for reproducible installs:

```lua
maki.pack.add({
  { src = "https://github.com/jluzny/maki-herdr-app" },
})
```

## Status model

The bridge maps live Maki-tab activity to one pane status and emits changes only. `needs_input` takes precedence as `blocked`, then active work as `working`; a recorded completed turn becomes `done` only when no live tab has an unknown state; all other cases, including unknown state without a completion, are `idle`. Herdr’s [agent status documentation](https://herdr.dev/tui/docs/agents/#how-status-works) provides background on how Herdr presents and rolls up status. The bridge reports one root OSC record per pane; avoid competing reporters in the same pane.

## Package tools

The package exposes two tools that wrap a bounded subset of the external Herdr core CLI, `hc`, for terminal inspection and allowlisted operations. The wrappers narrow the available command surface, validate input, reject specified interactive and stdin-dependent `hc` forms, and provide bounded summaries. They run through the existing bash permission context; the allowlist is not an approval bypass. Callers must ensure `exec` programs are noninteractive and finite; background `run` can host interactive programs. Use direct bash for unsupported `hc` operations subject to normal permissions. It does not expose or wrap `herdr-app`; use that separate Desktop CLI directly through bash for pane and window arrangement.

| Need | Use |
| --- | --- |
| Bounded terminal inspection | `hc_status` (`ls`, `get`, `wait`) |
| Allowed noninteractive `hc` command | `hc_command` — an execute tool; mutating operations need explicit user authorization |
| Package-tool reference | [Tool reference](docs/tools.md) |

Read [docs/tools.md](docs/tools.md) for input schemas, examples, operation allowlists, command-input constraints, output handling, prompt integration, and safety limits. Read `hc --skill` and `herdr-app --skill` for external CLI syntax rather than treating this package as their full manual.

## Privacy, permissions, and safety

The bridge emits only aggregate state and a fixed app identifier, not prompts, answers, titles, paths, credentials, or conversation content. It requests `env`, `fs_write`, and `run`; these grants are broader than the package's intended uses. Review the source and manifest before approval.

Raw tool output and errors can contain sensitive data. Summaries are not a confidentiality boundary, and restore or transcript search can expose raw content. `run`, `exec`, `send`, and `keys` can start work or deliver input; `hc_command` can also modify or remove resources. Never bypass approvals or use `--force` to avoid a permission decision. Reuse an existing terminal only when explicitly requested: inspect it, confirm authorization, and ask when intent is ambiguous.

## Operational notes

If status is absent, confirm that Maki is running in the intended direct Herdr pane, the package is approved, and the session has access to its controlling TTY. Then inspect Maki logs. A write failure disables reporting until the package is reloaded or Maki is restarted.

To remove the package, delete only its declaration from global `init.lua`, then `/reload` or restart. Once inactive in all Maki processes, use `/packdel maki-herdr-app`; preserve unrelated configuration.

MIT licensed; see [LICENSE](LICENSE).
