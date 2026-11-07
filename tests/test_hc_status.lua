local hc_status = require("maki_herdr_app.hc_status")
local ctx = {
  output_mode = function()
    return "compact"
  end,
}
local full_ctx = {
  output_mode = function()
    return "full"
  end,
}

-- Fixture-based stand-in for Maki's json.decode; it also records decode attempts.
local function setup()
  local mock = { calls = {}, fixtures = {}, decodes = {}, output = "{}" }
  local host = {
    api = {
      register_tool = function(spec)
        mock.spec = spec
      end,
    },
    ui = {
      buf = function()
        local buf = { lines = {} }
        function buf:line(text)
          self.lines[#self.lines + 1] = text
        end
        return buf
      end,
    },
    json = {
      decode = function(raw)
        mock.decodes[#mock.decodes + 1] = raw
        if mock.decode_throws then
          error("decoder failure: secret-decoder")
        end
        local fixture = mock.fixtures[raw]
        if fixture then
          return fixture.value, fixture.err
        end
        return nil, "invalid JSON"
      end,
    },
    agent = {
      call_tool = function(ctx, name, args, opts)
        mock.calls[#mock.calls + 1] = { ctx = ctx, name = name, args = args, opts = opts }
        return mock.output, mock.detail
      end,
    },
  }
  mock.host = host
  hc_status.start(host)
  return mock, mock.spec
end

local function lines(body)
  truthy(body, "expected summary buffer")
  return table.concat(body.lines, "\n")
end

local function fixture(mock, raw, value, err)
  mock.fixtures[raw] = { value = value, err = err }
end

local function reject(spec, mock, input, expected)
  local before = #mock.calls
  local result = spec.handler(input, ctx)
  eq(result.is_error, true)
  eq(result.llm_output, "error: " .. expected)
  eq(#mock.calls, before, "invalid input must not invoke bash")
end

local target_error =
  "target must be an explicit terminal name or machine/name (ASCII letters, digits, _, ., -; max 128 bytes)"

test("hc status registers a read tool with a closed bounded schema", function()
  local _, spec = setup()
  eq(spec.name, "hc_status")
  eq(spec.permission, "run")
  eq(spec.kind, "read")
  eq(spec.timeout, 140)
  truthy(spec.description:find("sensitive data", 1, true))
  truthy(spec.description:find("raw output temporarily on session resume", 1, true))
  truthy(spec.description:find("raw errors", 1, true))
  truthy(spec.description:find("raw output in transcript search", 1, true))
  local schema = spec.schema
  eq(schema.type, "object")
  eq(schema.additionalProperties, false)
  eq(#schema.required, 1)
  eq(schema.required[1], "action")
  eq(schema.properties.action.type, "string")
  eq(table.concat(schema.properties.action.enum, ","), "ls,get,wait")
  eq(schema.properties.target.type, "string")
  eq(schema.properties.timeout.type, "integer")
  eq(schema.properties.timeout.minimum, 1)
  eq(schema.properties.timeout.maximum, 120)
  local count = 0
  for _ in pairs(schema.properties) do
    count = count + 1
  end
  eq(count, 3)
  hc_status.start({ api = {} })
end)

test("hc status forwards exact nested bash commands and original permission context", function()
  local mock, spec = setup()
  local ctx = {
    permission = { token = "original" },
    output_mode = function()
      return "full"
    end,
  }
  local cases = {
    { { action = "ls" }, "hc ls --json", 10 },
    { { action = "get", target = "machine/name_1.2" }, "hc get --json -- machine/name_1.2", 10 },
    { { action = "get", target = "--help" }, "hc get --json -- --help", 10 },
    { { action = "wait", target = "-x" }, "hc wait --json --timeout 30 -- -x", 40 },
    { { action = "wait", target = "a", timeout = 1 }, "hc wait --json --timeout 1 -- a", 11 },
    { { action = "wait", target = "a", timeout = 120 }, "hc wait --json --timeout 120 -- a", 130 },
  }
  for i, case in ipairs(cases) do
    local result = spec.handler(case[1], ctx)
    eq(result.llm_output, "{}")
    local call = mock.calls[i]
    eq(call.ctx, ctx)
    eq(call.name, "bash")
    eq(call.args.command, case[2])
    eq(call.args.timeout, case[3])
    eq(call.args.description, "Inspect Herdr terminal status")
    eq(call.opts.timeout, case[3])
    eq(call.opts.output_mode, "full")
    local n = 0
    for _ in pairs(call.opts) do
      n = n + 1
    end
    eq(n, 2, "no permission bypass options")
  end
end)

test("hc status rejects invalid schema fields and action combinations before execution", function()
  local mock, spec = setup()
  for _, input in ipairs({ false, 0, "ls" }) do
    reject(spec, mock, input, "input must be an object")
  end
  reject(spec, mock, nil, "input must be an object")
  for _, input in ipairs({ {}, { action = "exec" }, { action = "LS" }, { action = 1 }, { action = false } }) do
    reject(spec, mock, input, "action must be ls, get, or wait")
  end
  for _, input in ipairs({
    { action = "ls", target = "a" },
    { action = "ls", timeout = 1 },
    { action = "ls", extra = true },
    { action = "ls", [1] = "x" },
  }) do
    local msg = (input.extra or input[1]) and "unexpected input field" or "ls does not accept target or timeout"
    reject(spec, mock, input, msg)
  end
  reject(spec, mock, { action = "get", target = "a", timeout = 1 }, "get does not accept timeout")
  reject(spec, mock, { action = "wait", target = "a", command = "evil" }, "unexpected input field")
end)

test("hc status target validation rejects shell metacharacters, controls, traversal separators and oversize", function()
  local mock, spec = setup()
  local bad = {
    "",
    "a b",
    "a\tb",
    "a\nb",
    "a\rb",
    "a\0b",
    "a\27[31m",
    "a;id",
    "a&&id",
    "a|id",
    "a>file",
    "a<file",
    "$(id)",
    "`id`",
    "a'b",
    'a"b',
    "a\\b",
    "a*b",
    "a?b",
    "a[b]",
    "a{b}",
    "a#b",
    "a~b",
    "$HOME",
    "/a",
    "a/",
    "a/b/c",
    "a//b",
    "é",
    string.rep("a", 129),
  }
  for _, target in ipairs(bad) do
    for _, action in ipairs({ "get", "wait" }) do
      reject(spec, mock, { action = action, target = target }, target_error)
    end
  end
  for _, target in ipairs({ false, 1, {}, true }) do
    reject(spec, mock, { action = "get", target = target }, target_error)
  end
  reject(spec, mock, { action = "get" }, target_error)
  spec.handler({ action = "get", target = string.rep("a", 128) }, ctx)
  eq(mock.calls[1].args.command, "hc get --json -- " .. string.rep("a", 128))
end)

test("hc wait enforces integer timeout limits and rejects non-finite values", function()
  local mock, spec = setup()
  for _, timeout in ipairs({ 0, -1, 121, 1.5, "30", false, {}, math.huge, -math.huge, 0 / 0 }) do
    reject(
      spec,
      mock,
      { action = "wait", target = "a", timeout = timeout },
      "timeout must be an integer from 1 to 120 seconds"
    )
  end
end)

test("hc status renders only allowlisted status fields without leaking sensitive data", function()
  local mock, spec = setup()
  local raw = '{"address":"machine/task","secret":"secret-raw"}'
  fixture(mock, raw, {
    address = "machine/task",
    terminal = "other",
    state = "live",
    status = { state = "working", message = "secret-status" },
    reason = "output",
    ended = false,
    output = "secret-output",
    message = "secret-message",
    cwd = "secret-path",
    env = { TOKEN = "secret-token" },
    command = "secret-command",
    title = "secret-title",
  })
  mock.output = raw
  local result = spec.handler({ action = "get", target = "machine/task" }, ctx)
  eq(result.llm_output, raw, "raw output must be preserved for the model")
  eq(lines(result.body), "machine/task · live · working · output · not ended")
  eq(lines(spec.restore({ action = "get", target = "machine/task" }, raw, false, ctx)), lines(result.body))
end)

test("hc summaries filter malicious values, controls and unknown enum fields", function()
  local mock, spec = setup()
  fixture(mock, "list", {
    terminals = {
      {
        address = "safe",
        state = "live\27[31m",
        status = "secret-state",
        reason = "secret-reason",
        ended = "true",
        output = "secret",
      },
      { address = "bad\nsecret", state = "live" },
      { terminal = "fallback", state = "finished", status = "done", reason = "exit", ended = true },
      { address = "--option", status = "blocked", reason = "message" },
      { address = "bad;secret" },
      false,
    },
  })
  mock.output = "list"
  local text = lines(spec.handler({ action = "ls" }, ctx).body)
  eq(
    text,
    "safe\nfallback · finished · done · exit · ended\n--option · blocked · message\n3 invalid terminals omitted."
  )
  eq(text:find("secret", 1, true), nil)
  eq(text:find("\27", 1, true), nil)
end)

test("hc list summary caps rows and handles empty or invalid terminal lists", function()
  local mock, spec = setup()
  local terminals = {}
  for i = 1, 26 do
    terminals[i] = { address = "t" .. i }
  end
  fixture(mock, "many", { terminals = terminals })
  mock.output = "many"
  local body = spec.handler({ action = "ls" }, ctx).body
  eq(#body.lines, 26)
  eq(body.lines[1], "t1")
  eq(body.lines[25], "t25")
  eq(body.lines[26], "1 valid terminal omitted.")
  fixture(mock, "empty", { terminals = {} })
  fixture(mock, "invalid", { terminals = { { address = "bad\nname" } } })
  fixture(mock, "missing", { terminals = "secret-list" })
  eq(lines(spec.restore({ action = "ls" }, "empty", false, ctx)), "No terminals to display.")
  eq(lines(spec.restore({ action = "ls" }, "invalid", false, ctx)), "1 invalid terminal omitted.")
  eq(lines(spec.restore({ action = "ls" }, "missing", false, ctx)), "hc output has no terminal list.")
  fixture(mock, "single-invalid", { address = "a\27b", message = "secret" })
  eq(
    lines(spec.restore({ action = "get", target = "a" }, "single-invalid", false, ctx)),
    "No terminal status to display."
  )
end)

test("hc wait summarizes schema fields and bounded children without exposing other data", function()
  local mock, spec = setup()
  local children = {
    {
      terminal = "node/t1",
      reason = "exit",
      ended = true,
      exit_code = -2147483648,
      signal = 15,
      from = "t2",
      output = "secret-output",
    },
    { terminal = "bad\nsecret" },
  }
  for i = 2, 27 do
    children[#children + 1] = { terminal = "t" .. i, reason = "running", ended = false }
  end
  fixture(mock, "wait", {
    terminal = "t0",
    reason = "message",
    ended = false,
    status = "working",
    exit_code = 0,
    signal = 9,
    from = "node/t3",
    children = children,
    message = "secret-message",
  })
  mock.output = "wait"
  local input = { action = "wait", target = "t0" }
  local result = spec.handler(input, ctx)
  eq(result.llm_output, "wait")
  local body = result.body
  eq(body.lines[1], "t0 · working · message · not ended · exit 0 · signal 9 · from node/t3")
  eq(body.lines[2], "Child: node/t1 · exit · ended · exit -2147483648 · signal 15 · from t2")
  eq(body.lines[26], "Child: t25 · running · not ended")
  eq(body.lines[27], "2 valid children omitted.")
  eq(body.lines[28], "1 invalid child omitted.")
  eq(lines(spec.restore(input, "wait", false, ctx)), lines(body))
  eq(lines(body):find("secret", 1, true), nil)
end)

test("hc wait filters invalid signal, exit and sender values without affecting valid fields", function()
  local mock, spec = setup()
  local input = { action = "wait", target = "t0" }
  for _, value in ipairs({ "9", false, {}, 1.5, math.huge, -math.huge, 0 / 0, 2147483648, -2147483649 }) do
    fixture(mock, "bad", { terminal = "t0", exit_code = value, signal = value })
    eq(lines(spec.restore(input, "bad", false, ctx)), "t0")
  end
  for _, sender in ipairs({ false, 42, {}, "node/t1/extra", "bad\nsecret", string.rep("x", 129), "a;secret" }) do
    fixture(mock, "bad-sender", { terminal = "t0", from = sender, exit_code = 2147483647, signal = 0 })
    eq(lines(spec.restore(input, "bad-sender", false, ctx)), "t0 · exit 2147483647 · signal 0")
  end
  fixture(
    mock,
    "nested",
    { terminal = "t0", children = { { terminal = "t1", children = { { terminal = "secret" } } } } }
  )
  eq(lines(spec.restore(input, "nested", false, ctx)), "t0\nChild: t1")
  eq(lines(spec.restore({ action = "get", target = "t0" }, "nested", false, ctx)), "t0")
end)

test("hc list shows bounded machine availability with safe names and states", function()
  local mock, spec = setup()
  local machines = {
    { name = "node", state = "unreachable", why = "secret-why", target = "secret-target" },
    { name = "bad\nsecret", state = "connected" },
    { name = "node/other", state = "connected" },
    { name = "unknown", state = "secret-state" },
    { name = "connecting", state = "connecting" },
    { name = "connected", state = "connected" },
    { name = "login", state = "needs_login" },
  }
  for i = 1, 23 do
    machines[#machines + 1] = { name = "m" .. i, state = "connected" }
  end
  fixture(mock, "machines", { terminals = {}, machines = machines })
  mock.output = "machines"
  local result = spec.handler({ action = "ls" }, ctx)
  eq(result.llm_output, "machines")
  local body = result.body
  eq(body.lines[1], "No terminals to display.")
  eq(body.lines[2], "Machine node · unreachable")
  eq(body.lines[3], "Machine unknown · unknown")
  eq(body.lines[4], "Machine connecting · connecting")
  eq(body.lines[5], "Machine connected · connected")
  eq(body.lines[6], "Machine login · needs_login")
  eq(body.lines[26], "Machine m20 · connected")
  eq(body.lines[27], "3 valid machines omitted.")
  eq(body.lines[28], "2 invalid machines omitted.")
  eq(lines(body):find("secret", 1, true), nil)
  eq(lines(spec.restore({ action = "ls" }, "machines", false, ctx)), lines(body))
end)

test("hc summaries reject malformed, scalar, oversized and throwing JSON without leaking raw data", function()
  local mock, spec = setup()
  fixture(mock, "scalar", "secret-scalar")
  fixture(mock, "decode-error", { address = "secret" }, "parse error")
  for _, raw in ipairs({ "{malformed-secret", "scalar", "decode-error" }) do
    mock.output = raw
    local result = spec.handler({ action = "get", target = "a" }, ctx)
    eq(result.llm_output, raw)
    eq(lines(result.body), "hc output is not structured JSON.")
  end
  local boundary = string.rep("x", 1024 * 1024)
  fixture(mock, boundary, { terminals = {} })
  mock.output = boundary
  local at_limit = spec.handler({ action = "ls" }, full_ctx)
  eq(at_limit.llm_output, boundary)
  eq(lines(at_limit.body), "No terminals to display.")
  local before = #mock.decodes
  local huge = boundary .. "x"
  mock.output = huge
  local result = spec.handler({ action = "ls" }, full_ctx)
  eq(result.llm_output, huge)
  eq(lines(result.body), "hc output unavailable for summary.")
  eq(#mock.decodes, before, "oversize output must not be decoded")
  mock.decode_throws = true
  mock.output = "secret-raw"
  result = spec.handler({ action = "ls" }, ctx)
  eq(result.llm_output, "secret-raw")
  eq(lines(result.body), "hc summary unavailable; details are in the tool output.")
end)

test("hc errors preserve custom bash errors for model but never expose them in summary", function()
  local mock, spec = setup()
  mock.output, mock.detail = nil, "permission denied: secret-token\27[31m"
  local result = spec.handler({ action = "get", target = "a" }, ctx)
  eq(result.is_error, true)
  eq(result.llm_output, mock.detail)
  eq(lines(result.body), "hc failed; details are in the tool output.")
  eq(#mock.decodes, 0)
  mock.detail = { secret = "private" }
  result = spec.handler({ action = "ls" }, ctx)
  eq(result.llm_output, "error: bash returned no output")
  eq(result.is_error, true)
  eq(lines(result.body), "hc failed; details are in the tool output.")
  mock.output = { secret = "private" }
  result = spec.handler({ action = "ls" }, ctx)
  eq(result.llm_output, "error: bash returned invalid output")
  eq(result.is_error, true)
  eq(lines(result.body), "hc failed; details are in the tool output.")
end)

test("hc restore never calls tools and fails closed on invalid arguments or errors", function()
  local mock, spec = setup()
  fixture(mock, "ok", { address = "a", status = "idle" })
  local input = { action = "get", target = "a" }
  eq(lines(spec.restore(input, "ok", false, ctx)), "a · idle")
  -- Real Maki uses userdata for its restore ctx, not a Lua table.
  local userdata_ctx = io.tmpfile()
  truthy(userdata_ctx)
  eq(type(userdata_ctx), "userdata")
  eq(lines(spec.restore(input, "ok", false, userdata_ctx)), "a · idle")
  userdata_ctx:close()
  eq(lines(spec.restore(input, "secret", true, ctx)), "hc failed; details are in the tool output.")
  eq(
    lines(spec.restore({ action = "get", target = "a;id" }, "secret", false, ctx)),
    "hc output unavailable for summary."
  )
  eq(lines(spec.restore(input, {}, false, ctx)), "hc output unavailable for summary.")
  eq(lines(spec.restore(input, "ok", nil, ctx)), "hc output unavailable for summary.")
  eq(lines(spec.restore(input, "ok", "false", ctx)), "hc output unavailable for summary.")
  eq(lines(spec.restore(input, "ok", false, nil)), "hc output unavailable for summary.")
  mock.decode_throws = true
  eq(lines(spec.restore(input, "ok", false, ctx)), "hc summary unavailable; details are in the tool output.")
  mock.host.ui.buf = function()
    error("secret UI exception")
  end
  eq(pcall(spec.restore, input, "ok", false, ctx), false)
  eq(#mock.calls, 0)
end)

test("hc compact output is bounded with explicit truncation and full mode preserves output", function()
  local mock, spec = setup()
  local raw = string.rep("a", 9000) .. "é" .. string.rep("b", 9000)
  mock.output = raw
  mock.output = string.rep("x", 16 * 1024)
  local at_limit = spec.handler({ action = "ls" }, ctx)
  eq(at_limit.llm_output, mock.output)
  mock.output = raw
  local result = spec.handler({ action = "ls" }, ctx)
  eq(mock.calls[2].opts.output_mode, "compact")
  truthy(#result.llm_output <= 16 * 1024)
  truthy(result.llm_output:find("[output truncated; incomplete text, not JSON]", 1, true))
  eq(result.llm_output:sub(1, 10), string.rep("a", 10))
  eq(result.llm_output:sub(-10), string.rep("b", 10))
  result = spec.handler({ action = "ls" }, full_ctx)
  eq(mock.calls[3].opts.output_mode, "full")
  eq(result.llm_output, raw)
  mock.output = nil
  mock.detail = "permission denied: " .. raw .. " END"
  result = spec.handler({ action = "ls" }, ctx)
  eq(result.is_error, true)
  truthy(#result.llm_output <= 16 * 1024)
  truthy(result.llm_output:find("permission denied:", 1, true))
  truthy(result.llm_output:find("[output truncated; incomplete text, not JSON]", 1, true))
  eq(result.llm_output:sub(-4), " END")
  result = spec.handler({ action = "ls" }, full_ctx)
  eq(result.llm_output, mock.detail)
end)

test("hc truncation does not split UTF-8 at either boundary", function()
  local mock, spec = setup()
  mock.output = string.rep("é", 10000)
  local text = spec.handler({ action = "ls" }, ctx).llm_output
  local head, tail = text:match("^(.-)\n%[output truncated; incomplete text, not JSON%]\n(.*)$")
  truthy(head)
  eq(#head % 2, 0)
  eq(#tail % 2, 0)
  eq(head, string.rep("é", #head / 2))
  eq(tail, string.rep("é", #tail / 2))
end)

test("hc summaries count valid omitted and invalid entries independently", function()
  local mock, spec = setup()
  local terminals = { false, { address = "bad\nname" } }
  for i = 1, 27 do
    terminals[#terminals + 1] = { address = "t" .. i }
  end
  terminals[#terminals + 1] = false
  fixture(mock, "mixed", { terminals = terminals })
  local body = spec.restore({ action = "ls" }, "mixed", false, ctx)
  eq(#body.lines, 27)
  eq(body.lines[1], "t1")
  eq(body.lines[25], "t25")
  eq(body.lines[26], "2 valid terminals omitted.")
  eq(body.lines[27], "3 invalid terminals omitted.")
  eq(#mock.calls, 0)
end)

test("hc list and single summaries support all documented allowlisted states and reasons", function()
  local mock, spec = setup()
  local states = { "idle", "working", "done", "blocked", "error" }
  local reasons = { "status", "exit", "timeout", "message", "output", "not_started", "children", "running" }
  for _, state in ipairs(states) do
    for _, reason in ipairs(reasons) do
      fixture(
        mock,
        "enum",
        { terminal = "node", state = "finished", status = { state = state }, reason = reason, ended = true }
      )
      eq(
        lines(spec.restore({ action = "wait", target = "node" }, "enum", false, ctx)),
        "node · finished · " .. state .. " · " .. reason .. " · ended"
      )
    end
  end
  eq(#mock.calls, 0)
end)
