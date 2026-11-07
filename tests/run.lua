package.path = "./lua/?.lua;./tests/?.lua;" .. package.path

local tests = {}

function test(name, fn)
  tests[#tests + 1] = { name = name, fn = fn }
end

function eq(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

function truthy(value, message)
  if not value then
    error(message or "expected a truthy value", 2)
  end
end

require("test_reducer")
require("test_osc")
require("test_runtime")
require("test_prompt_hint")

local failed = 0
for _, case in ipairs(tests) do
  local ok, err = pcall(case.fn)
  if not ok then
    failed = failed + 1
    io.stderr:write("FAIL ", case.name, ": ", tostring(err), "\n")
  end
end
io.write(string.format("%d tests, %d failures\n", #tests, failed))
if failed > 0 then
  os.exit(1)
end
