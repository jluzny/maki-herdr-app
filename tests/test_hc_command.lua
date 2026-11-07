local hc_command = require("maki_herdr_app.hc_command")

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
          error("decode failed")
        end
        local fixture = mock.fixtures[raw]
        if fixture then
          return fixture.value, fixture.err
        end
        return nil, "invalid JSON"
      end,
    },
    agent = {
      call_tool = function(context, name, args, opts)
        mock.calls[#mock.calls + 1] = { ctx = context, name = name, args = args, opts = opts }
        return mock.output, mock.detail
      end,
    },
  }
  hc_command.start(host)
  return mock, mock.spec
end

local function lines(body)
  truthy(body)
  return table.concat(body.lines, "\n")
end

local function reject(mock, spec, input)
  local before = #mock.calls
  local result = spec.handler(input, ctx)
  eq(result.is_error, true)
  truthy(result.llm_output:find("error:", 1, true))
  eq(#mock.calls, before, "invalid input must not invoke bash")
end

test("hc command registers a bounded execute tool", function()
  local _, spec = setup()
  eq(spec.name, "hc_command")
  eq(spec.permission, "run")
  eq(spec.kind, "execute")
  eq(spec.timeout, 140)
  eq(spec.schema.type, "object")
  eq(spec.schema.additionalProperties, false)
  eq(spec.schema.required[1], "argv")
  eq(spec.schema.properties.argv.type, "array")
  eq(spec.schema.properties.argv.items.type, "string")
  eq(spec.schema.properties.argv.items.maxLength, 16384)
  eq(spec.schema.properties.argv.minItems, 1)
  eq(spec.schema.properties.argv.maxItems, 128)
  hc_command.start({ api = {} })
end)

test("hc command delegates to bash with the original permission context", function()
  local mock, spec = setup()
  local context = { permission = { token = "original" }, output_mode = full_ctx.output_mode }
  local result = spec.handler({ argv = { "send", "--json", "terminal", "hello" } }, context)
  eq(result.llm_output, "{}")
  eq(#mock.calls, 1)
  local call = mock.calls[1]
  eq(call.ctx, context)
  eq(call.name, "bash")
  eq(call.args.command, 'hc "send" "--json" "terminal" "hello"')
  eq(call.args.timeout, 130)
  eq(call.args.description, "Run hc send")
  eq(call.opts.timeout, 130)
  eq(call.opts.output_mode, "full")
  local count = 0
  for _ in pairs(call.opts) do
    count = count + 1
  end
  eq(count, 2, "no permission bypass options")
end)

test("hc command accepts only the shell-safe alphabet and preserves argument boundaries", function()
  local mock, spec = setup()
  local result = spec.handler({ argv = { "exec", "program", "AZaz09 _.,/:@+=-", "two words", "--stdin" } }, ctx)
  eq(result.is_error, nil)
  eq(#mock.calls, 1)
  eq(mock.calls[1].args.command, 'hc "exec" "program" "AZaz09 _.,/:@+=-" "two words" "--stdin"')
  result = spec.handler({ argv = { "send", "terminal", "" } }, ctx)
  eq(result.is_error, nil)
  eq(mock.calls[2].args.command, 'hc "send" "terminal" ""')
end)

test("hc command rejects unsafe characters in arguments and flag values", function()
  local mock, spec = setup()
  for _, value in ipairs({
    "%PATH%",
    "!bang!",
    "^caret",
    "a'b",
    'a"b',
    "é",
    "line\nnext",
    "line\rnext",
    "tab\tnext",
    "$(id)",
    "`id`",
    "x;id",
    "x|id",
    "x&id",
    "x>id",
    "x<id",
    "*?[]",
    "\\",
    "{x}",
    "~",
    "#",
    "x\0y",
  }) do
    reject(mock, spec, { argv = { "send", "terminal", value } })
    reject(mock, spec, { argv = { "exec", "--cwd", value, "program" } })
    reject(mock, spec, { argv = { "exec", "--cwd=" .. value, "program" } })
  end
  for byte = 1, 127 do
    local char = string.char(byte)
    if not char:match("^[a-zA-Z0-9 _%.,/:%@%+%=%-]$") then
      reject(mock, spec, { argv = { "send", "terminal", "x" .. char .. "y" } })
      reject(mock, spec, { argv = { "exec", "--env=x" .. char .. "y", "program" } })
    end
  end
  eq(#mock.calls, 0)
end)

test("hc command rejects malformed argv and enforces size bounds before bash", function()
  local mock, spec = setup()
  for _, input in ipairs({
    false,
    "exec",
    {},
    { argv = false },
    { argv = {} },
    { argv = { "templates" }, extra = true },
    { argv = { [1] = "send", [3] = "x" } },
    { argv = { "templates", false } },
    { argv = { "send", "a", "x\0y" } },
    { argv = { "exec", string.rep("x", 16385) } },
    { argv = { [129] = "x" } },
  }) do
    reject(mock, spec, input)
  end
  reject(mock, spec, nil)
  local max_total =
    { "exec", string.rep("x", 16384), string.rep("x", 16384), string.rep("x", 16384), string.rep("x", 16380) }
  spec.handler({ argv = max_total }, ctx)
  eq(#mock.calls, 1)
  max_total[5] = max_total[5] .. "x"
  reject(mock, spec, { argv = max_total })
  local max_args = { "exec" }
  for i = 2, 128 do
    max_args[i] = "x"
  end
  spec.handler({ argv = max_args }, ctx)
  eq(#mock.calls, 2)
  max_args[129] = "x"
  reject(mock, spec, { argv = max_args })
end)

test("hc command rejects interactive and stdin modes without executing", function()
  local mock, spec = setup()
  for _, argv in ipairs({
    { "attach", "terminal" },
    { "connect", "terminal" },
    { "events" },
    { "file", "write", "path" },
    { "machine", "login", "node" },
    { "exec", "-i", "cat" },
    { "exec", "--stdin", "cat" },
    { "run", "program" },
    { "machine", "add" },
    { "machine", "add", "--install" },
    { "send", "terminal" },
    { "send", "--timeout" },
    { "templates", "--bogus" },
  }) do
    reject(mock, spec, { argv = argv })
  end
  spec.handler({ argv = { "run", "--bg", "program" } }, ctx)
  spec.handler({ argv = { "exec", "program", "--stdin" } }, ctx)
  eq(#mock.calls, 2)
end)

test("hc command accepts supported finite commands and flags", function()
  local mock, spec = setup()
  local cases = {
    { "ls", "--all", "--label", "team blue" },
    { "get", "--json", "terminal" },
    { "read", "--lines=20", "terminal" },
    { "wait", "--children", "all", "--output=full", "--timeout", "30", "terminal" },
    { "label", "terminal", "team=blue", "active" },
    { "keep", "--off", "terminal" },
    { "keys", "terminal", "Enter", "Tab" },
    { "interrupt", "--timeout=10", "terminal" },
    { "put", "terminal", "text" },
    { "schema", "--json" },
    { "send", "--wait", "--if=idle", "--timeout", "10", "terminal", "message" },
    { "kill", "terminal" },
    { "rm", "terminal" },
    { "templates" },
    {
      "run",
      "--bg",
      "--name",
      "job",
      "--cwd=/tmp",
      "--on",
      "node",
      "--label",
      "team=blue",
      "--parent",
      "terminal",
      "--timeout",
      "30",
      "--json",
      "--no-parent",
      "--no-notify",
      "--outlive-parent",
      "--rm",
      "--keep",
      "program",
      "--any-program-flag",
    },
    { "exec", "--on=node", "--cwd", "/tmp", "--env", "KEY=value", "--timeout", "30", "program", "-i" },
    { "update", "--from", "stable", "--version=1.2", "--json" },
    { "file", "read", "--on", "node", "--cwd=/tmp", "--offset", "1", "--limit=10", "file.txt" },
    { "file", "edit", "--old=", "--new", "", "file.txt" },
    { "machine", "ls" },
    { "machine", "add", "--install", "--temp", "--name", "node", "--session", "s", "target" },
    { "machine", "add", "--install", "--via=host", "--name=node" },
    { "machine", "update", "node" },
    { "machine", "rename", "node", "new-name" },
    { "machine", "rm", "node" },
    { "server", "start" },
    { "server", "stop" },
    { "server", "status" },
    { "server", "restart" },
    { "help" },
    { "help", "file", "read" },
    { "--help" },
    { "-h" },
    { "--version" },
    { "-V" },
    { "--skill" },
    { "--licenses" },
    { "exec", "--help" },
    { "file", "read", "-h" },
  }
  for i, argv in ipairs(cases) do
    local result = spec.handler({ argv = argv }, ctx)
    eq(result.is_error, nil, "valid case " .. i)
    eq(#mock.calls, i)
    local parts = { "hc" }
    for _, arg in ipairs(argv) do
      parts[#parts + 1] = '"' .. arg .. '"'
    end
    eq(mock.calls[i].args.command, table.concat(parts, " "), "valid case " .. i)
  end
end)

test("hc command rejects invalid finite commands and flag values before dispatch", function()
  local mock, spec = setup()
  for _, argv in ipairs({
    { "unknown" },
    { "file" },
    { "machine" },
    { "server" },
    { "file", "unknown" },
    { "machine", "unknown" },
    { "server", "unknown" },
    { "schema", "extra" },
    { "get" },
    { "get", "one", "two" },
    { "label", "terminal" },
    { "put", "terminal" },
    { "send", "", "message" },
    { "send", "terminal", "message", "extra" },
    { "exec", "" },
    { "exec", "--cwd", "", "program" },
    { "exec", "--cwd=", "program" },
    { "read", "--lines" },
    { "read", "--lines=", "terminal" },
    { "file", "edit", "--new" },
    { "file", "read", "--limit=", "path" },
    { "send", "--wait=true", "terminal", "message" },
    { "send", "--force", "terminal", "message" },
    { "update", "--force" },
    { "machine", "add", "--install", "--via", "host" },
    { "machine", "add", "--via", "host", "--name", "node" },
    { "run", "program", "--bg" },
    { "help", "file", "read", "extra" },
    { "help", "--json" },
    { "--version", "extra" },
    { "templates", "--", "extra" },
  }) do
    reject(mock, spec, { argv = argv })
  end
  eq(#mock.calls, 0)
end)

test("hc command propagates permission and invalid bash failures", function()
  local mock, spec = setup()
  mock.output, mock.detail = nil, "permission denied: cannot run bash"
  local result = spec.handler({ argv = { "templates" } }, ctx)
  eq(result.is_error, true)
  eq(result.llm_output, mock.detail)
  eq(lines(result.body), mock.detail)
  eq(#mock.calls, 1)
  eq(#mock.decodes, 0)
  mock.detail = { reason = "denied" }
  result = spec.handler({ argv = { "templates" } }, ctx)
  eq(result.is_error, true)
  eq(result.llm_output, "error: bash returned no output")
  mock.output = {}
  result = spec.handler({ argv = { "templates" } }, ctx)
  eq(result.is_error, true)
  eq(result.llm_output, "error: bash returned invalid output")
end)

test("hc command summaries and raw fallbacks restore without reexecution", function()
  local mock, spec = setup()
  mock.fixtures.list = { value = { templates = { { name = "one", state = "ready" } } } }
  mock.fixtures.send = { value = { turn = 7, started = true } }
  mock.fixtures.missing = { value = {} }
  mock.fixtures.error = { value = { error = "failed" } }
  local input = { argv = { "templates", "--json" } }
  mock.output = "list"
  local result = spec.handler(input, ctx)
  eq(result.llm_output, "list")
  eq(lines(result.body), "one · ready")
  eq(lines(spec.restore(input, "list", false, ctx)), lines(result.body))
  eq(
    lines(spec.restore({ argv = { "send", "a", "hello" } }, "send", false, ctx)),
    "Send accepted · turn 7\nTurn started."
  )
  for _, raw in ipairs({ "not json", "missing", "error" }) do
    eq(lines(spec.restore(input, raw, false, ctx)), raw)
  end
  eq(lines(spec.restore(input, "failed\27[31m\r\t", true, ctx)), "failed?[31m??")
  eq(lines(spec.restore(input, {}, false, ctx)), "hc output unavailable.")
  eq(lines(spec.restore(input, "list", nil, ctx)), "hc output unavailable.")
  eq(lines(spec.restore(input, "list", false, nil)), "hc output unavailable.")
  mock.decode_throws = true
  eq(lines(spec.restore(input, "raw", false, ctx)), "raw")
  eq(#mock.calls, 1, "restore must never reexecute")
end)

test("hc command summarizes actual terminal and message results", function()
  local mock, spec = setup()
  local cases = {
    {
      { "run", "--bg", "agent" },
      {
        address = "t7",
        state = "live",
        first_message = {
          sent = true,
          turn = 3,
          started = true,
        },
      },
      "Terminal t7 · live\nFirst message sent.\nFirst message turn: 3\nFirst message started.",
    },
    {
      { "run", "--bg", "agent" },
      {
        address = "t7",
        first_message = {
          sent = false,
          reason = "not_started",
          started = false,
        },
      },
      "Terminal t7\nFirst message was not sent; inspect the terminal before retrying.\nFirst message reason: not_started\nFirst message not observed starting.",
    },
    {
      { "send", "--wait", "t7", "hello" },
      {
        turn = 4,
        status = "idle",
        started = false,
        wait = { terminal = "t7", reason = "timeout", status = "working", ended = false, exit_code = 0 },
      },
      "Send accepted · turn 4 · status idle\nTurn not observed starting.\nWait: t7 · reason timeout · status working · ended false · exit 0",
    },
    {
      { "get", "t7" },
      { address = "t7", state = "finished", status = { state = "done" }, exit_code = -1 },
      "Terminal t7 · finished · status done · exit -1",
    },
    {
      { "kill", "t7" },
      { address = "t7", state = "finished", exit_code = 0 },
      "Terminal t7 · finished · exit 0",
    },
    { { "rm", "t7" }, { removed = "t7" }, "Removed t7" },
    {
      { "templates" },
      { templates = { { name = "agent", error = "bad config\nsecret" } } },
      "agent · error (see raw output)",
    },
    {
      { "ls" },
      {
        terminals = {
          { address = "t7", state = "live", status = "done" },
          { address = "node/t8", state = "finished", exit_code = 2 },
        },
        hidden_finished = 3,
        machines = { { name = "node" } },
      },
      "Terminal t7 · live · status done\nTerminal node/t8 · finished · exit 2\n3 finished terminals hidden.\n1 machine (see raw output).",
    },
    {
      { "wait", "t7" },
      {
        terminal = "t7",
        ended = true,
        reason = "children",
        status = "done",
        exit_code = 0,
        children = { { terminal = "t8", reason = "exit", ended = true, exit_code = 2 } },
      },
      "Wait: t7 · reason children · status done · ended true · exit 0\nChild: t8 · reason exit · ended true · exit 2",
    },
  }
  for i, case in ipairs(cases) do
    local raw = "fixture" .. i
    mock.fixtures[raw] = { value = case[2] }
    mock.output = raw
    local input = { argv = case[1] }
    local result = spec.handler(input, ctx)
    eq(result.llm_output, raw)
    eq(lines(result.body), case[3])
    eq(lines(spec.restore(input, raw, false, ctx)), case[3])
  end
end)

test("hc command bounds and sanitizes summaries without hiding raw errors from the model", function()
  local mock, spec = setup()
  local children, terminals, templates = {}, {}, {}
  for i = 1, 30 do
    children[i] = { terminal = "t" .. i, reason = "exit", ended = true }
    terminals[i] = { address = "t" .. i, state = "live" }
    templates[i] = { name = "agent" .. i }
  end
  terminals[1].status = { state = "bad\27[31m" }
  templates[1].error = "secret\nmessage"
  mock.fixtures.list = { value = { terminals = terminals, hidden_finished = 0, machines = {} } }
  mock.fixtures.templates = { value = { templates = templates } }
  mock.fixtures.wait = { value = { terminal = "t1", reason = "children", ended = true, children = children } }
  mock.fixtures.unsafe = {
    value = {
      turn = 1,
      status = "bad\nstatus",
      wait = {
        terminal = "t1\27",
        reason = string.rep("r", 129),
        status = "bad\nstatus",
        ended = false,
        exit_code = 1 / 0,
      },
    },
  }
  mock.fixtures.error = { value = { error = "sensitive details" } }
  for _, case in ipairs({
    { "list", { "ls" }, "5 entries omitted." },
    { "templates", { "templates" }, "5 entries omitted." },
    { "wait", { "wait", "t1" }, "5 children omitted." },
  }) do
    mock.output = case[1]
    local result = spec.handler({ argv = case[2] }, ctx)
    local body = lines(result.body)
    truthy(body:find(case[3], 1, true))
    truthy(not body:find("secret", 1, true))
    truthy(not body:find("\27", 1, true))
    eq(result.llm_output, case[1])
  end
  mock.output = "unsafe"
  local result = spec.handler({ argv = { "send", "t1", "hello" } }, ctx)
  eq(lines(result.body), "Send accepted · turn 1\nWait: ended false")
  eq(result.llm_output, "unsafe")
  mock.output = "error"
  result = spec.handler({ argv = { "templates" } }, ctx)
  eq(result.llm_output, "error")
  eq(lines(result.body), "error")
  eq(lines(spec.restore({ argv = { "ls" } }, "error", true, ctx)), "error")
end)

test("hc command compact output truncates safely while full output is preserved", function()
  local mock, spec = setup()
  local input = { argv = { "templates" } }
  mock.output = string.rep("é", 10000)
  local result = spec.handler(input, ctx)
  eq(mock.calls[1].opts.output_mode, "compact")
  truthy(#result.llm_output <= 16384)
  local head, tail = result.llm_output:match("^(.-)\n%[output truncated; incomplete text, not JSON%]\n(.*)$")
  truthy(head)
  eq(head, string.rep("é", #head / 2))
  eq(tail, string.rep("é", #tail / 2))
  result = spec.handler(input, full_ctx)
  eq(mock.calls[2].opts.output_mode, "full")
  eq(result.llm_output, mock.output)
  mock.output, mock.detail = nil, "permission denied: " .. string.rep("x", 18000) .. " END"
  result = spec.handler(input, ctx)
  eq(result.is_error, true)
  truthy(#result.llm_output <= 16384)
  truthy(result.llm_output:find("[output truncated; incomplete text, not JSON]", 1, true))
  eq(result.llm_output:sub(-4), " END")
  eq(spec.handler(input, full_ctx).llm_output, mock.detail)
end)
