local M = {}

local states = {
  idle = true,
  working = true,
  blocked = true,
  done = true,
  error = true,
  clear = true,
}

function M.encode(state)
  if not states[state] then
    return nil, "invalid status"
  end
  return "\27]7501;state=" .. state .. ":app=maki\27\\"
end

return M
