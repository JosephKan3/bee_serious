--[[
  Unit tests for bee_genebank_scheduler.lua -- the pure next-job planner.
  Synthetic states over a Noble-like tree; no hardware, no graph.

  POLICY UNDER TEST (v0.7): a species' reserve (minP pure princesses + minD pure
  drones) is INVIOLABLE capital -- never consumed to climb the tree. A species is
  built to reserve PLUS one surplus unit in each role it is spent in (princess parent
  -> minP+1 princesses; drone parent -> minD+1 drones); only that SURPLUS is ever
  spent in a cross. Build order per species: princess reserve -> drones (reserve +
  surplus) -> princess surplus, so surplus drones exist to purify a surplus princess.
]]

local S = require("bee_genebank_scheduler")

local failures = 0
local function check(name, cond, detail)
  if cond then print("OK   " .. name)
  else failures = failures + 1; print("FAIL " .. name .. (detail and (" -- " .. detail) or "")) end
end

-- Noble tree: Forest x Wintry -> Common; Common x Forest -> Cultivated;
--             Common x Cultivated -> Noble.
--   princess parents: Forest (Common), Common (Cultivated, Noble)
--   drone parents:    Wintry (Common), Forest (Cultivated), Cultivated (Noble)
-- buildTargets (minP=1, minD=8): Forest (2,9), Wintry (1,9), Common (2,8),
--                                Cultivated (1,9), Noble=target (1,0).
local STEPS = {
  { result = "Common", princess = "Forest", drone = "Wintry" },
  { result = "Cultivated", princess = "Common", drone = "Forest" },
  { result = "Noble", princess = "Common", drone = "Cultivated" },
}
local BASE = { Forest = true, Wintry = true }

local function stateD(banks, convertible, convertibleDrones)
  return {
    banks = banks, convertible = convertible or {}, convertibleDrones = convertibleDrones or {},
    steps = STEPS, baseSpecies = BASE, target = "Noble",
    minPrincesses = 1, minDrones = 8,
  }
end
local function state(banks, convertible) return stateD(banks, convertible, {}) end
local function b(pP, pD) return { purePrincesses = pP, pureDrones = pD } end

-- Bases stocked with ample SURPLUS so Phase 1 is satisfied and the climb (Phase 2)
-- is what the case actually exercises.
local function withReady(extra)
  local banks = { Forest = b(3, 12), Wintry = b(3, 12) }
  for k, v in pairs(extra or {}) do banks[k] = v end
  return banks
end

-- ============================================================
-- Reached
do
  local j = S.nextJob(state({ Noble = b(1, 0) }))
  check("done when target has a pure princess", j.type == "done", j.type)
end

-- ============================================================
-- Phase 1 -- base banks
do
  local j = S.nextJob(state({ Forest = b(0, 5), Wintry = b(1, 8) }, { Forest = 2 }))
  check("base princess below reserve + carrier -> convert", j.type == "convert" and j.to == "Forest", j.type)

  local j2 = S.nextJob(state({ Forest = b(0, 5), Wintry = b(1, 8) }, { Forest = 0 }))
  check("base princess below reserve + NOT convertible -> blocked", j2.type == "blocked", j2.type)

  local j3 = S.nextJob(state({ Forest = b(0, 0), Wintry = b(1, 8) }, { Forest = 3 }))
  check("base princess below reserve but no pure drone -> blocked", j3.type == "blocked", j3.type)
end

do
  -- Below the DRONE build target (Forest is a drone parent -> target 9) -> grow.
  local j = S.nextJob(state({ Forest = b(1, 3), Wintry = b(1, 9) }))
  check("base drone bank below target -> grow it", j.type == "grow" and j.species == "Forest", j.type)

  -- At reserve (8) but below drone surplus target (9) -> grow to build the surplus.
  local j2 = S.nextJob(state({ Forest = b(1, 8), Wintry = b(1, 9) }))
  check("base at drone reserve but below surplus target -> grow the surplus",
    j2.type == "grow" and j2.species == "Forest", j2.type)

  -- Drone surplus present, princess below surplus target, carrier on hand -> convert
  -- the byproduct against a SURPLUS drone to mint the surplus princess.
  local j3 = S.nextJob(state({ Forest = b(1, 9), Wintry = b(1, 9) }, { Forest = 2 }))
  check("base princess surplus buildable via convert (surplus drone) -> convert",
    j3.type == "convert" and j3.to == "Forest", j3.type)
end

-- ============================================================
-- Phase 2 -- the climb, bases stocked with surplus
do
  local j = S.nextJob(stateD(withReady({ Common = b(0, 0) }), {}, {}))
  check("Common not made, bases have surplus -> mutate Forest x Wintry -> Common",
    j.type == "mutate" and j.princess == "Forest" and j.drone == "Wintry" and j.result == "Common", j.type)
end

do
  local j = S.nextJob(stateD(withReady({ Common = b(0, 0) }), { Common = 1 }, { Common = 1 }))
  check("carriers of BOTH roles, no pure -> fix Common", j.type == "fix" and j.species == "Common", j.type)
end

do
  -- Only a carrier PRINCESS (V), no pure drone -> can't fix/convert; spread into the
  -- drone role from a surplus parent drone (Wintry) so fix can run later.
  local j = S.nextJob(stateD(withReady({ Common = b(0, 0) }), { Common = 1 }, {}))
  check("only a carrier princess -> seedDrone (V x surplus parent drone)",
    j.type == "seedDrone" and j.species == "Common" and j.drone == "Wintry", j.type .. "/" .. tostring(j.drone))
end

do
  -- Only a carrier DRONE (W), no pure -> spread into the princess role from a SURPLUS
  -- parent princess (Forest). Forest has surplus here, so spending it is allowed.
  local j = S.nextJob(stateD(withReady({ Common = b(0, 0) }), {}, { Common = 1 }))
  check("only a carrier drone -> seedPrincess (surplus parent x W)",
    j.type == "seedPrincess" and j.species == "Common" and j.princess == "Forest", j.type .. "/" .. tostring(j.princess))
end

do
  -- THE LOGGED BUG: Common has a pure princess + pure drones, drone bank not yet full,
  -- carrier drones around, NO carrier princess. Old scheduler ran seedPrincess (pure
  -- FOREST x carrier), sacrificing a foreign purebred. Now it GROWS the Common pair
  -- (pure x pure) to build the drone bank -- wastes nothing, touches no reserve.
  local j = S.nextJob(stateD(withReady({ Common = b(1, 2) }), {}, { Common = 4 }))
  check("pure Common pair on hand, drones short -> GROW Common, not seedPrincess(Forest)",
    j.type == "grow" and j.species == "Common", j.type .. "/" .. tostring(j.species))
end

do
  -- growDrone is allowed ONLY from a SURPLUS princess: Common has 2 pure princesses
  -- (surplus), 0 drones, and a carrier drone -> cross a surplus princess x the carrier.
  local j = S.nextJob(stateD(withReady({ Common = b(2, 0) }), {}, { Common = 1 }))
  check("surplus princess + carrier drone, no pure drone -> growDrone",
    j.type == "growDrone" and j.species == "Common", j.type .. "/" .. tostring(j.species))
end

do
  -- Common sits at exactly its RESERVE (1 princess, 8 drones) with Cultivated pending.
  -- It must NOT be spent toward Cultivated; instead build Common's own surplus first
  -- (here: re-mutate Forest x Wintry from base surplus to throw off Common carriers).
  local j = S.nextJob(stateD(withReady({ Common = b(1, 8), Cultivated = b(0, 0) }), {}, {}))
  check("Common at reserve -> BUILD Common (mutate->Common), never spend it toward Cultivated",
    j.type == "mutate" and j.result == "Common", j.type .. "/" .. tostring(j.result))
end

do
  -- Common has SURPLUS (2,8) -> now advancing to Cultivated is allowed (spends the
  -- Common surplus princess + a Forest surplus drone).
  local j = S.nextJob(stateD(withReady({ Common = b(2, 8), Cultivated = b(0, 0) }), {}, {}))
  check("Common surplus present -> mutate Common x Forest -> Cultivated",
    j.type == "mutate" and j.princess == "Common" and j.drone == "Forest" and j.result == "Cultivated", j.type)
end

do
  -- Bottom-up: Cultivated exists but its drone bank (feeds Noble) is short -> grow it
  -- to reserve+surplus BEFORE attempting Noble.
  local j = S.nextJob(stateD(withReady({ Common = b(2, 8), Cultivated = b(1, 2) }), {}, {}))
  check("Cultivated drones short -> grow Cultivated, NOT mutate Noble yet",
    j.type == "grow" and j.species == "Cultivated", j.type)
end

do
  -- All intermediate banks stocked with the surplus their roles need -> mutate Noble.
  local j = S.nextJob(stateD(withReady({ Common = b(2, 8), Cultivated = b(1, 9), Noble = b(0, 0) }), {}, {}))
  check("all banks ready (with surplus) -> mutate Common x Cultivated -> Noble",
    j.type == "mutate" and j.princess == "Common" and j.drone == "Cultivated" and j.result == "Noble", j.type)
end

do
  local j = S.nextJob(stateD(withReady({ Common = b(2, 8), Cultivated = b(1, 9), Noble = b(1, 0) }), {}, {}))
  check("target with 1 pure princess (no drones) counts as done", j.type == "done", j.type)
end

-- ============================================================
-- Invariant: a job is NEVER emitted that would consume a species at/below its reserve.
do
  -- Common at reserve (1,8): the only Common-consuming jobs are mutate princess=Common
  -- and seedPrincess princess=Common. Neither may be chosen while Common has no surplus.
  local j = S.nextJob(stateD(withReady({ Common = b(1, 8), Cultivated = b(0, 0), Noble = b(0, 0) }), {}, {}))
  local spendsCommon = (j.type == "mutate" and j.princess == "Common")
    or (j.type == "seedPrincess" and j.princess == "Common")
  check("reserve invariant: never spend Common while it is at reserve", not spendsCommon,
    j.type .. "/" .. tostring(j.princess or j.species))

  -- Forest at reserve (1,8) with everything above it wanting it: must build Forest,
  -- not spend it. (Bases only ever block/convert/grow when short -- never a foreign spend.)
  local j2 = S.nextJob(stateD({ Forest = b(1, 8), Wintry = b(3, 12), Common = b(0, 0) }, {}, {}))
  local spendsForestReserve = (j2.type == "mutate" and j2.princess == "Forest")
  check("reserve invariant: Forest at drone-reserve is grown, not spent",
    j2.type == "grow" and j2.species == "Forest", j2.type .. "/" .. tostring(j2.species))
  check("reserve invariant: no mutate consuming Forest at reserve", not spendsForestReserve)
end

-- ============================================================
-- Determinism
do
  local st = stateD(withReady({ Common = b(1, 3) }), {}, {})
  local j1, j2 = S.nextJob(st), S.nextJob(st)
  check("nextJob is deterministic", j1.type == j2.type and j1.species == j2.species)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
