local reducer = require("herdr_status.reducer")
local osc = require("herdr_status.osc")

local M = {}

local events = {
  "TurnStart",
  "TurnEnd",
  "SessionStatusChanged",
  "SessionFocusChanged",
  "SessionReset",
  "SessionEnd",
}

local teardown = {
  shutdown = true,
  reload = true,
  replaced = true,
  completed = true,
}

function M.start(host, opts)
  opts = opts or {}
  local state = reducer.new()
  local active = true
  local ready = false
  local emitted = false
  local writing = false
  local clear_pending = false
  local starting = type(host.async) == "table" and type(host.async.spawn) == "function"
  local loaded = not starting
  local focused = false
  local last
  local timer
  local startup_task
  local listener
  local running = false
  local revision = 0
  local attempts = 0
  local max_attempts = opts.max_attempts or 20
  local retry_ms = opts.retry_ms or 100
  local schedule

  local function warn(message)
    pcall(function()
      host.log.warn("herdr: " .. message)
    end)
  end

  local function clear_status()
    emitted = false
    last = nil
    writing = "clear"
    local ok, result, err = pcall(host.fs.append, "/dev/tty", osc.encode("clear"))
    writing = false
    if not ok or not result or err then
      warn("could not clear terminal status")
    end
  end

  local function stop(clear)
    if not active then
      return
    end
    active = false
    if startup_task then
      pcall(function()
        startup_task:cancel()
      end)
      startup_task = nil
    end
    if timer then
      pcall(function()
        timer:stop()
      end)
      timer = nil
    end
    if listener then
      pcall(host.api.del_autocmd, listener)
      listener = nil
    end
    if clear then
      if writing == "status" then
        clear_pending = true
      elseif not writing and emitted then
        clear_status()
      end
    end
  end

  local function emit(status)
    if not active or status == last then
      return
    end
    local bytes = osc.encode(status)
    if not bytes then
      return
    end
    writing = "status"
    local ok, result, err = pcall(host.fs.append, "/dev/tty", bytes)
    writing = false
    if not active then
      if clear_pending then
        clear_pending = false
        clear_status()
      end
      return
    end
    if not ok or not result or err then
      warn("terminal status write failed; reporter disabled")
      stop(true)
      return
    end
    last = status
    emitted = true
  end

  local function update()
    timer = nil
    if not active or running then
      return
    end
    running = true
    local version = revision
    local ok, live, err = pcall(host.session.live)
    if not active then
      running = false
      return
    end
    if version ~= revision then
      running = false
      schedule(0)
      return
    end
    local attached = false
    if ok and not err and type(live) == "table" then
      for _, session in ipairs(live) do
        if
          type(session) == "table"
          and session.focused == true
          and type(session.id) == "string"
          and session.id ~= ""
        then
          attached = true
          break
        end
      end
    end
    if not attached then
      attempts = attempts + 1
      if attempts < max_attempts then
        running = false
        schedule(retry_ms)
      else
        if ready or not ok or err or type(live) ~= "table" then
          warn("interactive session unavailable; waiting for next event")
        end
        if emitted then
          clear_status()
        end
        running = false
        if active and version ~= revision then
          schedule(0)
        end
      end
      return
    end
    attempts = 0
    ready = true
    reducer.reconcile(state, live)
    emit(reducer.aggregate(state))
    running = false
    if active and version ~= revision then
      schedule(0)
    end
  end

  schedule = function(delay)
    if not active or starting or timer or running then
      return
    end
    local ok, handle = pcall(host.defer_fn, function()
      local success = pcall(update)
      if not success then
        warn("status update failed; reporter disabled")
        stop(true)
      end
    end, delay)
    if ok and handle then
      timer = handle
    else
      warn("could not schedule status update")
      stop(true)
    end
  end

  local function teardown_stop(deadline_ms)
    local pending = writing
    stop(false)
    if pending then
      if
        type(deadline_ms) ~= "number"
        or deadline_ms ~= deadline_ms
        or deadline_ms == math.huge
        or deadline_ms <= 100
        or type(host.async) ~= "table"
        or type(host.async.sleep) ~= "function"
      then
        return
      end
      local budget = math.min(20, math.floor((deadline_ms - 100) / 4))
      for _ = 1, budget do
        if not writing then
          break
        end
        local ok = pcall(host.async.sleep, 1)
        if not ok then
          return
        end
      end
      if writing then
        return
      end
    end
    if pending == "status" or (not pending and emitted) then
      clear_status()
    end
  end

  local function on_event(ev)
    if not active or type(ev) ~= "table" then
      return
    end
    local data = type(ev.data) == "table" and ev.data or {}
    if ev.event == "SessionEnd" and teardown[data.reason] then
      teardown_stop(data.deadline_ms)
      return
    end
    if
      ev.event == "TurnStart"
      or ev.event == "TurnEnd"
      or ev.event == "SessionEnd"
      or ev.event == "SessionReset"
      or ev.event == "SessionStatusChanged"
      or ev.event == "SessionFocusChanged"
    then
      reducer.event(state, ev.event, data.session_id, data.reason)
    end
    revision = revision + 1
    attempts = 0
    if ev.event == "SessionFocusChanged" then
      focused = true
    end
    if loaded and focused then
      starting = false
    end
    schedule(0)
  end

  local ok, terminal_id = pcall(host.uv.os_getenv, "HC_TERMINAL_ID")
  local socket_ok, socket = pcall(host.uv.os_getenv, "HC_TERMINAL_SOCKET")
  if
    not ok
    or not socket_ok
    or type(terminal_id) ~= "string"
    or terminal_id == ""
    or type(socket) ~= "string"
    or socket == ""
  then
    stop(false)
    return {
      close = function()
        stop(true)
      end,
    }
  end
  local registered, id = pcall(host.api.create_autocmd, events, {
    callback = function(ev)
      local success = pcall(on_event, ev)
      if not success then
        warn("event handling failed; reporter disabled")
        stop(true)
      end
    end,
  })
  if not registered or not id then
    warn("could not register event handler")
    stop(false)
  else
    listener = id
    if starting then
      local spawned, task = pcall(host.async.spawn, function()
        if not active then
          return
        end
        loaded = true
        if not focused then
          local slept = pcall(host.async.sleep, 1000)
          if not active then
            return
          end
          if not slept then
            startup_task = nil
            warn("could not start status reporter")
            stop(false)
            return
          end
        end
        startup_task = nil
        if starting then
          starting = false
          schedule(0)
        end
      end)
      if not spawned or not task then
        warn("could not start status reporter")
        stop(false)
      else
        startup_task = task
      end
    else
      schedule(0)
    end
  end
  return {
    close = function()
      stop(true)
    end,
  }
end

return M
