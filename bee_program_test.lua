-- Unit tests for bee_program.lua -- the pure phase sequencer.
local P = require("bee_program")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

do
  local prog = P.new()
  check("default program starts at traitmax", P.current(prog) == "traitmax")
  check("default program is 2 phases (traitmax, rainbow)", P.remaining(prog) == 2)
  check("not done at start", not P.done(prog))
end

do
  local prog = P.new({ "traitmax", "rainbow" })
  check("custom phase list honored", P.current(prog) == "traitmax")
  check("advance -> rainbow", P.advance(prog) == "rainbow")
  check("remaining = 1 on last phase", P.remaining(prog) == 1)
  check("advance past last -> nil", P.advance(prog) == nil)
  check("done after advancing past the end", P.done(prog))
  check("remaining = 0 when done", P.remaining(prog) == 0)
  check("advance is a no-op once done", P.advance(prog) == nil and P.done(prog))
end

do
  check("current(nil) is nil", P.current(nil) == nil)
  check("done(nil) is true", P.done(nil))
  check("remaining(nil) is 0", P.remaining(nil) == 0)
end

print("")
if failures == 0 then print("ALL TESTS PASSED")
else print(failures .. " TEST(S) FAILED"); os.exit(1) end
