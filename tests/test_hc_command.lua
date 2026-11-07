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

local function encode64(text)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  local out = {}
  for i = 1, #text, 3 do
    local a, b, c = text:byte(i, i + 2)
    local n = a * 65536 + (b or 0) * 256 + (c or 0)
    local function char(value)
      return alphabet:sub(value + 1, value + 1)
    end
    out[#out + 1] = char(math.floor(n / 262144))
      .. char(math.floor(n / 4096) % 64)
      .. (b and char(math.floor(n / 64) % 64) or "=")
      .. (c and char(n % 64) or "=")
  end
  return table.concat(out)
end

local function setup()
  local mock =
    { calls = {}, fixtures = {}, decodes = {}, base64_values = { [""] = "", c2VjcmV0 = "secret" }, output = "{}" }
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
    base64 = {
      decode = function(encoded)
        if mock.base64_throws then
          error("base64 decode failed")
        end
        local decoded = mock.base64_values[encoded]
        if decoded == nil then
          return nil, "invalid base64"
        end
        return decoded
      end,
    },
    text = {
      to_utf8 = function(text)
        return text:gsub("\255", "�")
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
    { "file", "edit", "--old=--json", "--new=-x", "file.txt" },
    { "wait", "--output", "-", "terminal" },
    { "run", "--bg", "--cwd=--json", "program", "--flag" },
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
    { "run", "--name", "--bg", "--bg", "program" },
    { "run", "--name", "--", "--bg", "program" },
    { "exec", "--cwd", "--stdin", "program" },
    { "send", "--if", "--force", "terminal", "message" },
    { "wait", "--output", "--json", "terminal" },
    { "wait", "--output", "-x", "terminal" },
    { "file", "edit", "--old", "--new", "value", "path" },
    { "machine", "add", "--name", "--install", "--install", "target" },
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
        machines = { { name = "node", state = "unreachable" } },
      },
      "Terminal t7 · live · status done\nTerminal node/t8 · finished · exit 2\n3 finished terminals hidden.\nMachine node · unreachable",
    },
    {
      { "wait", "t7" },
      {
        terminal = "t7",
        ended = true,
        reason = "children",
        status = "done",
        exit_code = 0,
        signal = 15,
        from = "node/t9",
        children = { { terminal = "t8", reason = "exit", ended = true, exit_code = 2 } },
      },
      "Wait: t7 · reason children · status done · ended true · exit 0 · signal 15 · from node/t9\nChild: t8 · reason exit · ended true · exit 2",
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

test("hc command summarizes verified result shapes", function()
  local mock, spec = setup()
  local cases = {
    {
      { "read", "t1" },
      { text = "secret", complete = false, how = "screen", why = "working" },
      "Read · screen · complete false · why working\nText:\nsecret",
    },
    {
      { "interrupt", "t1" },
      { outcome = "still_working", key = "ctrl+c" },
      "Interrupt · still_working · key ctrl+c",
    },
    { { "keys", "t1", "enter" }, { turn = 0, status = "working" }, "Keys accepted · turn 0 · status working" },
    { { "put", "t1", "file" }, { path = "/private/secret", bytes = 0 }, "File sent · 0 bytes" },
    {
      { "file", "read", "file" },
      { text = "", first = 4, last = 3, lines = 3 },
      "File read · empty range · total 3\nText: [empty]",
    },
    { { "file", "edit", "file" }, { path = "/private/secret", bytes = 123 }, "File edited · 123 bytes" },
    {
      { "exec", "program" },
      { stdout = "c2VjcmV0", stderr = "c2VjcmV0", code = 2, ms = 9, timed_out = false, truncated = true },
      "Exec · exit 2 · 9 ms · timed out false · truncated true\nStdout:\nsecret\nStderr:\nsecret",
    },
    {
      { "exec", "program" },
      { stdout = "", stderr = "", signal = 9, ms = 0, timed_out = true, truncated = false },
      "Exec · signal 9 · 0 ms · timed out true · truncated false\nStdout: [empty]\nStderr: [empty]",
    },
    {
      { "server", "status" },
      { pid = 42, uptime_ms = 100, version = "0.1.18", live = 2, finished = 1 },
      "Server status · version 0.1.18 · pid 42 · uptime 100 ms\nTerminals · live 2 · finished 1",
    },
    { { "server", "stop" }, { stopped = false }, "Server stop · stopped false" },
    { { "server", "restart" }, { stopped = true }, "Server restart request · stopped true · restart not confirmed" },
    {
      { "server", "restart" },
      { stopped = false },
      "Server restart request · stopped false · restart not confirmed",
    },
    {
      { "label", "t1", "test=value" },
      { address = "t1", state = "live", labels = { test = "value" } },
      "Terminal t1 · live\nLabel test = value",
    },
    { { "keep", "t1" }, { address = "t1", state = "live", keep = true }, "Terminal t1 · live\nKeep · true" },
    {
      { "keep", "--off", "t1" },
      { address = "t1", state = "live", keep = false },
      "Terminal t1 · live\nKeep · false",
    },
    { { "machine", "rm", "node" }, { removed = "node" }, "Machine removed node" },
    {
      { "update" },
      { now = "hc 0.1.18", release = "0.0.1", updated = false },
      "Update · updated false\nNow: hc 0.1.18\nRelease: 0.0.1",
    },
    {
      { "update" },
      { now = "hc 0.1.18", release = "0.1.18", updated = false, restarted = true },
      "Update · updated false · restarted true\nNow: hc 0.1.18\nRelease: 0.1.18",
    },
    {
      { "server", "start" },
      { pid = 42, uptime_ms = 100, version = "0.1.18", live = 2, finished = 1 },
      "Server status · version 0.1.18 · pid 42 · uptime 100 ms\nTerminals · live 2 · finished 1",
    },
  }
  for i, case in ipairs(cases) do
    local raw = "verified" .. i
    mock.fixtures[raw] = { value = case[2] }
    mock.output = raw
    local input = { argv = case[1] }
    local result = spec.handler(input, ctx)
    eq(result.llm_output, raw)
    eq(lines(result.body), case[3])
    eq(lines(spec.restore(input, raw, false, ctx)), case[3])
  end
end)

test("hc exec decodes base64 previews or falls back without changing raw output", function()
  local mock, spec = setup()
  local input = { argv = { "exec", "--json", "program" } }
  local raw =
    '{"code":2,"ms":2,"signal":null,"stderr":"ZXJyCg==","stdout":"aGVsbG8KAP8=","timed_out":false,"truncated":false}'
  mock.base64_values["aGVsbG8KAP8="] = "hello\n\0\255"
  mock.base64_values["ZXJyCg=="] = "err\n"
  mock.fixtures[raw] =
    { value = { stdout = "aGVsbG8KAP8=", stderr = "ZXJyCg==", code = 2, ms = 2, timed_out = false, truncated = false } }
  mock.output = raw
  local result = spec.handler(input, full_ctx)
  eq(result.llm_output, raw)
  eq(
    lines(result.body),
    "Exec · exit 2 · 2 ms · timed out false · truncated false\nStdout:\nhello\n?�\nStderr:\nerr"
  )
  eq(lines(spec.restore(input, raw, false, ctx)), lines(result.body))
  mock.fixtures.invalid_stdout =
    { value = { stdout = "%%%", stderr = "ZXJyCg==", ms = 2, timed_out = false, truncated = false } }
  mock.fixtures.invalid_stderr =
    { value = { stdout = "aGVsbG8KAP8=", stderr = "%%%", ms = 2, timed_out = false, truncated = false } }
  for _, invalid in ipairs({ "invalid_stdout", "invalid_stderr" }) do
    mock.output = invalid
    eq(spec.handler(input, ctx).llm_output, invalid)
    eq(lines(spec.handler(input, ctx).body), invalid)
    eq(lines(spec.restore(input, invalid, false, ctx)), invalid)
  end
  mock.base64_throws = true
  eq(lines(spec.restore(input, raw, false, ctx)), raw)
  mock.base64_throws = false
  mock.base64_values["ZXJyCg=="] = nil
  mock.output = raw
  eq(lines(spec.handler(input, full_ctx).body), raw)
  eq(spec.handler(input, full_ctx).llm_output, raw)
end)

test("hc command displays bounded sanitized content without changing model output", function()
  local mock, spec = setup()
  local input = { argv = { "read", "t1" } }
  local text = "first\n\nsecond\27[31m\r\t\0\127\194\155end"
  local raw = '{"text":"first\\n\\nsecond\\u001b[31m\\r\\t\\u0000\\u007f\\u009bend","complete":true,"how":"screen"}'
  mock.fixtures[raw] = { value = { text = text, complete = true, how = "screen" } }
  mock.output = raw
  local result = spec.handler(input, full_ctx)
  eq(result.llm_output, raw)
  eq(spec.handler(input, ctx).llm_output, raw)
  eq(lines(result.body), "Read · screen · complete true\nText:\nfirst\n\nsecond?[31m?????end")
  eq(lines(spec.restore(input, raw, false, ctx)), lines(result.body))

  local file = { argv = { "file", "read", "file" } }
  mock.fixtures.file = { value = { text = "one\ntwo\n", first = 1, last = 2, lines = 2 } }
  eq(lines(spec.restore(file, "file", false, ctx)), "File read · lines 1–2 · total 2\nText:\none\ntwo")
  mock.fixtures.empty = { value = { text = "", first = 1, last = 0, lines = 0 } }
  eq(lines(spec.restore(file, "empty", false, ctx)), "File read · empty range · total 0\nText: [empty]")

  local exec = { argv = { "exec", "program" } }
  local large_stdout = string.rep("x", 4095) .. "é" .. "tail"
  local large_stderr = string.rep("line\n", 25) .. "hidden"
  mock.base64_values[encode64(large_stdout)] = large_stdout
  mock.base64_values[encode64(large_stderr)] = large_stderr
  mock.fixtures.large = {
    value = {
      stdout = encode64(large_stdout),
      stderr = encode64(large_stderr),
      ms = 1,
      timed_out = false,
      truncated = false,
    },
  }
  mock.output = "large"
  local large = spec.handler(exec, full_ctx)
  eq(large.llm_output, "large")
  local body = lines(large.body)
  truthy(body:find("Stdout:\n" .. string.rep("x", 4095) .. "\n[content truncated; remainder omitted]", 1, true))
  truthy(body:find("Stderr:\n" .. string.rep("line\n", 25) .. "[content truncated; remainder omitted]", 1, true))
  truthy(not body:find("hidden", 1, true))
  truthy(not body:find("tail", 1, true))
  eq(lines(spec.restore(exec, "large", false, ctx)), body)

  local boundary_stdout = string.rep("x", 4096)
  local boundary_stderr = string.rep("line\n", 25)
  mock.base64_values[encode64(boundary_stdout)] = boundary_stdout
  mock.base64_values[encode64(boundary_stderr)] = boundary_stderr
  mock.fixtures.boundary = {
    value = {
      stdout = encode64(boundary_stdout),
      stderr = encode64(boundary_stderr),
      ms = 1,
      timed_out = false,
      truncated = false,
    },
  }
  truthy(not lines(spec.restore(exec, "boundary", false, ctx)):find("[content truncated; remainder omitted]", 1, true))
end)

test("hc command sanitizes bidi controls in all content previews", function()
  local mock, spec = setup()
  local controls = {
    "\216\156",
    "\226\128\142",
    "\226\128\143",
    "\226\128\170",
    "\226\128\171",
    "\226\128\172",
    "\226\128\173",
    "\226\128\174",
    "\226\129\166",
    "\226\129\167",
    "\226\129\168",
    "\226\129\169",
  }
  local text = "العربية עברית café 😀\nstart"
    .. table.concat(controls, "x")
    .. "end\n"
    .. "\216\155\216\157\226\128\141\226\128\144\226\128\169\226\128\175\226\129\165\226\129\170"
  local expected = "العربية עברית café 😀\nstart"
    .. string.rep("?x", #controls - 1)
    .. "?end\n"
    .. "\216\155\216\157\226\128\141\226\128\144\226\128\169\226\128\175\226\129\165\226\129\170"
  local encoded = encode64(text)
  mock.base64_values[encoded] = text
  local cases = {
    {
      { "read", "t1" },
      { text = text, complete = true, how = "screen" },
      "Read · screen · complete true\nText:\n" .. expected,
    },
    {
      { "file", "read", "file" },
      { text = text, first = 1, last = 2, lines = 2 },
      "File read · lines 1–2 · total 2\nText:\n" .. expected,
    },
    {
      { "exec", "program" },
      { stdout = encoded, stderr = encoded, ms = 1, timed_out = false, truncated = false },
      "Exec · 1 ms · timed out false · truncated false\nStdout:\n" .. expected .. "\nStderr:\n" .. expected,
    },
  }
  for i, case in ipairs(cases) do
    local raw = "bidi" .. i
    mock.fixtures[raw] = { value = case[2] }
    mock.output = raw
    local input = { argv = case[1] }
    local result = spec.handler(input, full_ctx)
    eq(result.llm_output, raw)
    eq(lines(result.body), case[3])
    eq(lines(spec.restore(input, raw, false, ctx)), case[3])
  end

  local boundary = string.rep("a", 4094) .. "\226\128\174" .. "tail"
  mock.fixtures.bidi_boundary = { value = { text = boundary, complete = true, how = "screen" } }
  local body = lines(spec.restore({ argv = { "read", "t1" } }, "bidi_boundary", false, ctx))
  eq(
    body,
    "Read · screen · complete true\nText:\n" .. string.rep("a", 4094) .. "\n[content truncated; remainder omitted]"
  )
end)

test("hc command summarizes send wait children and bounded machine states", function()
  local mock, spec = setup()
  local children, machines = {}, {}
  for i = 1, 30 do
    children[i] = { terminal = "t" .. i, reason = "exit", ended = true, signal = 9, from = "node/t2" }
    machines[i] = { name = "node" .. i, state = "unreachable" }
  end
  children[1].from = "secret\nmessage"
  machines[1].state = "unsafe\27state"
  mock.fixtures.send = {
    value = {
      turn = 1,
      wait = { terminal = "t1", reason = "message", ended = false, from = "node/t2", signal = 15, children = children },
    },
  }
  mock.fixtures.list = { value = { terminals = {}, machines = machines } }
  local send = lines(spec.restore({ argv = { "send", "t1", "hi" } }, "send", false, ctx))
  truthy(send:find("Wait: t1 · reason message · ended false · signal 15 · from node/t2", 1, true))
  truthy(send:find("Child: t1 · reason exit · ended true · signal 9", 1, true))
  truthy(send:find("Child: t2 · reason exit · ended true · signal 9 · from node/t2", 1, true))
  truthy(send:find("5 children omitted.", 1, true))
  truthy(not send:find("secret", 1, true))
  local list = lines(spec.restore({ argv = { "ls" } }, "list", false, ctx))
  truthy(list:find("Machine node1\nMachine node2 · unreachable", 1, true))
  truthy(list:find("5 machines omitted.", 1, true))
  truthy(not list:find("unsafe", 1, true))
  eq(#mock.calls, 0)
end)

test("hc command displays bounded sanitized label and update results", function()
  local mock, spec = setup()
  local labels = {}
  for i = 1, 30 do
    labels[string.format("key%02d", i)] = "value " .. i
  end
  labels.key01 = "line\n\27[31m\194\155" .. string.rep("é", 100)
  mock.fixtures.labels = { value = { address = "t1", labels = labels } }
  mock.output = "labels"
  local input = { argv = { "label", "t1", "key01=value" } }
  local result = spec.handler(input, ctx)
  local body = lines(result.body)
  eq(result.llm_output, "labels")
  eq(lines(spec.restore(input, "labels", false, ctx)), body)
  truthy(body:find("Label key01 = line??[31m?", 1, true))
  truthy(body:find("[truncated]", 1, true))
  local label_prefix = body:match("Label key01 = (.-) %[truncated%]")
  eq(label_prefix, "line??[31m?" .. string.rep("é", 58))
  truthy(body:find("Label key02 = value 2", 1, true))
  truthy(body:find("5 labels omitted.", 1, true))
  truthy(not body:find("key26", 1, true))
  truthy(not body:find("\27", 1, true))
  truthy(not body:find("\194\155", 1, true))
  mock.fixtures.empty = { value = { address = "t1", labels = {} } }
  eq(lines(spec.restore(input, "empty", false, ctx)), "Terminal t1\nLabels: [none]")
  mock.fixtures.update_safe = {
    value = { updated = true, restarted = false, now = "hc\n\27" .. string.rep("é", 100), release = "" },
  }
  mock.output = "update_safe"
  local update_input = { argv = { "update" } }
  local update = spec.handler(update_input, ctx)
  local update_body = lines(update.body)
  eq(update.llm_output, "update_safe")
  eq(lines(spec.restore(update_input, "update_safe", false, ctx)), update_body)
  truthy(update_body:find("Update · updated true · restarted false\nNow: hc??", 1, true))
  truthy(update_body:find("[truncated]\nRelease: [empty]", 1, true))
  truthy(not update_body:find("\27", 1, true))
end)

test("hc command falls back for unsupported or malformed result shapes", function()
  local mock, spec = setup()
  local cases = {
    { "read", { "read", "t1" }, { text = "secret", complete = true } },
    { "interrupt", { "interrupt", "t1" }, { outcome = "stopped", key = "bad\27" } },
    { "keys", { "keys", "t1", "enter" }, { turn = -1 } },
    { "put", { "put", "t1", "file" }, { path = "file", bytes = -1 } },
    { "file-read", { "file", "read", "file" }, { text = "", first = 1, last = 1 } },
    { "file-edit", { "file", "edit", "file" }, { bytes = 5 } },
    { "exec", { "exec", "program" }, { stdout = "", stderr = "", ms = 0, timed_out = false } },
    { "status", { "server", "status" }, { pid = 1 } },
    { "stop", { "server", "stop" }, { stopped = "true" } },
    { "start", { "server", "start" }, { stopped = true } },
    { "keep", { "keep", "t1" }, { address = "t1", keep = "true" } },
    { "label-missing", { "label", "t1", "x=y" }, { address = "t1" } },
    { "label-invalid", { "label", "t1", "x=y" }, { address = "t1", labels = { x = false } } },
    { "label-array", { "label", "t1", "x=y" }, { address = "t1", labels = { "x" } } },
    { "machine-rm", { "machine", "rm", "node" }, { name = "node" } },
    { "machine-rm-invalid", { "machine", "rm", "node" }, { removed = "bad\nname" } },
    { "update", { "update" }, { now = "hc 0.1.18", release = "0.1.18", updated = false, restarted = "true" } },
    { "update-missing", { "update" }, { updated = true } },
    { "update-invalid-version", { "update" }, { updated = true, now = false, release = "1.2.3" } },
    { "update-error", { "update" }, { error = "failed", updated = true, now = "1", release = "2" } },
  }
  for _, case in ipairs(cases) do
    mock.fixtures[case[1]] = { value = case[3] }
    eq(lines(spec.restore({ argv = case[2] }, case[1], false, ctx)), case[1])
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
