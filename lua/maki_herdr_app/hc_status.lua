local M = {}

local MAX_TARGET = 128
local MAX_ROWS = 25
local MAX_JSON = 1024 * 1024
local MAX_COMPACT = 16 * 1024
local DEFAULT_TIMEOUT = 30
local MAX_TIMEOUT = 120

local function valid_target(target)
  if type(target) ~= "string" or #target == 0 or #target > MAX_TARGET then
    return false
  end
  return target:match("^[A-Za-z0-9_.-]+$") ~= nil or target:match("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") ~= nil
end

local function command_for(input)
  if type(input) ~= "table" then
    return nil, "input must be an object"
  end
  for key in pairs(input) do
    if key ~= "action" and key ~= "target" and key ~= "timeout" then
      return nil, "unexpected input field"
    end
  end
  if input.action == "ls" then
    if input.target ~= nil or input.timeout ~= nil then
      return nil, "ls does not accept target or timeout"
    end
    return "hc ls --json", 10
  end
  if input.action ~= "get" and input.action ~= "wait" then
    return nil, "action must be ls, get, or wait"
  end
  if not valid_target(input.target) then
    return nil,
      "target must be an explicit terminal name or machine/name (ASCII letters, digits, _, ., -; max 128 bytes)"
  end
  if input.action == "get" then
    if input.timeout ~= nil then
      return nil, "get does not accept timeout"
    end
    return "hc get --json -- " .. input.target, 10
  end
  local timeout = input.timeout
  if timeout == nil then
    timeout = DEFAULT_TIMEOUT
  end
  if type(timeout) ~= "number" or timeout ~= math.floor(timeout) or timeout < 1 or timeout > MAX_TIMEOUT then
    return nil, "timeout must be an integer from 1 to 120 seconds"
  end
  return "hc wait --json --timeout " .. tostring(timeout) .. " -- " .. input.target, timeout + 10
end

local states = { idle = true, working = true, done = true, blocked = true, error = true }
local lifecycle = { live = true, finished = true }
local machine_states = { connecting = true, connected = true, needs_login = true, unreachable = true }
local reasons = {
  status = true,
  exit = true,
  timeout = true,
  message = true,
  output = true,
  not_started = true,
  children = true,
  running = true,
}

local function safe_int32(value)
  if type(value) == "number" and value >= -2147483648 and value <= 2147483647 and value == math.floor(value) then
    return tostring(value)
  end
end

local function terminal_line(value, wait)
  if type(value) ~= "table" then
    return nil
  end
  local address = value.address or value.terminal
  if not valid_target(address) then
    return nil
  end
  local parts = { address }
  if lifecycle[value.state] then
    parts[#parts + 1] = value.state
  end
  local status = value.status
  if type(status) == "table" then
    status = status.state
  end
  if states[status] then
    parts[#parts + 1] = status
  end
  if reasons[value.reason] then
    parts[#parts + 1] = value.reason
  end
  if type(value.ended) == "boolean" then
    parts[#parts + 1] = value.ended and "ended" or "not ended"
  end
  if wait then
    local exit_code, signal = safe_int32(value.exit_code), safe_int32(value.signal)
    if exit_code then
      parts[#parts + 1] = "exit " .. exit_code
    end
    if signal then
      parts[#parts + 1] = "signal " .. signal
    end
    if valid_target(value.from) then
      parts[#parts + 1] = "from " .. value.from
    end
  end
  return table.concat(parts, " · ")
end

local function compact_output(text)
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

local function summary(host, input, output, is_error)
  local buf = host.ui.buf()
  if type(input) ~= "table" or not command_for(input) or type(output) ~= "string" then
    buf:line("hc output unavailable for summary.")
    return buf
  end
  if is_error then
    buf:line("hc failed; details are in the tool output.")
    return buf
  end
  if #output > MAX_JSON then
    buf:line("hc output unavailable for summary.")
    return buf
  end
  local value, err = host.json.decode(output)
  if err or type(value) ~= "table" then
    buf:line("hc output is not structured JSON.")
    return buf
  end
  if input.action == "ls" then
    if type(value.terminals) ~= "table" then
      buf:line("hc output has no terminal list.")
      return buf
    end
    local count, omitted, invalid = 0, 0, 0
    for _, terminal in ipairs(value.terminals) do
      local line = terminal_line(terminal)
      if not line then
        invalid = invalid + 1
      elseif count < MAX_ROWS then
        buf:line(line)
        count = count + 1
      else
        omitted = omitted + 1
      end
    end
    if count == 0 and invalid == 0 then
      buf:line("No terminals to display.")
    end
    if omitted > 0 then
      buf:line(tostring(omitted) .. (omitted == 1 and " valid terminal omitted." or " valid terminals omitted."))
    end
    if invalid > 0 then
      buf:line(tostring(invalid) .. (invalid == 1 and " invalid terminal omitted." or " invalid terminals omitted."))
    end
    if type(value.machines) == "table" then
      local shown, omitted, bad = 0, 0, 0
      for _, machine in ipairs(value.machines) do
        local name = type(machine) == "table" and machine.name or nil
        if not valid_target(name) or name:find("/", 1, true) then
          bad = bad + 1
        elseif shown < MAX_ROWS then
          local state = machine_states[machine.state] and machine.state or "unknown"
          buf:line("Machine " .. name .. " · " .. state)
          shown = shown + 1
        else
          omitted = omitted + 1
        end
      end
      if omitted > 0 then
        buf:line(tostring(omitted) .. (omitted == 1 and " valid machine omitted." or " valid machines omitted."))
      end
      if bad > 0 then
        buf:line(tostring(bad) .. (bad == 1 and " invalid machine omitted." or " invalid machines omitted."))
      end
    end
  else
    local wait = input.action == "wait"
    local line = terminal_line(value, wait)
    buf:line(line or "No terminal status to display.")
    if wait and type(value.children) == "table" then
      local shown, omitted, invalid = 0, 0, 0
      for _, child in ipairs(value.children) do
        local child_line = terminal_line(child, true)
        if not child_line then
          invalid = invalid + 1
        elseif shown < MAX_ROWS then
          buf:line("Child: " .. child_line)
          shown = shown + 1
        else
          omitted = omitted + 1
        end
      end
      if omitted > 0 then
        buf:line(tostring(omitted) .. (omitted == 1 and " valid child omitted." or " valid children omitted."))
      end
      if invalid > 0 then
        buf:line(tostring(invalid) .. (invalid == 1 and " invalid child omitted." or " invalid children omitted."))
      end
    end
  end
  return buf
end

local function safe_summary(host, input, output, is_error)
  local fallback = host.ui.buf()
  fallback:line("hc summary unavailable; details are in the tool output.")
  local ok, body = pcall(summary, host, input, output, is_error)
  if ok then
    return body
  end
  return fallback
end

function M.start(host)
  if type(host.api.register_tool) ~= "function" then
    return
  end
  host.api.register_tool({
    name = "hc_status",
    permission = "run",
    kind = "read",
    timeout = 140,
    description = "Inspect Herdr terminals with hc: list live terminals, get one terminal's state, or wait for one explicit terminal. Calls bash with normal permission checks. Raw output and errors may contain sensitive data. Maki may show raw output temporarily on session resume, show raw errors, and include raw output in transcript search. Compact output is limited and may be truncated; bash may also apply its own limits or rewriting. The UI summary filters terminal fields. For other hc operations consult hc --skill.",
    schema = {
      type = "object",
      properties = {
        action = { type = "string", enum = { "ls", "get", "wait" }, description = "Operation to perform." },
        target = { type = "string", description = "Explicit terminal name or machine/name for get and wait." },
        timeout = { type = "integer", minimum = 1, maximum = 120, description = "Wait timeout in seconds; default 30." },
      },
      required = { "action" },
      additionalProperties = false,
    },
    -- Maki 0.7.1 passes (input, output, is_error, ctx); ctx is userdata.
    -- The host can render raw history before this asynchronous callback finishes.
    restore = function(input, output, is_error, ctx)
      if type(is_error) ~= "boolean" or ctx == nil then
        return safe_summary(host, nil, nil, false)
      end
      return safe_summary(host, input, output, is_error)
    end,
    handler = function(input, ctx)
      local command, timeout_or_error = command_for(input)
      if not command then
        local err = "error: " .. timeout_or_error
        return { llm_output = err, is_error = true, body = safe_summary(host, input, err, true) }
      end
      local full = ctx:output_mode() == "full"
      local output, detail = host.agent.call_tool(ctx, "bash", {
        command = command,
        timeout = timeout_or_error,
        description = "Inspect Herdr terminal status",
      }, { timeout = timeout_or_error, output_mode = full and "full" or "compact" })
      if output == nil then
        local err = type(detail) == "string" and detail or "error: bash returned no output"
        return {
          llm_output = full and err or compact_output(err),
          is_error = true,
          body = safe_summary(host, input, err, true),
        }
      end
      if type(output) ~= "string" then
        local err = "error: bash returned invalid output"
        return { llm_output = err, is_error = true, body = safe_summary(host, input, err, true) }
      end
      return { llm_output = full and output or compact_output(output), body = safe_summary(host, input, output, false) }
    end,
  })
end

return M
