local M = {}

function M.new()
  local mock = {
    env = { HC_TERMINAL_ID = "terminal", HC_TERMINAL_SOCKET = "socket" },
    live = { { id = "one", status = "idle", focused = true } },
    queue = {},
    writes = {},
    committed = {},
    warnings = {},
    registrations = {},
    deleted = {},
    calls = {},
  }
  local host = {}
  mock.host = host
  host.uv = {
    os_getenv = function(name)
      mock.calls[#mock.calls + 1] = "env:" .. name
      if mock.env_error then
        error(mock.env_error)
      end
      return mock.env[name]
    end,
  }
  host.log = {
    warn = function(message)
      if mock.log_error then
        error("log denied")
      end
      mock.warnings[#mock.warnings + 1] = message
    end,
  }
  host.fs = {
    append = function(path, bytes)
      mock.writes[#mock.writes + 1] = { path = path, bytes = bytes }
      if mock.on_write then
        mock.on_write(mock, path, bytes)
      end
      if mock.write_error then
        error(mock.write_error)
      end
      if mock.write_nil then
        return nil, mock.write_err
      end
      if mock.write_result == false or mock.write_err then
        return mock.write_result, mock.write_err
      end
      mock.committed[#mock.committed + 1] = bytes
      return true
    end,
  }
  host.session = {
    live = function()
      mock.live_calls = (mock.live_calls or 0) + 1
      if mock.on_live then
        return mock.on_live(mock)
      end
      if mock.live_error then
        error(mock.live_error)
      end
      return mock.live, mock.live_err
    end,
  }
  host.api = {
    register_prompt_hint = function(spec)
      mock.hints = mock.hints or {}
      mock.hints[#mock.hints + 1] = spec
    end,
    create_autocmd = function(events, opts)
      mock.registrations[#mock.registrations + 1] = events
      if mock.register_error then
        error(mock.register_error)
      end
      if mock.register_false then
        return nil
      end
      mock.callback = opts.callback
      return 42
    end,
    del_autocmd = function(id)
      mock.deleted[#mock.deleted + 1] = id
      if mock.delete_error then
        error(mock.delete_error)
      end
      mock.callback = nil
    end,
  }
  host.defer_fn = function(fn, delay)
    if mock.defer_error then
      error(mock.defer_error)
    end
    if mock.defer_false then
      return nil
    end
    local timer = { fn = fn, delay = delay, stopped = false }
    function timer:stop()
      self.stopped = true
    end
    mock.queue[#mock.queue + 1] = timer
    return timer
  end
  function mock:event(name, data)
    if self.callback then
      self.callback({ id = 42, event = name, match = name, data = data })
    end
  end
  function mock:step()
    local timer = table.remove(self.queue, 1)
    if not timer then
      return false
    end
    if not timer.stopped then
      timer.fn()
    end
    return true
  end
  function mock:drain(limit)
    local count = 0
    while self:step() do
      count = count + 1
      if count > (limit or 100) then
        error("timer queue did not drain")
      end
    end
  end
  return mock
end

return M
