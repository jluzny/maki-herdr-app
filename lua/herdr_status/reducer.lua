local M = {}
local max_pending = 128
local max_pending_misses = 8

function M.new()
  return { sessions = {}, removed = {}, pending = {}, pending_sequence = 0 }
end

function M.event(state, event, id, reason)
  if type(id) ~= "string" or id == "" then
    return
  end
  if event == "SessionEnd" or event == "SessionReset" then
    state.sessions[id] = nil
    state.pending[id] = nil
    state.removed[id] = true
    return
  end
  if event == "SessionStatusChanged" or event == "SessionFocusChanged" then
    state.removed[id] = nil
    return
  end
  if state.removed[id] then
    return
  end
  local session = state.sessions[id] or state.pending[id]
  if not session then
    if event ~= "TurnStart" then
      return
    end
    local count, oldest_id, oldest_sequence = 0, nil, nil
    for pending_id, pending in pairs(state.pending) do
      count = count + 1
      if not oldest_sequence or pending.sequence < oldest_sequence then
        oldest_id, oldest_sequence = pending_id, pending.sequence
      end
    end
    if count >= max_pending then
      state.pending[oldest_id] = nil
    end
    state.pending_sequence = state.pending_sequence + 1
    session = { sequence = state.pending_sequence, misses = 0 }
    state.pending[id] = session
  end
  if event == "TurnStart" then
    session.turn = true
    session.outcome = nil
  elseif event == "TurnEnd" then
    if session.turn and reason == "finished" then
      session.outcome = "done"
    else
      session.outcome = nil
    end
    session.turn = false
  end
end

function M.reconcile(state, live)
  local seen = {}
  for _, item in ipairs(live) do
    local id = type(item) == "table" and item.id or nil
    if type(id) == "string" and id ~= "" then
      seen[id] = true
      if not state.removed[id] then
        local session = state.sessions[id] or state.pending[id] or {}
        session.status = item.status
        session.sequence = nil
        session.misses = nil
        state.sessions[id] = session
        state.pending[id] = nil
      end
    end
  end
  for id in pairs(state.sessions) do
    if not seen[id] then
      state.sessions[id] = nil
    end
  end
  for id in pairs(state.removed) do
    if not seen[id] then
      state.removed[id] = nil
    end
  end
  for id, session in pairs(state.pending) do
    if not seen[id] then
      session.misses = session.misses + 1
      if session.misses >= max_pending_misses then
        state.pending[id] = nil
      end
    end
  end
end

function M.aggregate(state)
  local working, done, unknown = false, false, false
  for _, session in pairs(state.sessions) do
    if session.status == "needs_input" then
      return "blocked"
    elseif session.status == "working" then
      working = true
    elseif session.status == "idle" then
      if session.outcome == "done" then
        done = true
      end
    else
      unknown = true
    end
  end
  if working then
    return "working"
  elseif done and not unknown then
    return "done"
  end
  return "idle"
end

return M
