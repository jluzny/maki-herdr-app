local M = {}

local MAX_ARGS = 128
local MAX_ARG = 16384
local MAX_TOTAL = 65536
local MAX_COMPACT = 16384
local MAX_JSON = 1024 * 1024
local MAX_ROWS = 25
local TIMEOUT = 130

local specs = {
  run = {
    flags = {
      ["--json"] = true,
      ["--no-parent"] = true,
      ["--no-notify"] = true,
      ["--outlive-parent"] = true,
      ["--rm"] = true,
      ["--keep"] = true,
      ["--bg"] = true,
    },
    values = {
      ["--name"] = true,
      ["--cwd"] = true,
      ["--on"] = true,
      ["--label"] = true,
      ["--parent"] = true,
      ["--timeout"] = true,
    },
    min = 1,
    max = MAX_ARGS,
    trailing = true,
  },
  ls = {
    flags = { ["--json"] = true, ["--all"] = true },
    values = { ["--label"] = true },
    min = 0,
    max = 0,
  },
  get = { flags = { ["--json"] = true }, min = 1, max = 1 },
  read = { flags = { ["--json"] = true }, values = { ["--lines"] = true }, min = 1, max = 1 },
  wait = {
    flags = { ["--json"] = true },
    values = { ["--children"] = true, ["--output"] = true, ["--timeout"] = true },
    min = 1,
    max = 1,
  },
  label = { flags = { ["--json"] = true }, min = 2, max = MAX_ARGS },
  keep = { flags = { ["--json"] = true, ["--off"] = true }, min = 1, max = 1 },
  keys = { flags = { ["--json"] = true }, min = 2, max = MAX_ARGS },
  interrupt = { flags = { ["--json"] = true }, values = { ["--timeout"] = true }, min = 1, max = 1 },
  put = { flags = { ["--json"] = true }, min = 2, max = 2 },
  schema = { flags = { ["--json"] = true }, min = 0, max = 0 },
  send = {
    flags = { ["--json"] = true, ["--wait"] = true },
    values = { ["--if"] = true, ["--timeout"] = true },
    min = 2,
    max = 2,
  },
  kill = { flags = { ["--json"] = true }, min = 1, max = 1 },
  rm = { flags = { ["--json"] = true }, min = 1, max = 1 },
  templates = { flags = { ["--json"] = true }, min = 0, max = 0 },
  exec = {
    flags = { ["--json"] = true },
    values = { ["--on"] = true, ["--cwd"] = true, ["--env"] = true, ["--timeout"] = true },
    min = 1,
    max = MAX_ARGS,
    trailing = true,
  },
  update = {
    flags = { ["--json"] = true },
    values = { ["--from"] = true, ["--version"] = true },
    min = 0,
    max = 0,
  },
  ["file read"] = {
    flags = { ["--json"] = true },
    values = { ["--on"] = true, ["--cwd"] = true, ["--offset"] = true, ["--limit"] = true },
    min = 1,
    max = 1,
  },
  ["file edit"] = {
    flags = { ["--json"] = true },
    values = { ["--on"] = true, ["--cwd"] = true, ["--old"] = true, ["--new"] = true },
    min = 1,
    max = 1,
  },
  ["machine ls"] = { flags = { ["--json"] = true }, min = 0, max = 0 },
  ["machine add"] = {
    flags = { ["--json"] = true, ["--temp"] = true, ["--install"] = true },
    values = { ["--via"] = true, ["--name"] = true, ["--session"] = true },
    min = 0,
    max = 1,
  },
  ["machine update"] = { flags = { ["--json"] = true }, min = 1, max = 1 },
  ["machine rename"] = { flags = { ["--json"] = true }, min = 2, max = 2 },
  ["machine rm"] = { flags = { ["--json"] = true }, min = 1, max = 1 },
  ["server start"] = { flags = { ["--json"] = true }, min = 0, max = 0 },
  ["server stop"] = { flags = { ["--json"] = true }, min = 0, max = 0 },
  ["server status"] = { flags = { ["--json"] = true }, min = 0, max = 0 },
  ["server restart"] = { flags = { ["--json"] = true }, min = 0, max = 0 },
}

local function quote(s)
  return '"' .. s .. '"'
end

local function validate(input)
  if type(input) ~= "table" then
    return nil, "input must be an object"
  end
  for k in pairs(input) do
    if k ~= "argv" then
      return nil, "unexpected input field"
    end
  end
  local argv = input.argv
  if type(argv) ~= "table" then
    return nil, "argv must be a nonempty array of strings"
  end
  local count, total = 0, 0
  for k, v in pairs(argv) do
    if type(k) ~= "number" or k ~= math.floor(k) or k < 1 or k > MAX_ARGS then
      return nil, "argv must be a dense array of at most 128 strings"
    end
    if type(v) ~= "string" or #v > MAX_ARG or v:find("\0", 1, true) then
      return nil, "each argument must be a string of at most 16384 bytes without NUL"
    end
    if v:find("[^a-zA-Z0-9 _%.,/:%@%+%=%-]") then
      return nil,
        "unsupported argument character; only ASCII letters, digits, spaces and _ . , / : @ + = - are supported"
    end
    count = count + 1
    total = total + #v
  end
  if count == 0 or count ~= #argv or total > MAX_TOTAL then
    return nil, "argv must be nonempty and dense, with at most 65536 total bytes"
  end
  for i = 1, count do
    if argv[i] == nil then
      return nil, "argv must be a dense array"
    end
  end
  local command, start = argv[1], 2
  local help_only = (count == 2 and (argv[2] == "--help" or argv[2] == "-h"))
    or (
      count == 3
      and (command == "file" or command == "machine" or command == "server")
      and argv[2]:match("^[a-z]+$")
      and (argv[3] == "--help" or argv[3] == "-h")
    )
  if help_only and command:match("^[a-z]+$") then
    command = "help"
  elseif
    command == "help"
    or command == "--help"
    or command == "-h"
    or command == "--version"
    or command == "-V"
    or command == "--skill"
    or command == "--licenses"
  then
    if count > 3 or (command ~= "help" and count ~= 1) then
      return nil, "help accepts at most a command and subcommand"
    end
    for i = 2, count do
      if not argv[i]:match("^[a-z]+$") then
        return nil, "invalid help topic"
      end
    end
  else
    if command == "file" or command == "machine" or command == "server" then
      if count < 2 then
        return nil, command .. " requires a supported subcommand; use help for syntax"
      end
      command, start = command .. " " .. argv[2], 3
    end
    if command == "attach" or command == "connect" or command == "machine login" then
      return nil, command .. " is interactive and is not supported"
    end
    if command == "events" then
      return nil, "events streams indefinitely and is not supported"
    end
    if command == "file write" then
      return nil, "file write requires stdin and is not supported"
    end
    local spec = specs[command]
    if not spec then
      return nil, "unsupported hc command; use help to inspect available commands"
    end
    local positions, seen, options = 0, {}, true
    local i = start
    while i <= count do
      local arg = argv[i]
      if options and arg == "--" then
        options = false
      elseif options and arg:sub(1, 1) == "-" then
        local key, value = arg:match("^(%-%-[^=]+)=(.*)$")
        key = key or arg
        if key == "--force" and (command == "send" or command == "update") then
          return nil, "--force is not supported for " .. command
        elseif command == "exec" and (key == "--stdin" or key == "-i") then
          return nil, "exec stdin is not supported"
        elseif spec.flags[key] and value == nil then
          seen[key] = true
        elseif spec.values and spec.values[key] then
          if value == nil then
            i = i + 1
            if i > count then
              return nil, "missing value for " .. key
            end
            value = argv[i]
          end
          if value == "" and key ~= "--new" and key ~= "--old" then
            return nil, "empty value for " .. key
          end
          seen[key] = value
        else
          return nil, "unsupported option " .. key .. " for " .. command
        end
      else
        positions = positions + 1
        if arg == "" and (positions == 1 or command ~= "send") then
          return nil, "empty positional argument for " .. command
        end
        if spec.trailing then
          options = false
        end
      end
      i = i + 1
    end
    if positions < spec.min or positions > spec.max then
      return nil, "invalid number of arguments for " .. command .. "; use hc help for syntax"
    end
    if command == "run" and not seen["--bg"] then
      return nil, "run requires --bg before the program; foreground run streams output"
    end
    if command == "machine add" and (not seen["--install"] or (positions == 0 and not seen["--via"])) then
      return nil, "machine add requires --install and an explicit target or --via to avoid prompts"
    end
    if command == "machine add" and seen["--via"] and not seen["--name"] then
      return nil, "machine add --via requires --name"
    end
  end
  local parts = { "hc" }
  for i = 1, count do
    parts[#parts + 1] = quote(argv[i])
  end
  return table.concat(parts, " "), command
end

local function compact(text)
  if #text <= MAX_COMPACT then
    return text
  end
  local marker = "\n[output truncated; incomplete text, not JSON]\n"
  local keep = MAX_COMPACT - #marker
  local head = math.floor(keep / 2)
  while head > 0 and text:byte(head + 1) >= 128 and text:byte(head + 1) < 192 do
    head = head - 1
  end
  local tail = #text - (keep - math.floor(keep / 2)) + 1
  while tail <= #text and text:byte(tail) >= 128 and text:byte(tail) < 192 do
    tail = tail + 1
  end
  return text:sub(1, head) .. marker .. text:sub(tail)
end

local function safe_field(value)
  if type(value) ~= "string" or #value == 0 or #value > 128 or not value:match("^[%w_.:/%-]+$") then
    return nil
  end
  return value
end

local function safe_integer(value, min, max)
  if type(value) == "number" and value >= min and value <= max and value == math.floor(value) then
    return tostring(value)
  end
end

local function terminal_line(value)
  if type(value) ~= "table" then
    return nil
  end
  local address = safe_field(value.address)
  if not address then
    return nil
  end
  local state = safe_field(value.state)
  local status = type(value.status) == "table" and safe_field(value.status.state) or safe_field(value.status)
  local exit_code = safe_integer(value.exit_code, -2147483648, 2147483647)
  return "Terminal "
    .. address
    .. (state and " · " .. state or "")
    .. (status and " · status " .. status or "")
    .. (exit_code and " · exit " .. exit_code or "")
end

local function wait_lines(buf, value, prefix)
  if type(value) ~= "table" then
    return
  end
  local parts = {}
  local terminal = safe_field(value.terminal)
  local reason = safe_field(value.reason)
  local status = safe_field(value.status)
  local exit_code = safe_integer(value.exit_code, -2147483648, 2147483647)
  if terminal then
    parts[#parts + 1] = terminal
  end
  if reason then
    parts[#parts + 1] = "reason " .. reason
  end
  if status then
    parts[#parts + 1] = "status " .. status
  end
  if type(value.ended) == "boolean" then
    parts[#parts + 1] = "ended " .. tostring(value.ended)
  end
  if exit_code then
    parts[#parts + 1] = "exit " .. exit_code
  end
  if #parts > 0 then
    buf:line(prefix .. table.concat(parts, " · "))
  end
end

local function raw_body(host, output)
  local buf = host.ui.buf()
  local text = compact(output):gsub("[%z\1-\9\11-\31\127]", "?")
  for line in (text .. "\n"):gmatch("(.-)\n") do
    buf:line(line)
  end
  return buf
end

local function summary(host, command, output, is_error)
  if is_error or #output > MAX_JSON then
    return raw_body(host, output)
  end
  local value, err = host.json.decode(output)
  if err or type(value) ~= "table" or value.error ~= nil then
    return raw_body(host, output)
  end
  local buf = host.ui.buf()
  if command == "templates" or command == "machine ls" then
    local list = command == "templates" and value.templates or value.machines
    if type(list) ~= "table" then
      return raw_body(host, output)
    end
    local shown, omitted = 0, 0
    for _, item in ipairs(list) do
      local name = type(item) == "table" and safe_field(item.name) or nil
      if name and shown < MAX_ROWS then
        local state = safe_field(item.state)
        local invalid = command == "templates" and type(item.error) == "string" and #item.error > 0
        buf:line(name .. (state and " · " .. state or "") .. (invalid and " · error (see raw output)" or ""))
        shown = shown + 1
      else
        omitted = omitted + 1
      end
    end
    if shown == 0 and omitted == 0 then
      buf:line(command == "templates" and "No templates." or "No machines.")
    end
    if omitted > 0 then
      buf:line(tostring(omitted) .. " entries omitted.")
    end
    return buf
  end
  if command == "ls" and type(value.terminals) == "table" then
    local shown, omitted = 0, 0
    for _, item in ipairs(value.terminals) do
      local line = terminal_line(item)
      if line and shown < MAX_ROWS then
        buf:line(line)
        shown = shown + 1
      else
        omitted = omitted + 1
      end
    end
    if shown == 0 and omitted == 0 then
      buf:line("No terminals.")
    end
    if omitted > 0 then
      buf:line(tostring(omitted) .. " entries omitted.")
    end
    local hidden = safe_integer(value.hidden_finished, 0, 9007199254740991)
    if hidden and hidden ~= "0" then
      buf:line(hidden .. " finished terminals hidden.")
    end
    if type(value.machines) == "table" and #value.machines > 0 then
      local count = #value.machines
      buf:line(tostring(count) .. (count == 1 and " machine" or " machines") .. " (see raw output).")
    end
    return buf
  end
  local terminal = terminal_line(value)
  if (command == "run" or command == "get" or command == "kill") and terminal then
    buf:line(terminal)
    if command == "run" and type(value.first_message) == "table" and type(value.first_message.sent) == "boolean" then
      local first = value.first_message
      buf:line(
        first.sent and "First message sent." or "First message was not sent; inspect the terminal before retrying."
      )
      local reason = safe_field(first.reason)
      local turn = safe_integer(first.turn, 0, 9007199254740991)
      if reason then
        buf:line("First message reason: " .. reason)
      end
      if turn then
        buf:line("First message turn: " .. turn)
      end
      if type(first.started) == "boolean" then
        buf:line(first.started and "First message started." or "First message not observed starting.")
      end
    end
    return buf
  end
  local turn = safe_integer(value.turn, 0, 9007199254740991)
  if command == "send" and turn then
    local status = safe_field(value.status)
    buf:line("Send accepted · turn " .. turn .. (status and " · status " .. status or ""))
    if type(value.started) == "boolean" then
      buf:line(value.started and "Turn started." or "Turn not observed starting.")
    end
    wait_lines(buf, value.wait, "Wait: ")
    return buf
  end
  if
    command == "wait"
    and safe_field(value.terminal)
    and safe_field(value.reason)
    and type(value.ended) == "boolean"
  then
    wait_lines(buf, value, "Wait: ")
    if type(value.children) == "table" then
      local count = #value.children
      for i = 1, math.min(count, MAX_ROWS) do
        wait_lines(buf, value.children[i], "Child: ")
      end
      if count > MAX_ROWS then
        buf:line(tostring(count - MAX_ROWS) .. " children omitted.")
      end
    end
    return buf
  end
  local removed = safe_field(value.removed)
  if command == "rm" and removed then
    buf:line("Removed " .. removed)
    return buf
  end
  if command:sub(1, 8) == "machine " then
    local name = safe_field(value.name)
    if name then
      buf:line("Machine " .. name .. (safe_field(value.state) and " · " .. value.state or ""))
      return buf
    end
  end
  return raw_body(host, output)
end

local function safe_summary(host, command, output, is_error)
  local ok, body = pcall(summary, host, command or "", output, is_error)
  if ok then
    return body
  end
  return raw_body(host, output)
end

function M.start(host)
  if type(host.api.register_tool) ~= "function" then
    return
  end
  host.api.register_tool({
    name = "hc_command",
    permission = "run",
    kind = "execute",
    timeout = TIMEOUT + 10,
    description = "Run bounded hc commands with structured argv (without the hc executable): ls, get, read, wait, label, keep, keys, interrupt, put, schema, --skill, run --bg, send, kill, rm, templates, help, file read/edit, non-stdin exec, machine ls/add/update/rename/rm, server start/stop/status/restart, update. Explicit terminal targets are required. Attach, connect, streaming events, file write, machine login, exec stdin and foreground run are excluded; --force is rejected. Machine add requires --install and an explicit target or --via. Never use keys or other commands to bypass a permission decision. Exec must be noninteractive and finite; commands can block until the 130-second tool timeout, including waits with longer hc timeouts. All operations use bash with its normal permissions, choices and Yolo behavior; no new autoallow or guaranteed fresh prompt. Raw arguments, output and errors can contain sensitive data; UI summaries are not a privacy boundary. Raw output may appear during restore, in errors and transcript search. Compact output and bash itself may truncate or rewrite output.",
    schema = {
      type = "object",
      properties = {
        argv = {
          type = "array",
          items = { type = "string", maxLength = MAX_ARG },
          minItems = 1,
          maxItems = MAX_ARGS,
          description = "hc arguments as separate strings, starting with a supported command. Only ASCII letters, digits, spaces and _ . , / : @ + = - are supported; quotes, shell metacharacters, backslashes, newlines and non-ASCII text are unsupported.",
        },
      },
      required = { "argv" },
      additionalProperties = false,
    },
    restore = function(input, output, is_error, ctx)
      if type(is_error) ~= "boolean" or ctx == nil or type(output) ~= "string" then
        return raw_body(host, "hc output unavailable.")
      end
      local _, command = validate(input)
      return safe_summary(host, command, output, is_error)
    end,
    handler = function(input, ctx)
      local command, action = validate(input)
      if not command then
        local err = "error: " .. action
        return { llm_output = err, is_error = true, body = raw_body(host, err) }
      end
      local full = ctx:output_mode() == "full"
      local output, detail = host.agent.call_tool(ctx, "bash", {
        command = command,
        timeout = TIMEOUT,
        description = "Run hc " .. action,
      }, { timeout = TIMEOUT, output_mode = full and "full" or "compact" })
      if output == nil then
        local err = type(detail) == "string" and detail or "error: bash returned no output"
        return {
          llm_output = full and err or compact(err),
          is_error = true,
          body = safe_summary(host, action, err, true),
        }
      end
      if type(output) ~= "string" then
        local err = "error: bash returned invalid output"
        return { llm_output = err, is_error = true, body = raw_body(host, err) }
      end
      return { llm_output = full and output or compact(output), body = safe_summary(host, action, output, false) }
    end,
  })
end

return M
