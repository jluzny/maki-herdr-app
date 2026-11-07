local reducer = require("herdr_status.reducer")

test("reducer starts idle and ignores invalid or unknown events", function()
  local state = reducer.new()
  eq(reducer.aggregate(state), "idle")
  for _, id in ipairs({ "", 4, false, "missing" }) do
    reducer.event(state, "TurnStart", id)
  end
  reducer.event(state, "SessionEnd", nil)
  eq(next(state.sessions), nil)
  eq(next(state.removed), nil)
end)

test("reducer applies aggregate priority across sessions", function()
  local state = reducer.new()
  reducer.reconcile(
    state,
    { { id = "a", status = "idle" }, { id = "b", status = "working" }, { id = "c", status = "needs_input" } }
  )
  eq(reducer.aggregate(state), "blocked")
  reducer.reconcile(state, { { id = "a", status = "idle" }, { id = "b", status = "working" } })
  eq(reducer.aggregate(state), "working")
  reducer.event(state, "TurnStart", "a")
  reducer.event(state, "TurnEnd", "a", "finished")
  eq(reducer.aggregate(state), "working")
  reducer.reconcile(state, { { id = "a", status = "idle" }, { id = "b", status = "idle" } })
  eq(reducer.aggregate(state), "done")
  reducer.reconcile(state, { { id = "a", status = "idle" }, { id = "b", status = "mystery" } })
  eq(reducer.aggregate(state), "idle")
  reducer.reconcile(state, {})
  eq(reducer.aggregate(state), "idle")
end)

test("reducer only marks a matching finished turn done", function()
  local state = reducer.new()
  reducer.reconcile(state, { { id = "a", status = "idle" } })
  reducer.event(state, "TurnEnd", "a", "finished")
  eq(reducer.aggregate(state), "idle")
  for _, reason in ipairs({ "cancelled", "error", "limit", "dropped" }) do
    reducer.event(state, "TurnStart", "a")
    reducer.event(state, "TurnEnd", "a", reason)
    eq(reducer.aggregate(state), "idle", reason)
  end
  reducer.event(state, "TurnStart", "a")
  reducer.event(state, "TurnEnd", "a", "finished")
  eq(reducer.aggregate(state), "done")
  reducer.event(state, "TurnStart", "a")
  eq(reducer.aggregate(state), "idle")
end)

test("reducer tombstones prevent stale resurrection until disappearance", function()
  for _, event in ipairs({ "SessionEnd", "SessionReset" }) do
    local state = reducer.new()
    reducer.reconcile(state, { { id = "a", status = "working" }, { id = "b", status = "idle" } })
    reducer.event(state, event, "a")
    reducer.event(state, "TurnStart", "a")
    reducer.reconcile(state, { { id = "a", status = "working" }, { id = "b", status = "idle" } })
    eq(reducer.aggregate(state), "idle", event)
    eq(state.sessions.a, nil)
    truthy(state.removed.a)
    reducer.reconcile(state, { { id = "b", status = "idle" } })
    eq(state.removed.a, nil)
    reducer.reconcile(state, { { id = "a", status = "working" } })
    eq(reducer.aggregate(state), "working")
  end
end)

test("reducer retains pending turns across missing snapshots", function()
  local state = reducer.new()
  reducer.reconcile(state, { { id = "other", status = "idle" } })
  reducer.event(state, "TurnStart", "new")
  reducer.reconcile(state, { { id = "other", status = "idle" } })
  reducer.reconcile(state, { { id = "other", status = "idle" } })
  reducer.event(state, "TurnEnd", "new", "finished")
  eq(reducer.aggregate(state), "idle")
  reducer.reconcile(state, { { id = "other", status = "idle" }, { id = "new", status = "idle" } })
  eq(reducer.aggregate(state), "done")
  eq(state.pending.new, nil)
end)

test("reducer bounds and expires pending turns without false completion", function()
  local state = reducer.new()
  for i = 1, 200 do
    reducer.event(state, "TurnStart", tostring(i))
  end
  local count = 0
  for _ in pairs(state.pending) do
    count = count + 1
  end
  truthy(count <= 128)
  eq(state.pending["1"], nil)
  reducer.event(state, "TurnEnd", "1", "finished")
  reducer.reconcile(state, { { id = "1", status = "idle" } })
  eq(reducer.aggregate(state), "idle")
  truthy(state.pending["200"])
  for _ = 1, 8 do
    reducer.reconcile(state, { { id = "1", status = "idle" } })
  end
  eq(next(state.pending), nil)
  reducer.event(state, "TurnEnd", "200", "finished")
  reducer.reconcile(state, { { id = "200", status = "idle" } })
  eq(reducer.aggregate(state), "idle")
end)

test("reducer reopens tombstoned sessions without reviving stale turns", function()
  for _, ending in ipairs({ "SessionEnd", "SessionReset" }) do
    for _, reopening in ipairs({ "SessionStatusChanged", "SessionFocusChanged" }) do
      local state = reducer.new()
      reducer.reconcile(state, { { id = "a", status = "idle" } })
      reducer.event(state, "TurnStart", "a")
      reducer.event(state, ending, "a")
      reducer.event(state, "TurnStart", "a")
      reducer.event(state, reopening, "a")
      reducer.event(state, "TurnEnd", "a", "finished")
      reducer.reconcile(state, { { id = "a", status = "idle" } })
      eq(reducer.aggregate(state), "idle")
      reducer.event(state, "TurnStart", "a")
      reducer.event(state, "TurnEnd", "a", "finished")
      eq(reducer.aggregate(state), "done")
    end
  end
end)

test("reducer ignores malformed snapshot entries", function()
  local state = reducer.new()
  reducer.reconcile(
    state,
    { false, 1, "bad", {}, { id = "", status = "working" }, { id = false }, { id = "valid", status = "idle" } }
  )
  eq(reducer.aggregate(state), "idle")
  truthy(state.sessions.valid)
  eq(state.sessions[""], nil)
end)
