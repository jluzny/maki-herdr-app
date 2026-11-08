# Package tool reference

This package exposes two Maki tools, both wrapping a bounded subset of the external Herdr core CLI (`hc`). It does not expose a `herdr-app` tool or encapsulate any `herdr-app` operations.

| Need | Use | Boundary |
| --- | --- | --- |
| Inspect bounded terminal status | `hc_status` | Read-oriented `ls`, `get`, or `wait` |
| Run an allowed noninteractive `hc` operation | `hc_command` | Validated `argv` envelope |
| Use an unsupported `hc` operation | Direct `bash` | Subject to normal permissions |
| Arrange Herdr Desktop panes or windows | Direct `bash` with `herdr-app` | External CLI; not wrapped by this package |

Read `hc --skill` for complete `hc` syntax. For Desktop work, use `herdr-app` directly through bash: locate it on `PATH` (or `herdr-app.exe` in WSL if needed) and read its `--skill` output. The package provides no allowlist, validation, summary, or permission rule for `herdr-app`. Do not treat the `herdr` TUI or `HERDR_ENV` as Desktop control.

## `hc_status`

**Purpose:** inspect terminal state with a small, read-oriented interface. It is a Maki `read` tool with `run` permission and invokes nested `bash`; normal bash permission checks still apply. It does not run programs in a target terminal or send terminal input, but the underlying `hc` calls can have operational side effects such as starting the core or marking child news as seen.

### Input

The input is an object with no additional properties:

| Field | Required | Rules |
| --- | --- | --- |
| `action` | Yes | `ls`, `get`, or `wait` |
| `target` | `get`/`wait` | Explicit terminal name or `machine/name`; each part permits ASCII letters, digits, `_`, `.`, `-`; whole value is at most 128 bytes |
| `timeout` | No, `wait` only | Integer seconds from 1 to 120; defaults to 30 |

`ls` accepts neither `target` nor `timeout`; `get` accepts no `timeout`. The tool runs `hc ls --json`, `hc get --json -- TARGET`, or `hc wait --json --timeout SECONDS -- TARGET`.

```json
{"action":"ls"}
```

```json
{"action":"get","target":"build-agent"}
```

```json
{"action":"wait","target":"remote/build-agent","timeout":60}
```

### Output and limits

The tool returns the underlying command output to the model, compacted outside full-output mode. Its UI summary parses JSON and shows safe terminal, machine, and child-state fields, with lists bounded to 25 rows. `get` may warn when its first message was not sent. Errors and malformed or oversized JSON fall back to a generic summary.

A summary is not a confidentiality boundary. Raw output and errors can contain sensitive data and may appear during history restoration or transcript search. A successful status result also does not prove an agent launched or is ready; inspect terminal status and screen before retrying after a timeout or error.

## `hc_command`

**Purpose:** run a validated subset of `hc`. It is a Maki `execute` tool with `run` permission and calls nested `bash` under the original permission context. It is not full `hc` parity. It rejects specified interactive and stdin-dependent `hc` forms, but cannot establish that a program run through `exec` or background `run` is noninteractive or finite.

### Input and normalization

Supply exactly one object field, `argv`: a dense, nonempty array of one to 128 strings. Do not include the `hc` executable.

```json
{"argv":["ls","--json"]}
```

```json
{"argv":["run","--bg","--name","worker","my-program","--fast"]}
```

Each argument is at most 16,384 bytes, and the normalized arguments together are at most 65,536 bytes; NUL is rejected. Supported characters are ASCII letters, digits, spaces, and `_ . , / : @ + = - ' ( )`. U+2018 and U+2019 apostrophes are normalized to ASCII `'` before the total is measured; other non-ASCII characters are rejected. Double quotes, backslashes, newlines, and other shell metacharacters are rejected.

The allowlist validates command shape, accepted option names, option-value presence, and positional count before quoting every argument for `hc`. It generally leaves option-value semantics to `hc`. Use `hc --skill` or `hc help` to determine the upstream syntax for an allowed family.

### Allowed operations

| Family | Allowed forms / constraints |
| --- | --- |
| Help and metadata | `help`, `--help`, `-h`, command/subcommand help, `--version`, `-V`, `--skill`, `--licenses` |
| Terminal operations | `ls`, `get`, `read`, `wait`, `label`, `keep`, `keys`, `interrupt`, `put`, `send`, `kill`, `rm` |
| Launch and execution | `run --bg` only; non-stdin `exec` |
| Discovery | `schema`, `templates` |
| Files | `file read`, `file edit` |
| Machines | `machine ls`, `machine add`, `machine update`, `machine rename`, `machine rm` |
| Server | `server start`, `server stop`, `server status`, `server restart` |
| Update | `update` without `--force` |

Only command-specific options before the program in `run` or `exec` are checked against the package allowlist. After that program position, arguments are passed through as program arguments. `machine add` requires `--install` and either an explicit target or `--via`; `--via` additionally requires `--name`. `send --force` and `update --force` are rejected.

### Rejected and unsupported operations

`attach`, `connect`, and `machine login` are interactive and rejected. `events` and foreground `run` stream output and are unsupported. `file write` needs stdin and is unsupported, as are stdin-dependent file operations and `exec --stdin` / `exec -i`. Any unlisted `hc` command or option before the program position in `run` or `exec` is rejected. For these operations, use direct bash only when the normal permission flow authorizes it.

### Output and safety

The tool has a 130-second command timeout. It is an **execute** tool, not read-only: `kill`, `rm`, `file edit`, machine mutations, server stop/restart, and `update` can change or remove resources. Run these forms only with explicit user authorization. In normal output mode it compacts model output; its UI summaries are bounded and tailored to recognized JSON responses. For example, terminal and machine lists show at most 25 entries, and `schema` shows at most 25 method names rather than a full schema.

For a complete schema, use `hc schema --json` through direct bash in full-output mode and check for truncation. `hc_command` summaries and raw output are not a confidentiality boundary; errors, restoration, and transcript search can expose raw content. Prefer direct tool calls, or batch independent calls, for readable summaries. When using `code_execution`, parse and filter raw results before printing.

## Herdr prompt integration

The package registers the following integration only when **both** `HC_TERMINAL_ID` and `HC_TERMINAL_SOCKET` exist and are nonempty:

- A `tool_usage` prompt hint directs agents to read `hc --skill` through bash, prefer these package tools for supported `hc` work, and read the available CLI's `--skill` before Desktop operations.
- A bash permission rule allows only the `hc --skill` scope.

The rule does not authorize other bash commands, unsupported `hc` operations, any `herdr-app` operation, or any permission bypass. It does not confirm that a CLI is installed or that a Desktop operation is possible. Report an actual task that cannot be completed rather than reporting a missing CLI by itself.

## Status bridge

The package's runtime bridge is separate from its tools: it publishes aggregate Maki-tab status to the current Herdr Desktop pane. See the concise behavior description in the [README](../README.md#status-model). Do not use it as critical-status infrastructure.
