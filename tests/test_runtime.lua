local runtime = require("maki_herdr_app.runtime")
local osc = require("herdr_status.osc")
local mock_host = require("mock_host")

local function status(mock, index, expected)
  local write = mock.writes[index]
  truthy(write, "missing write " .. index)
  eq(write.path, "/dev/tty")
  eq(write.bytes, osc.encode(expected))
end

local function started()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host)
  mock:drain()
  return mock, handle
end

local function resume(co)
  local ok, err = coroutine.resume(co)
  if not ok then
    error(err, 2)
  end
end

local function deferred_spawn(mock)
  local tasks = {}
  mock.host.async = {
    spawn = function(fn)
      local task = { coroutine = coroutine.create(fn) }
      function task:cancel()
        self.cancelled = true
      end
      tasks[#tasks + 1] = task
      return task
    end,
    sleep = function(ms)
      mock.sleep_ms = ms
      coroutine.yield()
    end,
  }
  return tasks
end

test("plugin starts through top-level spawn after load and preserves early events", function()
  local mock = mock_host.new()
  local rules = {}
  mock.host.api.register_permission_rule = function(spec)
    rules[#rules + 1] = spec
  end
  local tasks = deferred_spawn(mock)
  local old_maki = _G.maki
  _G.maki = mock.host
  local ok, err = pcall(dofile, "plugin/herdr.lua")
  _G.maki = old_maki
  if not ok then
    error(err)
  end
  eq(#tasks, 1)
  eq(#mock.hints, 1)
  eq(mock.hints[1].slot, "tool_usage")
  eq(
    mock.hints[1].content,
    "For Herdr Desktop orchestration, use hc. Before coordinating terminals or agents, run the exact bash command hc --skill and read its output. "
      .. "For repeated hc blocked notifications, notify the user once per unresolved prompt; "
      .. "if the prompt changes, inspect it again and notify as needed. Never bypass approvals."
  )
  eq(#rules, 1)
  eq(rules[1].tool, "bash")
  eq(rules[1].scope, "hc --skill")
  eq(rules[1].effect, "allow")
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  mock:event("TurnStart", { session_id = "one", text = "prompt" })
  mock:event("TurnEnd", { session_id = "one", reason = "finished" })
  eq(#mock.queue, 0)
  resume(tasks[1].coroutine)
  eq(coroutine.status(tasks[1].coroutine), "suspended")
  eq(mock.sleep_ms, 1000)
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  mock:event("SessionFocusChanged", { session_id = "one" })
  eq(#mock.queue, 1)
  mock:drain()
  status(mock, 1, "done")
  resume(tasks[1].coroutine)
  eq(#mock.queue, 0)
  eq(mock.live_calls, 1)
end)

test("startup waits for load after an early focus event", function()
  local mock = mock_host.new()
  local tasks = deferred_spawn(mock)
  local handle = runtime.start(mock.host)
  mock:event("SessionFocusChanged", { session_id = "one" })
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  resume(tasks[1].coroutine)
  eq(mock.sleep_ms, nil)
  eq(coroutine.status(tasks[1].coroutine), "dead")
  eq(#mock.queue, 1)
  mock:drain()
  status(mock, 1, "idle")
  handle.close()
end)

test("missed focus event starts bounded retries after the sleep", function()
  local mock = mock_host.new()
  mock.live = {}
  local tasks = deferred_spawn(mock)
  local handle = runtime.start(mock.host, { max_attempts = 3, retry_ms = 17 })
  mock:event("TurnStart", { session_id = "one" })
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  resume(tasks[1].coroutine)
  eq(mock.sleep_ms, 1000)
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  resume(tasks[1].coroutine)
  eq(coroutine.status(tasks[1].coroutine), "dead")
  eq(#mock.queue, 1)
  mock:drain()
  eq(mock.live_calls, 3)
  eq(#mock.writes, 0)
  mock.live = { { id = "one", status = "working", focused = true } }
  mock:event("SessionStatusChanged", { session_id = "one" })
  mock:drain()
  status(mock, 1, "working")
  handle.close()
end)

test("fallback reports a focused snapshot without a focus event", function()
  local mock = mock_host.new()
  local tasks = deferred_spawn(mock)
  local handle = runtime.start(mock.host)
  resume(tasks[1].coroutine)
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  resume(tasks[1].coroutine)
  eq(#mock.queue, 1)
  mock:drain()
  status(mock, 1, "idle")
  mock:event("SessionFocusChanged", { session_id = "one" })
  mock:drain()
  eq(#mock.writes, 1)
  handle.close()
end)

test("teardown during startup sleep prevents delayed work", function()
  for _, mode in ipairs({ "close", "shutdown" }) do
    local mock = mock_host.new()
    local tasks = deferred_spawn(mock)
    local handle = runtime.start(mock.host)
    resume(tasks[1].coroutine)
    if mode == "close" then
      handle.close()
    else
      mock:event("SessionEnd", { reason = "shutdown" })
    end
    truthy(tasks[1].cancelled)
    resume(tasks[1].coroutine)
    mock:drain()
    eq(#mock.queue, 0)
    eq(mock.live_calls, nil)
    eq(#mock.writes, 0)
    eq(#mock.deleted, 1)
    eq(#mock.warnings, 0)
  end
end)

test("sleep failure disables startup without an immediate host callback", function()
  local mock = mock_host.new()
  local tasks = deferred_spawn(mock)
  mock.host.async.sleep = function()
    error("sleep failed")
  end
  runtime.start(mock.host)
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
  resume(tasks[1].coroutine)
  eq(#mock.warnings, 1)
  eq(#mock.deleted, 1)
  eq(#mock.queue, 0)
  eq(mock.live_calls, nil)
end)

test("spawn failure or teardown before spawn leaves no reporter", function()
  for _, mode in ipairs({ "throw", "nil", "close", "shutdown" }) do
    local mock = mock_host.new()
    local tasks = deferred_spawn(mock)
    if mode == "throw" then
      mock.host.async.spawn = function()
        error("spawn denied")
      end
    end
    if mode == "nil" then
      mock.host.async.spawn = function()
        return nil
      end
    end
    local handle = runtime.start(mock.host)
    if mode == "close" then
      handle.close()
    end
    if mode == "shutdown" then
      mock:event("SessionEnd", { session_id = "one", reason = "shutdown", deadline_ms = 20 })
    end
    if tasks[1] then
      truthy(tasks[1].cancelled, mode)
      resume(tasks[1].coroutine)
    end
    mock:drain()
    eq(#mock.writes, 0, mode)
    eq(#mock.queue, 0, mode)
    eq(#mock.deleted, 1, mode)
    eq(#mock.warnings, (mode == "throw" or mode == "nil") and 1 or 0, mode)
  end
end)

test("runtime requires both Herdr environment variables", function()
  for _, key in ipairs({ "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET" }) do
    for _, value in ipairs({ "", false, 12 }) do
      local mock = mock_host.new()
      mock.env[key] = value
      local handle = runtime.start(mock.host)
      mock:drain()
      handle.close()
      eq(#mock.registrations, 0)
      eq(#mock.writes, 0)
    end
    local mock = mock_host.new()
    mock.env[key] = nil
    runtime.start(mock.host)
    eq(#mock.registrations, 0)
  end
  local mock = mock_host.new()
  mock.env_error = "permission denied"
  runtime.start(mock.host)
  eq(#mock.registrations, 0)
  eq(#mock.writes, 0)
end)

test("runtime registers expected events and coalesces updates", function()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host)
  eq(
    table.concat(mock.registrations[1], ","),
    "TurnStart,TurnEnd,SessionStatusChanged,SessionFocusChanged,SessionReset,SessionEnd"
  )
  eq(#mock.queue, 1)
  mock:event("SessionStatusChanged", {})
  mock:event("SessionFocusChanged", {})
  eq(#mock.queue, 1)
  mock:drain()
  eq(mock.live_calls, 1)
  status(mock, 1, "idle")
  mock:event("SessionStatusChanged", {})
  mock:drain()
  eq(#mock.writes, 1)
  handle.close()
  status(mock, 2, "clear")
  eq(mock.deleted[1], 42)
  handle.close()
  eq(#mock.writes, 2)
  eq(#mock.deleted, 1)
end)

test("runtime retries unattached sessions without writing", function()
  local mock = mock_host.new()
  mock.live = {}
  local handle = runtime.start(mock.host, { max_attempts = 3, retry_ms = 17 })
  mock:step()
  eq(mock.queue[1].delay, 17)
  mock:step()
  mock.live = { { id = "one", status = "working", focused = true } }
  mock:step()
  status(mock, 1, "working")
  eq(mock.live_calls, 3)
  handle.close()
  status(mock, 2, "clear")
end)

test("runtime waits for an event after bounded unattached retries", function()
  local mock = mock_host.new()
  mock.live = { { id = "one", status = "working", focused = false }, { id = "", focused = true } }
  local handle = runtime.start(mock.host, { max_attempts = 3, retry_ms = 1 })
  mock:drain()
  eq(mock.live_calls, 3)
  eq(#mock.writes, 0)
  eq(#mock.deleted, 0)
  eq(#mock.warnings, 0)
  mock.live = { { id = "one", status = "working", focused = true } }
  mock:event("SessionFocusChanged", { session_id = "one" })
  mock:drain()
  eq(mock.live_calls, 4)
  status(mock, 1, "working")
  handle.close()
end)

test("runtime aggregates all tabs and completed turns", function()
  local mock, handle = started()
  mock.live = { { id = "one", status = "idle", focused = true }, { id = "two", status = "working" } }
  mock:event("SessionStatusChanged", { session_id = "two" })
  mock:drain()
  status(mock, 2, "working")
  mock.live[1].status = "needs_input"
  mock:event("SessionStatusChanged", {})
  mock:drain()
  status(mock, 3, "blocked")
  mock.live[1].status = "idle"
  mock.live[2].status = "idle"
  mock:event("TurnStart", { session_id = "one" })
  mock:event("TurnEnd", { session_id = "one", reason = "finished" })
  mock:drain()
  status(mock, 4, "done")
  mock:event("TurnStart", { session_id = "one" })
  mock:drain()
  status(mock, 5, "idle")
  handle.close()
end)

test("runtime resets or removes a tab without clearing other tabs", function()
  for _, event in ipairs({ "SessionEnd", "SessionReset" }) do
    local mock = mock_host.new()
    mock.live = { { id = "one", status = "idle", focused = true }, { id = "two", status = "working" } }
    local handle = runtime.start(mock.host)
    mock:drain()
    status(mock, 1, "working")
    mock:event(event, { session_id = "two", reason = "deleted" })
    mock:drain()
    status(mock, 2, "idle")
    eq(#mock.deleted, 0)
    handle.close()
  end
end)

test("runtime teardown reasons cancel timers and clear once", function()
  for _, reason in ipairs({ "shutdown", "reload", "replaced", "completed" }) do
    local mock = mock_host.new()
    runtime.start(mock.host)
    local callback = mock.callback
    mock:drain()
    mock:event("SessionStatusChanged", {})
    local pending = mock.queue[1]
    mock:event("SessionEnd", { reason = reason })
    truthy(pending.stopped)
    status(mock, 2, "clear")
    eq(#mock.deleted, 1)
    callback({ event = "SessionStatusChanged", data = {} })
    mock:drain()
    eq(#mock.writes, 2)
  end
end)

test("runtime close before first update does not clear", function()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host)
  local timer = mock.queue[1]
  handle.close()
  truthy(timer.stopped)
  mock:drain()
  eq(#mock.writes, 0)
  eq(#mock.deleted, 1)
end)

test("runtime recovers from a transient missing interactive session", function()
  local mock, handle = started()
  mock.live = {}
  mock:event("SessionFocusChanged", {})
  mock:step()
  eq(#mock.writes, 1)
  eq(#mock.deleted, 0)
  mock.live = { { id = "one", status = "working", focused = true } }
  mock:step()
  status(mock, 2, "working")
  handle.close()
end)

test("runtime handles permission failures and absent tty", function()
  for _, mode in ipairs({ "throw", "false", "nil", "error" }) do
    local mock = mock_host.new()
    if mode == "throw" then
      mock.write_error = "no tty"
    end
    if mode == "false" then
      mock.write_result = false
    end
    if mode == "nil" then
      mock.write_nil = true
    end
    if mode == "error" then
      mock.write_result, mock.write_err = true, "permission denied"
    end
    runtime.start(mock.host)
    mock:drain()
    eq(#mock.writes, 1)
    eq(#mock.deleted, 1)
    eq(#mock.warnings, 1)
    mock:event("SessionStatusChanged", {})
    mock:drain()
    eq(#mock.writes, 1)
  end
end)

test("runtime clears after a later write failure", function()
  local mock = started()
  mock.live[1].status = "working"
  mock.write_result = false
  mock:event("SessionStatusChanged", {})
  mock:drain()
  status(mock, 2, "working")
  status(mock, 3, "clear")
  eq(#mock.deleted, 1)
  eq(#mock.warnings, 2)
end)

test("runtime handles registration and scheduling errors", function()
  for _, field in ipairs({ "register_error", "register_false", "defer_error", "defer_false" }) do
    local mock = mock_host.new()
    mock[field] = true
    runtime.start(mock.host)
    mock:drain()
    eq(#mock.writes, 0, field)
    eq(#mock.warnings, 1, field)
    eq(#mock.deleted, field:match("defer") and 1 or 0, field)
  end
end)

test("runtime retries transient live errors before and after readiness", function()
  local mock = mock_host.new()
  mock.live_error = "private error"
  local handle = runtime.start(mock.host, { max_attempts = 2 })
  mock:step()
  mock.live_error = nil
  mock:step()
  status(mock, 1, "idle")
  mock.live_err = "failed"
  mock:event("SessionStatusChanged", {})
  mock:step()
  eq(#mock.writes, 1)
  eq(#mock.deleted, 0)
  mock.live_err = nil
  mock.live[1].status = "working"
  mock:step()
  status(mock, 2, "working")
  handle.close()
end)

test("runtime bounds live failures and resumes on later events", function()
  for _, ready in ipairs({ false, true }) do
    local mock = mock_host.new()
    local handle = runtime.start(mock.host, { max_attempts = 2, retry_ms = 7 })
    if ready then
      mock:drain()
      status(mock, 1, "idle")
    end
    mock.live_error = "private error"
    if ready then
      mock:event("SessionStatusChanged", {})
    end
    local before = mock.live_calls or 0
    mock:drain()
    eq(mock.live_calls, before + 2)
    eq(#mock.queue, 0)
    eq(#mock.deleted, 0)
    eq(#mock.warnings, 1)
    eq(mock.warnings[1], "herdr: interactive session unavailable; waiting for next event")
    eq(#mock.writes, ready and 2 or 0)
    if ready then
      status(mock, 2, "clear")
    end
    mock:event("SessionStatusChanged", {})
    mock:drain()
    eq(mock.live_calls, before + 4)
    eq(#mock.warnings, 2)
    mock.live_error = nil
    mock.live[1].status = "working"
    mock:event("SessionStatusChanged", {})
    mock:drain()
    status(mock, ready and 3 or 1, "working")
    handle.close()
    status(mock, ready and 4 or 2, "clear")
  end
end)

test("exhaustion clears once and re-emits the same recovered status", function()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host, { max_attempts = 2 })
  mock:drain()
  status(mock, 1, "idle")
  mock.live = {}
  mock:event("SessionFocusChanged", {})
  mock:step()
  eq(#mock.writes, 1)
  mock:step()
  status(mock, 2, "clear")
  eq(#mock.queue, 0)
  mock:event("SessionStatusChanged", {})
  mock:drain()
  eq(#mock.writes, 2)
  mock.live = { { id = "one", status = "idle", focused = true } }
  mock:event("SessionFocusChanged", {})
  mock:drain()
  status(mock, 3, "idle")
  handle.close()
  status(mock, 4, "clear")
end)

test("failed exhaustion clear is best effort and recovery re-emits", function()
  for _, failure in ipairs({ "throw", "false", "nil", "error" }) do
    local mock = mock_host.new()
    local handle = runtime.start(mock.host, { max_attempts = 1 })
    mock:drain()
    mock.live = {}
    if failure == "throw" then
      mock.write_error = "private"
    elseif failure == "false" then
      mock.write_result = false
    elseif failure == "nil" then
      mock.write_nil = true
    else
      mock.write_result, mock.write_err = true, "private"
    end
    mock:event("SessionStatusChanged", {})
    mock:drain()
    status(mock, 2, "clear")
    eq(#mock.committed, 1)
    eq(#mock.deleted, 0)
    eq(mock.warnings[2], "herdr: could not clear terminal status")
    mock.write_error, mock.write_result, mock.write_nil, mock.write_err = nil, nil, nil, nil
    mock:event("SessionStatusChanged", {})
    mock:drain()
    eq(#mock.writes, 2)
    mock.live = { { id = "one", status = "idle", focused = true } }
    mock:event("SessionFocusChanged", {})
    mock:drain()
    status(mock, 3, "idle")
    handle.close()
  end
end)

test("exhaustion waits for an in-flight status write", function()
  for _, initial in ipairs({ false, true }) do
    local mock = mock_host.new()
    local handle = runtime.start(mock.host, { max_attempts = 1 })
    if not initial then
      mock:drain()
      mock.live[1].status = "working"
      mock:event("SessionStatusChanged", {})
    end
    local pending = true
    mock.on_write = function()
      if pending then
        pending = false
        coroutine.yield("status pending")
      end
    end
    local worker = coroutine.create(function()
      mock:step()
    end)
    resume(worker)
    local before = #mock.writes
    mock.live = {}
    mock:event("SessionFocusChanged", {})
    eq(#mock.queue, 0)
    eq(#mock.writes, before)
    resume(worker)
    eq(#mock.queue, 1)
    mock:drain()
    status(mock, before + 1, "clear")
    eq(mock.committed[before + 1], osc.encode("clear"))
    handle.close()
    eq(#mock.writes, before + 1)
  end
end)

test("exhaustion clear serializes events and teardown", function()
  for _, close in ipairs({ false, true }) do
    local mock = mock_host.new()
    local handle = runtime.start(mock.host, { max_attempts = 1 })
    mock:drain()
    mock.live = {}
    mock.on_write = function(_, _, bytes)
      if bytes == osc.encode("clear") then
        coroutine.yield("clear pending")
      end
    end
    mock:event("SessionStatusChanged", {})
    local worker = coroutine.create(function()
      mock:step()
    end)
    resume(worker)
    status(mock, 2, "clear")
    eq(#mock.committed, 1)
    mock.live = { { id = "one", status = "idle", focused = true } }
    mock:event("SessionFocusChanged", {})
    eq(#mock.queue, 0)
    if close then
      handle.close()
    end
    eq(#mock.writes, 2)
    resume(worker)
    eq(coroutine.status(worker), "dead")
    eq(mock.committed[2], osc.encode("clear"))
    mock.on_write = nil
    mock:drain()
    eq(#mock.writes, close and 2 or 3)
    if not close then
      status(mock, 3, "idle")
      handle.close()
    end
  end
end)

test("runtime closes safely after retry exhaustion", function()
  for _, ready in ipairs({ false, true }) do
    for _, failure in ipairs({ "missing", "malformed", "error" }) do
      local mock = mock_host.new()
      local handle = runtime.start(mock.host, { max_attempts = 1 })
      if ready then
        mock:drain()
        mock:event("SessionFocusChanged", {})
      end
      if failure == "missing" then
        mock.live = {}
      elseif failure == "malformed" then
        mock.live = false
      else
        mock.live_err = "private details"
      end
      mock:drain()
      eq(mock.live_calls, ready and 2 or 1)
      eq(#mock.queue, 0)
      eq(#mock.deleted, 0)
      eq(#mock.warnings, (ready or failure ~= "missing") and 1 or 0)
      eq(#mock.writes, ready and 2 or 0)
      if ready then
        status(mock, 2, "clear")
      end
      handle.close()
      eq(#mock.deleted, 1)
      eq(#mock.writes, ready and 2 or 0)
      if ready then
        status(mock, 2, "clear")
      end
      mock:event("SessionFocusChanged", {})
      mock:drain()
      eq(mock.live_calls, ready and 2 or 1)
    end
  end
end)

test("runtime isolates warning and cleanup errors", function()
  local mock = started()
  mock.log_error = true
  mock.delete_error = true
  mock.write_error = "denied"
  mock.live[1].status = "working"
  mock:event("SessionFocusChanged", {})
  mock:drain()
  eq(#mock.deleted, 1)
  eq(#mock.writes, 3)
end)

test("runtime records a turn that starts before the first snapshot", function()
  local mock = mock_host.new()
  runtime.start(mock.host)
  mock:event("TurnStart", { session_id = "one" })
  mock:drain()
  mock:event("TurnEnd", { session_id = "one", reason = "finished" })
  mock:drain()
  status(mock, 1, "idle")
  status(mock, 2, "done")
end)

test("runtime preserves a new tab turn across a snapshot before it appears", function()
  local mock, handle = started()
  mock:event("TurnStart", { session_id = "two" })
  mock:drain()
  mock:event("TurnEnd", { session_id = "two", reason = "finished" })
  mock:drain()
  eq(#mock.writes, 1)
  mock.live[2] = { id = "two", status = "idle" }
  mock:event("SessionStatusChanged", { session_id = "two" })
  mock:drain()
  status(mock, 2, "done")
  handle.close()
end)

test("runtime discards stale snapshots when an event arrives during live", function()
  local mock = started()
  local first = true
  mock.on_live = function(self)
    if first then
      first = false
      self.live = { { id = "one", focused = true, status = "needs_input" } }
      self:event("SessionStatusChanged", {})
      return { { id = "one", focused = true, status = "working" } }
    end
    return self.live
  end
  mock:event("SessionStatusChanged", {})
  mock:drain()
  eq(#mock.writes, 2)
  status(mock, 2, "blocked")
end)

test("runtime reschedules an event arriving during a write", function()
  local mock = started()
  local first = true
  mock.on_write = function(self)
    if first then
      first = false
      self.live[1].status = "needs_input"
      self:event("SessionStatusChanged", {})
    end
  end
  mock.live[1].status = "working"
  mock:event("SessionStatusChanged", {})
  mock:drain()
  status(mock, 2, "working")
  status(mock, 3, "blocked")
end)

test("runtime ignores a live result after close", function()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host)
  mock.on_live = function(self)
    handle.close()
    return self.live
  end
  mock:drain()
  eq(#mock.writes, 0)
  eq(#mock.deleted, 1)
end)

test("runtime clears if closed during its first successful write", function()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host)
  local first = true
  mock.on_write = function()
    if first then
      first = false
      handle.close()
    end
  end
  mock:drain()
  status(mock, 1, "idle")
  status(mock, 2, "clear")
  eq(#mock.deleted, 1)
end)

test("runtime leaves clear as final output when closed during a later write", function()
  local mock, handle = started()
  local first = true
  mock.on_write = function()
    if first then
      first = false
      handle.close()
    end
  end
  mock.live[1].status = "working"
  mock:event("SessionStatusChanged", {})
  mock:drain()
  eq(mock.committed[#mock.committed], osc.encode("clear"))
end)

test("runtime restores a reopened session from status or focus events", function()
  for _, event in ipairs({ "SessionStatusChanged", "SessionFocusChanged" }) do
    local mock = mock_host.new()
    mock.live = { { id = "one", status = "idle", focused = true }, { id = "two", status = "working", focused = false } }
    local handle = runtime.start(mock.host)
    mock:drain()
    status(mock, 1, "working")
    mock:event("SessionEnd", { session_id = "two", reason = "delete" })
    mock:drain()
    status(mock, 2, "idle")
    mock:event("TurnStart", { session_id = "two", text = "stale" })
    mock:event(event, { session_id = "two", status = "working", focused = false, previous_session_id = "one" })
    mock:drain()
    status(mock, 3, "working")
    mock.live[2].status = "idle"
    mock:event("TurnEnd", { session_id = "two", reason = "finished" })
    mock:drain()
    status(mock, 4, "idle")
    handle.close()
  end
end)

test("teardown awaits a suspended status write in the callback before clearing once", function()
  for _, first_write in ipairs({ true, false }) do
    for _, reason in ipairs({ "reload", "shutdown", "replaced", "completed" }) do
      local mock = mock_host.new()
      runtime.start(mock.host)
      if not first_write then
        mock:drain()
      end
      local inflight = false
      mock.on_write = function(_, _, bytes)
        if bytes ~= osc.encode("clear") then
          inflight = true
          coroutine.yield("write pending")
          inflight = false
        else
          eq(inflight, false)
        end
      end
      if not first_write then
        mock.live[1].status = "working"
        mock:event("SessionStatusChanged", { session_id = "one" })
      end
      local worker = coroutine.create(function()
        mock:step()
      end)
      resume(worker)
      local before = #mock.committed
      local sleeps = 0
      mock.host.async = {
        sleep = function(ms)
          eq(ms, 1)
          sleeps = sleeps + 1
          coroutine.yield("poll")
        end,
      }
      local callback = coroutine.create(function()
        mock:event("SessionEnd", { reason = reason, deadline_ms = 200 })
      end)
      resume(callback)
      eq(coroutine.status(callback), "suspended")
      eq(#mock.deleted, 1)
      mock:event("SessionStatusChanged", {})
      eq(#mock.committed, before)
      resume(worker)
      eq(coroutine.status(worker), "dead")
      eq(#mock.committed, before + 1)
      resume(callback)
      eq(coroutine.status(callback), "dead")
      eq(sleeps, 1)
      eq(mock.committed[before + 1], osc.encode(first_write and "idle" or "working"))
      eq(mock.committed[before + 2], osc.encode("clear"))
      mock:drain()
      eq(#mock.committed, before + 2)
    end
  end
end)

test("teardown declines uncertain budgets and never clears a late status write", function()
  for _, deadline in ipairs({ 0, 50, 100, -1, math.huge, "200", false }) do
    local mock = mock_host.new()
    local handle = runtime.start(mock.host)
    mock.on_write = function(_, _, bytes)
      if bytes ~= osc.encode("clear") then
        coroutine.yield()
      end
    end
    local worker = coroutine.create(function()
      mock:step()
    end)
    resume(worker)
    local sleeps = 0
    mock.host.async = {
      sleep = function()
        sleeps = sleeps + 1
      end,
    }
    mock:event("SessionEnd", { reason = "reload", deadline_ms = deadline })
    eq(sleeps, 0)
    eq(#mock.writes, 1)
    resume(worker)
    handle.close()
    mock:drain()
    eq(#mock.writes, 1)
    eq(#mock.committed, 1)
  end
end)

test("teardown bounds a never completing write and does not clear on late completion", function()
  local mock = mock_host.new()
  local handle = runtime.start(mock.host)
  mock.on_write = function(_, _, bytes)
    if bytes ~= osc.encode("clear") then
      coroutine.yield()
    end
  end
  local worker = coroutine.create(function()
    mock:step()
  end)
  resume(worker)
  local sleeps = 0
  mock.host.async = {
    sleep = function(ms)
      eq(ms, 1)
      sleeps = sleeps + 1
      coroutine.yield()
    end,
  }
  local callback = coroutine.create(function()
    mock:event("SessionEnd", { reason = "shutdown", deadline_ms = 10000 })
  end)
  for _ = 1, 20 do
    resume(callback)
    eq(coroutine.status(callback), "suspended")
    eq(#mock.writes, 1)
  end
  resume(callback)
  eq(coroutine.status(callback), "dead")
  eq(sleeps, 20)
  eq(#mock.writes, 1)
  eq(coroutine.status(worker), "suspended")
  resume(worker)
  handle.close()
  mock:drain()
  eq(#mock.writes, 1)
  eq(#mock.committed, 1)
end)

test("teardown stops waiting on sleep failure or without a sleep API", function()
  for _, mode in ipairs({ "failure", "missing" }) do
    local mock = mock_host.new()
    runtime.start(mock.host)
    mock.on_write = function()
      coroutine.yield()
    end
    local worker = coroutine.create(function()
      mock:step()
    end)
    resume(worker)
    local sleeps = 0
    if mode == "failure" then
      mock.host.async = {
        sleep = function()
          sleeps = sleeps + 1
          error("sleep failed")
        end,
      }
    end
    mock:event("SessionEnd", { reason = "reload", deadline_ms = 200 })
    eq(sleeps, mode == "failure" and 1 or 0)
    resume(worker)
    eq(#mock.writes, 1)
  end
end)

test("teardown scales the poll budget and cannot serialize a new generation", function()
  local mock = mock_host.new()
  runtime.start(mock.host)
  local old_pending = true
  mock.on_write = function(_, _, bytes)
    if old_pending and bytes ~= osc.encode("clear") then
      old_pending = false
      coroutine.yield()
    end
  end
  local worker = coroutine.create(function()
    mock:step()
  end)
  resume(worker)
  local sleeps = 0
  mock.host.async = {
    sleep = function()
      sleeps = sleeps + 1
    end,
  }
  mock:event("SessionEnd", { reason = "reload", deadline_ms = 112 })
  eq(sleeps, 3)
  mock.host.async = nil
  local handle = runtime.start(mock.host)
  mock:drain()
  eq(#mock.committed, 1)
  resume(worker)
  eq(#mock.writes, 2)
  eq(#mock.committed, 2)
  handle.close()
  status(mock, 3, "clear")
end)

test("teardown waits for an existing clear but does not clear twice", function()
  local mock = mock_host.new()
  runtime.start(mock.host, { max_attempts = 1 })
  mock:drain()
  mock.live = {}
  mock.on_write = function(_, _, bytes)
    if bytes == osc.encode("clear") then
      coroutine.yield()
    end
  end
  mock:event("SessionStatusChanged", {})
  local worker = coroutine.create(function()
    mock:step()
  end)
  resume(worker)
  mock.host.async = {
    sleep = function()
      coroutine.yield()
    end,
  }
  local callback = coroutine.create(function()
    mock:event("SessionEnd", { reason = "reload", deadline_ms = 200 })
  end)
  resume(callback)
  eq(coroutine.status(callback), "suspended")
  resume(worker)
  resume(callback)
  eq(coroutine.status(callback), "dead")
  eq(coroutine.status(worker), "dead")
  eq(#mock.writes, 2)
  eq(mock.committed[2], osc.encode("clear"))
end)

test("events during a suspended live snapshot discard it and coalesce", function()
  local mock = started()
  local calls = 0
  mock.on_live = function(self)
    calls = calls + 1
    if calls == 1 then
      coroutine.yield("snapshot pending")
      return { { id = "one", status = "working", focused = true } }
    end
    return self.live
  end
  mock:event("SessionStatusChanged", { session_id = "one", status = "working", focused = true })
  local worker = coroutine.create(function()
    mock:step()
  end)
  resume(worker)
  mock.live[1].status = "needs_input"
  mock:event("SessionStatusChanged", { session_id = "one", status = "needs_input", focused = true })
  mock:event("SessionFocusChanged", { session_id = "one" })
  eq(#mock.queue, 0)
  resume(worker)
  eq(#mock.queue, 1)
  mock:drain()
  eq(calls, 2)
  eq(#mock.writes, 2)
  status(mock, 2, "blocked")
end)

test("event during suspended write schedules latest snapshot after commit", function()
  local mock = started()
  local pending = true
  mock.on_write = function()
    if pending then
      pending = false
      coroutine.yield("write pending")
    end
  end
  mock.live[1].status = "working"
  mock:event("SessionStatusChanged", { session_id = "one", status = "working", focused = true })
  local worker = coroutine.create(function()
    mock:step()
  end)
  resume(worker)
  mock.live[1].status = "needs_input"
  mock:event("SessionStatusChanged", { session_id = "one", status = "needs_input", focused = true })
  eq(#mock.queue, 0)
  resume(worker)
  eq(#mock.queue, 1)
  mock:drain()
  eq(mock.committed[2], osc.encode("working"))
  eq(mock.committed[3], osc.encode("blocked"))
end)

test("permission denials follow Maki's raised-error contract", function()
  local denied = "permission denied: 'fs_write' not granted for this plugin"
  local mock = mock_host.new()
  mock.write_error = denied
  runtime.start(mock.host)
  mock:drain()
  eq(#mock.writes, 1)
  eq(#mock.committed, 0)
  eq(#mock.deleted, 1)
  eq(#mock.warnings, 1)
  eq(mock.warnings[1]:find(denied, 1, true), nil)

  mock = mock_host.new()
  mock.env_error = "permission denied: 'env' not granted for this plugin"
  runtime.start(mock.host)
  mock:drain()
  eq(#mock.registrations, 0)
  eq(#mock.writes, 0)
end)

test("runtime never emits session content or host error details", function()
  local secret = "SECRET_PROMPT_TOKEN_PATH_TITLE"
  local mock = mock_host.new()
  mock.live = { { id = secret, status = "idle", focused = true, title = secret, prompt = secret, path = secret } }
  local handle = runtime.start(mock.host)
  mock:drain()
  mock:event("TurnStart", { session_id = secret, prompt = secret })
  mock:event("TurnEnd", { session_id = secret, reason = "finished", answer = secret })
  mock:drain()
  mock.live_error = secret
  mock:event("SessionStatusChanged", { session_id = secret })
  mock:drain()
  handle.close()
  for _, write in ipairs(mock.writes) do
    eq(write.path, "/dev/tty")
    eq(write.bytes:find(secret, 1, true), nil)
    truthy(write.bytes == osc.encode("idle") or write.bytes == osc.encode("done") or write.bytes == osc.encode("clear"))
  end
  for _, warning in ipairs(mock.warnings) do
    eq(warning:find(secret, 1, true), nil)
  end
end)
