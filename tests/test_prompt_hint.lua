local prompt_hint = require("maki_herdr_app.prompt_hint")
local mock_host = require("mock_host")

local hint =
  "For Herdr Desktop, read 'hc --skill' via bash. Prefer hc_status and hc_command for other supported hc calls. Check PATH for 'herdr-app'; if absent in WSL, check 'herdr-app.exe'. Read the available CLI's --skill before Desktop operations. Do not report a missing CLI by itself; report any task you cannot complete."

local function new_mock()
  local mock = mock_host.new()
  mock.rules = {}
  mock.host.api.register_permission_rule = function(spec)
    mock.rules[#mock.rules + 1] = spec
  end
  return mock
end

test("prompt hint and exact permission rule are registered in a Herdr terminal", function()
  local mock = new_mock()
  mock.env.HC_TERMINAL_ID = "secret-id"
  mock.env.HC_TERMINAL_SOCKET = "secret-socket"
  prompt_hint.start(mock.host)
  eq(#mock.hints, 1)
  eq(mock.hints[1].slot, "tool_usage")
  eq(mock.hints[1].content, hint)
  eq(#mock.rules, 1)
  local rule = mock.rules[1]
  eq(rule.tool, "bash")
  eq(rule.scope, "hc --skill")
  eq(rule.effect, "allow")
  local fields = 0
  for _ in pairs(rule) do
    fields = fields + 1
  end
  eq(fields, 3)
end)

test("prompt hint is omitted when either terminal variable is absent or empty", function()
  for _, name in ipairs({ "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET" }) do
    for _, value in ipairs({ false, "", 42 }) do
      local mock = new_mock()
      mock.env[name] = value or nil
      prompt_hint.start(mock.host)
      eq(mock.hints, nil)
      eq(#mock.rules, 0)
    end
  end
end)

test("prompt hint fails closed when either environment read is denied", function()
  for _, denied in ipairs({ "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET" }) do
    local mock = new_mock()
    local getenv = mock.host.uv.os_getenv
    mock.host.uv.os_getenv = function(name)
      if name == denied then
        error("permission denied: secret-value")
      end
      return getenv(name)
    end
    prompt_hint.start(mock.host)
    eq(mock.hints, nil)
    eq(#mock.rules, 0)
    eq(#mock.warnings, 0)
  end
end)
