--[[
  Unit test for M.classifyApiaryLoad -- the guard that stops the robot dropping
  a drone (or clobbering a queen) into an apiary that's already set up.

  Background: every site runner used to rely SOLELY on `canWork(down)==true AND
  slot 1 occupied` to decide "leave it working". Any time canWork() read false
  while slot 1 still held a bee (output full, wrong climate/time, a transient
  false), the runners fell straight through and swapQueen/swapDrone'd anyway --
  loading a stray drone next to a mated queen, or re-picking a different drone
  next to an already-paired princess (the "random breeding" the user saw).

  classifyApiaryLoad reads the RAW slot stacks (by item name, not analyzed
  genome, since a freshly mated queen is often still unanalyzed) and returns the
  state the runners branch on. This locks in the princess-vs-queen distinction.
]]

local M = require("bee_keeper_manager")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Forestry item names (as the sim/hardware report them via getStackInSlot).
local PRINCESS = { name = "Forestry:beePrincessGE", size = 1 }
local DRONE    = { name = "Forestry:beeDroneGE", size = 1 }
local QUEEN    = { name = "Forestry:beeQueenGE", size = 1 } -- a MATED princess
-- Case-insensitivity + unanalyzed queen (no .individual) must still classify.
local QUEEN_UNANALYZED = { name = "forestry:beequeenge", size = 1 }
local COMB = { name = "forestry:beeComb", size = 3 } -- an unexpected slot-1 item

local function C(a, b) return M.classifyApiaryLoad(a, b) end

check("empty slot 1 -> 'empty' (free to seed a princess)", C(nil, nil) == "empty", C(nil, nil))
check("empty slot 1 ignores whatever's in slot 2", C(nil, DRONE) == "empty", C(nil, DRONE))

check("princess + empty drone slot -> 'unpaired' (the one load case)", C(PRINCESS, nil) == "unpaired", C(PRINCESS, nil))
check("princess + drone already loaded -> 'paired' (leave the committed cross)", C(PRINCESS, DRONE) == "paired", C(PRINCESS, DRONE))

check("mated queen -> 'queen' (breeding, never touch)", C(QUEEN, nil) == "queen", C(QUEEN, nil))
check("mated queen + drone in slot 2 -> still 'queen'", C(QUEEN, DRONE) == "queen", C(QUEEN, DRONE))
check("queen match is case-insensitive & analyze-independent", C(QUEEN_UNANALYZED, nil) == "queen", C(QUEEN_UNANALYZED, nil))

-- "queen" is deliberately the fallback for any non-princess occupant: better to
-- leave a slot we don't understand alone than to clobber it.
check("unexpected slot-1 item -> 'queen' (leave it alone)", C(COMB, nil) == "queen", C(COMB, nil))

-- A queen item whose name contains "princess" must NOT exist, but guard the
-- ordering anyway: "queen" takes precedence so a mated bee is never mistaken
-- for one still needing a drone.
check("name containing both -> 'queen' wins", C({ name = "beeQueenPrincessGE" }, nil) == "queen")

print("")
if failures == 0 then print("ALL TESTS PASSED") else print(failures .. " TEST(S) FAILED"); os.exit(1) end
