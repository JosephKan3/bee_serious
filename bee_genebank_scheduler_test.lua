--[[
  Unit tests for bee_genebank_scheduler.lua -- the pure next-job planner.
  Synthetic states over a Noble-like tree; no hardware, no graph.
--]]

local S = require("bee_genebank_scheduler")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Noble tree: Forest x Wintry -> Common; Common x Forest -> Cultivated;
--             Common x Cultivated -> Noble.
local STEPS = {
  { result = "Common", princess = "Forest", drone = "Wintry" },
  { result = "Cultivated", princess = "Common", drone = "Forest" },
  { result = "Noble", princess = "Common", drone = "Cultivated" },
}
local BASE = { Forest = true, Wintry = true }

local function state(banks, convertible)
  return {
    banks = banks, convertible = convertible or {},
    steps = STEPS, baseSpecies = BASE, target = "Noble",
    minPrincesses = 1, minDrones = 8,
  }
end
-- shorthand bank
local function b(pP, pD) return { purePrincesses = pP, pureDrones = pD } end
local READY_BASE = { Forest = b(1, 8), Wintry = b(1, 8) }
local function withBase(extra)
  local banks = { Forest = b(1, 8), Wintry = b(1, 8) }
  for k, v in pairs(extra or {}) do banks[k] = v end
  return banks
end

-- ============================================================
do
  local j = S.nextJob(state({ Noble = b(1, 0) }))
  check("done when target has a pure princess", j.type == "done")
end

-- Base princess short -> convert (if convertible + drones), else blocked
do
  local j = S.nextJob(state({ Forest = b(0, 5), Wintry = b(1, 8) }, { Forest = 2 }))
  check("base princess short + convertible -> convert to it", j.type == "convert" and j.to == "Forest", j.type)

  local j2 = S.nextJob(state({ Forest = b(0, 5), Wintry = b(1, 8) }, { Forest = 0 }))
  check("base princess short + NOT convertible -> blocked", j2.type == "blocked", j2.type)

  -- no pure drone to convert against -> blocked
  local j3 = S.nextJob(state({ Forest = b(0, 0), Wintry = b(1, 8) }, { Forest = 3 }))
  check("base princess short but no pure drone to converge on -> blocked", j3.type == "blocked", j3.type)
end

-- Base drones short -> grow pure x pure
do
  local j = S.nextJob(state({ Forest = b(1, 3), Wintry = b(1, 8) }))
  check("base drone bank short -> grow it", j.type == "grow" and j.species == "Forest", j.type)
end

-- Intermediate never made, parents ready -> mutate
do
  local j = S.nextJob(state(withBase({ Common = b(0, 0) })))
  check("Common not made, base ready -> mutate Forest x Wintry -> Common",
    j.type == "mutate" and j.princess == "Forest" and j.drone == "Wintry" and j.result == "Common", j.type)
end

-- Role-aware drone targets: Common is only ever a PRINCESS parent here, so it
-- needs just the small recovery drone reserve (default 2), not the full minDrones
-- -- it advances once it has that, instead of over-building a bank it never spends.
do
  local j = S.nextJob(state(withBase({ Common = b(1, 1) })))
  check("princess-only intermediate below recovery drones -> grow",
    j.type == "grow" and j.species == "Common", j.type)

  local j2 = S.nextJob(state(withBase({ Common = b(1, 2) })))
  check("princess-only intermediate AT recovery drones -> advance (mutate Cultivated), not over-build",
    j2.type == "mutate" and j2.result == "Cultivated", j2.type)
end

-- A DRONE parent (Cultivated feeds Noble as a drone) still needs the FULL reserve.
do
  local j = S.nextJob(state(withBase({ Common = b(1, 8), Cultivated = b(1, 5) })))
  check("drone-parent intermediate below minDrones -> grow to full reserve",
    j.type == "grow" and j.species == "Cultivated", j.type)
end

-- Common bank ready -> advance to Cultivated (mutate Common x Forest)
do
  local j = S.nextJob(state(withBase({ Common = b(1, 8), Cultivated = b(0, 0) })))
  check("Common bank ready -> mutate Common x Forest -> Cultivated",
    j.type == "mutate" and j.princess == "Common" and j.drone == "Forest" and j.result == "Cultivated", j.type)
end

-- BOTTOM-UP: Cultivated drone bank grown to reserve BEFORE attempting Noble
do
  local j = S.nextJob(state(withBase({ Common = b(1, 8), Cultivated = b(1, 2) })))
  check("Cultivated made, drones short -> grow Cultivated, NOT mutate Noble yet",
    j.type == "grow" and j.species == "Cultivated", j.type)
end

-- All intermediate banks ready -> mutate the final target
do
  local j = S.nextJob(state(withBase({ Common = b(1, 8), Cultivated = b(1, 8), Noble = b(0, 0) })))
  check("all banks ready -> mutate Common x Cultivated -> Noble",
    j.type == "mutate" and j.princess == "Common" and j.drone == "Cultivated" and j.result == "Noble", j.type)
end

-- Parent renewal: Common princess spent (0) while building Cultivated -> rebuild Common first
do
  local j = S.nextJob(state(withBase({ Common = b(0, 8), Cultivated = b(0, 0) }), { Common = 1 }))
  check("Common princess spent -> re-mutate Common (rebuild) before advancing",
    j.type == "mutate" and j.result == "Common", j.type)
end

-- Determinism
do
  local st = state(withBase({ Common = b(1, 3) }))
  local j1, j2 = S.nextJob(st), S.nextJob(st)
  check("nextJob is deterministic", j1.type == j2.type and j1.species == j2.species)
end

-- Target only needs to be REACHED, not a full drone bank
do
  local j = S.nextJob(state(withBase({ Common = b(1, 8), Cultivated = b(1, 8), Noble = b(1, 0) })))
  check("target with 1 pure princess (no drones) counts as done", j.type == "done", j.type)
end

-- ============================================================
-- Consolidation: a mutation only ever yields HYBRID carriers, never a pure. The
-- ONLY way to bootstrap the first pure of a mutated species is to breed a carrier
-- princess x carrier drone together (`fix`). Without this the scheduler mutates
-- forever and never gets a pure -- the real-hardware dead-end.
-- ============================================================

local function stateD(banks, convertible, convertibleDrones)
  return {
    banks = banks, convertible = convertible or {}, convertibleDrones = convertibleDrones or {},
    steps = STEPS, baseSpecies = BASE, target = "Noble",
    minPrincesses = 1, minDrones = 8,
  }
end

do
  -- Base ready, no pure Common anywhere, but a carrier Common princess AND a
  -- carrier Common drone exist -> consolidate them into a pure.
  local j = S.nextJob(stateD(withBase({}), { Common = 1 }, { Common = 1 }))
  check("fix when carriers of BOTH roles exist but no pure yet", j.type == "fix" and j.species == "Common",
    j.type .. "/" .. tostring(j.species))
end

do
  -- Only a carrier PRINCESS (no carrier drone) -> can't fix yet; mutate more to
  -- produce carrier drones.
  local j = S.nextJob(stateD(withBase({}), { Common = 1 }, {}))
  check("no fix with only a carrier princess -> mutate to make more carriers",
    j.type == "mutate" and j.result == "Common", j.type)
end

do
  -- A pure Common princess already exists but no Common drones, and carriers of
  -- both roles are around -> fix seeds the first pure DRONES (grow needs a pure
  -- drone to start, which we don't have).
  local j = S.nextJob(stateD(withBase({ Common = b(1, 0) }), { Common = 1 }, { Common = 1 }))
  check("fix to seed first pure drones when princess exists but no pure drone",
    j.type == "fix" and j.species == "Common", j.type .. "/" .. tostring(j.species))
end

do
  -- Once Common has a pure princess AND at least one pure drone, stop fixing and
  -- grow the drone bank normally.
  local j = S.nextJob(stateD(withBase({ Common = b(1, 1) }), { Common = 1 }, { Common = 1 }))
  check("grow (not fix) once a pure drone seed exists", j.type == "grow" and j.species == "Common", j.type)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
