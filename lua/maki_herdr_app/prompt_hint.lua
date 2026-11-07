local M = {}

function M.start(host)
  local id_ok, terminal_id = pcall(host.uv.os_getenv, "HC_TERMINAL_ID")
  local socket_ok, socket = pcall(host.uv.os_getenv, "HC_TERMINAL_SOCKET")
  if
    not id_ok
    or not socket_ok
    or type(terminal_id) ~= "string"
    or terminal_id == ""
    or type(socket) ~= "string"
    or socket == ""
  then
    return
  end

  host.api.register_permission_rule({
    tool = "bash",
    scope = "hc --skill",
    effect = "allow",
  })

  host.api.register_prompt_hint({
    slot = "tool_usage",
    content = "For Herdr Desktop orchestration, use hc. Before coordinating terminals or agents, run the exact bash command hc --skill and read its output. "
      .. "For repeated hc blocked notifications, notify the user once per unresolved prompt; "
      .. "if the prompt changes, inspect it again and notify as needed. Never bypass approvals.",
  })
end

return M
