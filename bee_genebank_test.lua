--[[
  Unit tests for bee_genebank.lua -- the pure per-species reserve policy.
  No hardware; everything is data-in/data-out, like bee_mutation_graph_test.lua.
--]]

local GB = require("bee_genebank")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- Convenience: build an entries list from a compact spec.
--   pp = pure princesses, ip = impure princesses, pd = pure drones, id = impure drones
local function entriesFor(species, pp, ip, pd, id)
  local e = {}
  for _ = 1, pp do table.insert(e, { species = species, role = "princess", speciesPure = true }) end
  for _ = 1, ip do table.insert(e, { species = species, role = "princess", speciesPure = false }) end
  for _ = 1, pd do table.insert(e, { species = species, role = "drone", speciesPure = true }) end
  for _ = 1, id do table.insert(e, { species = species, role = "drone", speciesPure = false }) end
  return e
end

-- ============================================================
-- summarize
-- ============================================================

do
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 1, 2, 8, 3)) do table.insert(e, x) end
  for _, x in ipairs(entriesFor("Meadows", 0, 1, 2, 0)) do table.insert(e, x) end
  local s = GB.summarize(e)

  check("summarize counts Forest princesses (pure+impure)", s.Forest.princesses == 3)
  check("summarize counts Forest pure princesses", s.Forest.purePrincesses == 1)
  check("summarize counts Forest impure princesses", s.Forest.impurePrincesses == 2)
  check("summarize counts Forest pure drones", s.Forest.pureDrones == 8)
  check("summarize counts Forest impure drones", s.Forest.impureDrones == 3)
  check("summarize counts Meadows too", s.Meadows.impurePrincesses == 1 and s.Meadows.pureDrones == 2)
  check("statusOf zero-fills an absent species", GB.statusOf(s, "Nowhere").purePrincesses == 0)
end

-- ============================================================
-- Reserve floor / isSecure (defaults: 1 princess, 8 drones)
-- ============================================================

do
  local secure = GB.summarize(entriesFor("Forest", 1, 0, 8, 0))
  check("isSecure at exactly the floor (1 pure princess, 8 pure drones)", GB.isSecure(secure, "Forest"))

  local noPrincess = GB.summarize(entriesFor("Forest", 0, 3, 20, 0))
  check("not secure with 0 pure princesses even with many drones", not GB.isSecure(noPrincess, "Forest"))

  local fewDrones = GB.summarize(entriesFor("Forest", 2, 0, 7, 0))
  check("not secure with only 7 pure drones", not GB.isSecure(fewDrones, "Forest"))

  local absent = GB.summarize({})
  check("absent species is not secure", not GB.isSecure(absent, "Forest"))
end

-- ============================================================
-- canSpendDrone -- only from surplus above the reservoir
-- ============================================================

do
  local atFloor = GB.summarize(entriesFor("Forest", 1, 0, 8, 0))
  check("canSpendDrone is FALSE at exactly the floor (8 = reservoir, protected)",
    not GB.canSpendDrone(atFloor, "Forest"))

  local surplus = GB.summarize(entriesFor("Forest", 1, 0, 9, 0))
  check("canSpendDrone is TRUE with surplus (9 > 8)", GB.canSpendDrone(surplus, "Forest"))

  check("canSpendDrone respects a custom minDrones",
    not GB.canSpendDrone(surplus, "Forest", { minDrones = 9 }))
end

-- ============================================================
-- canSpendPrincess -- SURPLUS-ONLY: spendable only ABOVE the reserve (minPrincesses),
-- mirroring canSpendDrone. The reserve princess is inviolable capital.
-- ============================================================

do
  local surplus = GB.summarize(entriesFor("Forest", 2, 0, 8, 0))
  check("canSpendPrincess TRUE with a SURPLUS princess (2 > reserve 1)",
    GB.canSpendPrincess(surplus, "Forest"))

  local atReserve = GB.summarize(entriesFor("Forest", 1, 0, 8, 0))
  check("canSpendPrincess FALSE at the reserve (1 princess) -- reserve is inviolable",
    not GB.canSpendPrincess(atReserve, "Forest"))

  check("canSpendPrincess respects a custom minPrincesses (2 not > reserve 2)",
    not GB.canSpendPrincess(surplus, "Forest", { minPrincesses = 2 }))

  local noPrincess = GB.summarize(entriesFor("Forest", 0, 2, 10, 0))
  check("canSpendPrincess FALSE with no pure princess to spend",
    not GB.canSpendPrincess(noPrincess, "Forest"))
end

-- ============================================================
-- deficit / needsReplenish
-- ============================================================

do
  local low = GB.summarize(entriesFor("Forest", 0, 1, 3, 0))
  local d = GB.deficit(low, "Forest")
  check("deficit reports missing pure princesses", d.princesses == 1, "got " .. d.princesses)
  check("deficit reports missing pure drones (8-3=5)", d.drones == 5, "got " .. d.drones)
  check("needsReplenish true when below floor", GB.needsReplenish(low, "Forest"))

  local secure = GB.summarize(entriesFor("Forest", 1, 0, 8, 0))
  check("needsReplenish false when secure", not GB.needsReplenish(secure, "Forest"))
end

-- ============================================================
-- canReplenish -- needs a princess (any purity) + at least one pure drone to converge on
-- ============================================================

do
  local recoverable = GB.summarize(entriesFor("Forest", 0, 1, 1, 0))
  check("canReplenish TRUE with an impure princess + a pure drone to purify toward",
    GB.canReplenish(recoverable, "Forest"))

  local noPrincess = GB.summarize(entriesFor("Forest", 0, 0, 5, 0))
  check("canReplenish FALSE with drones but no princess at all",
    not GB.canReplenish(noPrincess, "Forest"))

  local noPureDrone = GB.summarize(entriesFor("Forest", 0, 2, 0, 4))
  check("canReplenish FALSE with princesses but no PURE drone to converge on",
    not GB.canReplenish(noPureDrone, "Forest"))
end

-- ============================================================
-- planStepDraw -- the directional-step verdict the manager consumes
-- ============================================================

do
  -- Both parents have SURPLUS in the role they're spent in -> ready.
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 2, 0, 8, 0)) do table.insert(e, x) end   -- princess surplus (2>1)
  for _, x in ipairs(entriesFor("Wintry", 1, 0, 9, 0)) do table.insert(e, x) end   -- drone surplus (9>8)
  local s = GB.summarize(e)
  local plan = GB.planStepDraw(s, "Forest", "Wintry")
  check("planStepDraw ready when both parents have surplus",
    plan.ready and #plan.replenish == 0 and #plan.unrecoverable == 0)
end

do
  -- Drone parent at reserve (no surplus) -> must replenish it first (recoverable).
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 2, 0, 8, 0)) do table.insert(e, x) end
  for _, x in ipairs(entriesFor("Wintry", 1, 0, 8, 0)) do table.insert(e, x) end   -- at reserve, no surplus
  local s = GB.summarize(e)
  local plan = GB.planStepDraw(s, "Forest", "Wintry")
  check("planStepDraw not ready when drone parent has no surplus", not plan.ready)
  check("planStepDraw asks to replenish the drone parent (Wintry)",
    plan.replenish[1] == "Wintry" and #plan.unrecoverable == 0)
end

do
  -- Princess parent at reserve (1 = minP, no surplus) but recoverable (a pure drone to
  -- purify toward) -> replenish it first, never spend the reserve.
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 1, 0, 8, 0)) do table.insert(e, x) end   -- at reserve
  for _, x in ipairs(entriesFor("Wintry", 1, 0, 9, 0)) do table.insert(e, x) end
  local s = GB.summarize(e)
  local plan = GB.planStepDraw(s, "Forest", "Wintry")
  check("planStepDraw asks to replenish the princess parent when at reserve (no surplus)",
    not plan.ready and plan.replenish[1] == "Forest")
end

do
  -- Drone parent entirely absent and unrecoverable (no princess, no pure drone).
  local s = GB.summarize(entriesFor("Forest", 2, 0, 9, 0))
  local plan = GB.planStepDraw(s, "Forest", "Meadows")
  check("planStepDraw flags a missing base parent as unrecoverable",
    not plan.ready and plan.unrecoverable[1] == "Meadows" and #plan.replenish == 0)
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
