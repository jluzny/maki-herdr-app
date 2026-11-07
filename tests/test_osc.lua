local osc = require("herdr_status.osc")

test("osc encodes only fixed aggregate states", function()
  for _, status in ipairs({ "idle", "working", "blocked", "done", "error", "clear" }) do
    eq(osc.encode(status), "\27]7501;state=" .. status .. ":app=maki\27\\")
  end
end)

test("osc rejects invalid states", function()
  for _, status in ipairs({ "", "unknown", "idle:app=evil", "idle\27\\", false, 1 }) do
    local value, err = osc.encode(status)
    eq(value, nil)
    eq(err, "invalid status")
  end
  local value, err = osc.encode(nil)
  eq(value, nil)
  eq(err, "invalid status")
end)

test("osc rejects inherited Lua table keys", function()
  for _, status in ipairs({ "__index", "__newindex", "__mode" }) do
    local value, err = osc.encode(status)
    eq(value, nil)
    eq(err, "invalid status")
  end
end)
