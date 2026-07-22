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
-- canSpendPrincess -- may draw to zero, but only if the drone reservoir is intact
-- ============================================================

do
  local ready = GB.summarize(entriesFor("Forest", 1, 0, 8, 0))
  check("canSpendPrincess TRUE with 1 pure princess AND full drone reservoir",
    GB.canSpendPrincess(ready, "Forest"))

  -- Recovery floor (default 2), NOT the full reserve: a freshly-bred
  -- intermediate with a princess + a couple drones can already be used.
  local recoverable = GB.summarize(entriesFor("Forest", 1, 0, 2, 0))
  check("canSpendPrincess TRUE at the recovery floor (2 pure drones, < the 8 reserve)",
    GB.canSpendPrincess(recoverable, "Forest"))

  local belowRecovery = GB.summarize(entriesFor("Forest", 1, 0, 1, 0))
  check("canSpendPrincess FALSE below the recovery floor (1 < 2) -- can't re-purify",
    not GB.canSpendPrincess(belowRecovery, "Forest"))

  check("canSpendPrincess respects a custom recoveryDrones",
    not GB.canSpendPrincess(recoverable, "Forest", { recoveryDrones = 3 }))

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
  -- Both parents secure and drawable.
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 1, 0, 8, 0)) do table.insert(e, x) end   -- princess parent
  for _, x in ipairs(entriesFor("Wintry", 1, 0, 9, 0)) do table.insert(e, x) end   -- drone parent (surplus)
  local s = GB.summarize(e)
  local plan = GB.planStepDraw(s, "Forest", "Wintry")
  check("planStepDraw ready when princess-parent recoverable and drone-parent has surplus",
    plan.ready and #plan.replenish == 0 and #plan.unrecoverable == 0)
end

do
  -- Drone parent at floor (no surplus) -> must replenish it first.
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 1, 0, 8, 0)) do table.insert(e, x) end
  for _, x in ipairs(entriesFor("Wintry", 1, 0, 8, 0)) do table.insert(e, x) end
  local s = GB.summarize(e)
  local plan = GB.planStepDraw(s, "Forest", "Wintry")
  check("planStepDraw not ready when drone parent is only at the floor", not plan.ready)
  check("planStepDraw asks to replenish the drone parent (Wintry)",
    plan.replenish[1] == "Wintry" and #plan.unrecoverable == 0)
end

do
  -- Princess parent below the RECOVERY floor (1 pure drone < 2) but recoverable
  -- (has that 1 pure drone to purify toward) -> replenish it first.
  local e = {}
  for _, x in ipairs(entriesFor("Forest", 1, 0, 1, 0)) do table.insert(e, x) end   -- below recovery
  for _, x in ipairs(entriesFor("Wintry", 1, 0, 9, 0)) do table.insert(e, x) end
  local s = GB.summarize(e)
  local plan = GB.planStepDraw(s, "Forest", "Wintry")
  check("planStepDraw asks to replenish the princess parent when below the recovery floor",
    not plan.ready and plan.replenish[1] == "Forest")
end

do
  -- Drone parent entirely absent and unrecoverable (no princess, no pure drone).
  local s = GB.summarize(entriesFor("Forest", 1, 0, 9, 0))
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
