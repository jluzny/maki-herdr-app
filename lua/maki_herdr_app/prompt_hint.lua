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

  host.api.register_prompt_hint({
    slot = "tool_usage",
    content = "For Herdr Desktop orchestration, use hc. Before coordinating terminals or agents, read hc --skill.",
  })
end

return M
