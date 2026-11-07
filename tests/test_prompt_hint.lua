local prompt_hint = require("maki_herdr_app.prompt_hint")
local mock_host = require("mock_host")

local hint = "For Herdr Desktop orchestration, use hc. Before coordinating terminals or agents, read hc --skill."

test("prompt hint is registered with fixed content in a Herdr terminal", function()
  local mock = mock_host.new()
  mock.env.HC_TERMINAL_ID = "secret-id"
  mock.env.HC_TERMINAL_SOCKET = "secret-socket"
  prompt_hint.start(mock.host)
  eq(#mock.hints, 1)
  eq(mock.hints[1].slot, "tool_usage")
  eq(mock.hints[1].content, hint)
end)

test("prompt hint is omitted when either terminal variable is absent or empty", function()
  for _, name in ipairs({ "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET" }) do
    for _, value in ipairs({ false, "", 42 }) do
      local mock = mock_host.new()
      mock.env[name] = value or nil
      prompt_hint.start(mock.host)
      eq(mock.hints, nil)
    end
  end
end)

test("prompt hint fails closed when either environment read is denied", function()
  for _, denied in ipairs({ "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET" }) do
    local mock = mock_host.new()
    local getenv = mock.host.uv.os_getenv
    mock.host.uv.os_getenv = function(name)
      if name == denied then
        error("permission denied: secret-value")
      end
      return getenv(name)
    end
    prompt_hint.start(mock.host)
    eq(mock.hints, nil)
    eq(#mock.warnings, 0)
  end
end)
