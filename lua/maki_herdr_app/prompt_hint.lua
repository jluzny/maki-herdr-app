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
    content = "For Herdr Desktop, read 'hc --skill' via bash. Prefer hc_status and hc_command for other supported hc calls. Check PATH for 'herdr-app'; if absent in WSL, check 'herdr-app.exe'. Read the available CLI's --skill before Desktop operations. If 'hc' is missing from PATH, try '~/.local/bin/hc' or set 'HC_INSTALL_DIR'. Do not report a missing CLI by itself; report any task you cannot complete.",
  })
end

return M
