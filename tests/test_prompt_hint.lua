local prompt_hint = require("maki_herdr_app.prompt_hint")
local mock_host = require("mock_host")

local hint = "For Herdr Desktop orchestration, use hc. Before coordinating terminals or agents, run the exact bash command hc --skill and read its output. "
  .. "For repeated hc blocked notifications, notify the user once per unresolved prompt; "
  .. "if the prompt changes, inspect it again and notify as needed. Never bypass approvals. "
  .. "The hc permission includes commands that start programs and control terminals; use them only as authorized."

local function new_mock()
  local mock = mock_host.new()
  mock.rules = {}
  mock.host.api.register_permission_rule = function(spec)
    mock.rules[#mock.rules + 1] = spec
  end
  return mock
end

test("prompt hint and selected permission rules are registered in a Herdr terminal", function()
  local mock = new_mock()
  mock.env.HC_TERMINAL_ID = "secret-id"
  mock.env.HC_TERMINAL_SOCKET = "secret-socket"
  prompt_hint.start(mock.host)
  eq(#mock.hints, 1)
  eq(mock.hints[1].slot, "tool_usage")
  eq(mock.hints[1].content, hint)
  local scopes = { "hc *" }
  eq(#mock.rules, #scopes)
  for i, rule in ipairs(mock.rules) do
    eq(rule.tool, "bash")
    eq(rule.scope, scopes[i])
    eq(rule.effect, "allow")
    local fields = 0
    for _ in pairs(rule) do
      fields = fields + 1
    end
    eq(fields, 3)
  end
end)

test("prompt hint is omitted when either terminal variable is absent or empty", function()
  for _, name in ipairs({ "HC_TERMINAL_ID", "HC_TERMINAL_SOCKET" }) do
    for _, value in ipairs({ false, "", 42 }) do
      local mock = new_mock()
      mock.env.HC_TERMINAL_ID = "test-id"
      mock.env.HC_TERMINAL_SOCKET = "test-socket"
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
