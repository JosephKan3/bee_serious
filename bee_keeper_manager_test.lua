--[[
  Mock-based tests for bee_keeper_manager.lua.

  There's no OpenComputers/Minecraft runtime to test against here, so this
  fakes "component", "sides", and "bee_keeper_nav" (the only hardware-
  touching requires) with an in-memory simulated world: a table of apiary
  slots keyed by (droneX, droneZ, side) -- mirroring how the real
  UpgradeBeekeeperUtil resolves position.offset(facing) from wherever the
  agent currently is -- plus a table of the agent's own inventory slots.
  bee_keeper_manager's actual decision logic (which drone to pick, which
  mutation pair to load, etc.) runs for real against these fakes -- only
  world I/O and flight are simulated, not the logic being tested. Nav's
  own geometry (orderByProximity, gotoXZ arrival/stuck detection) is
  tested separately in bee_keeper_nav_test.lua against the real module.
--]]

-- ============================================================
-- Fakes: sides, component, bee_keeper_nav
-- ============================================================

package.loaded["sides"] = {
  north = 2, south = 3, east = 4, west = 5, up = 0, down = 1,
}
local DOWN = 1

local world = {
  apiaries = {},  -- ["x:z:side"] = { [slot] = stack }
  agentInventory = {},  -- [slot] = stack
  selectedSlot = 1,
  analyzeCalls = 0,
  dronePos = { x = 0, z = 0 },
}

local function apiary(side)
  local key = world.dronePos.x .. ":" .. world.dronePos.z .. ":" .. side
  world.apiaries[key] = world.apiaries[key] or {}
  return world.apiaries[key]
end

-- Fake nav: instantly "arrives" and tracks position for apiary() to key
-- off of. Real Nav geometry (proximity ordering, stuck detection) is
-- tested against the real module in bee_keeper_nav_test.lua.
-- gotoLog records every requested (x,z) in order -- used by the runCycle
-- ordering test below to verify sites are fully handled one at a time
-- (harvest+decide together) rather than visited in two separate sweeps.
world.gotoLog = {}
package.loaded["bee_keeper_nav"] = {
  setHome = function() end,
  setAltitude = function() return true end,
  getPos = function() return { x = world.dronePos.x, z = world.dronePos.z } end,
  gotoXZ = function(x, z)
    world.dronePos = { x = x, z = z }
    table.insert(world.gotoLog, x .. ":" .. z)
    return true
  end,
  gotoHome = function() world.dronePos = { x = 0, z = 0 }; return true end,
  orderByProximity = function(sites) return sites end, -- keep list order for test determinism
  needCharge = function() return false end,
  isFullyCharged = function() return true end,
  chargeAtHome = function() end,
}

local function makeAlleles(traitList, goodTraits)
  local active, inactive = {}, {}
  for _, t in ipairs(traitList) do
    if t == "species" then
      active[t] = goodTraits.species or { name = "Common" }
      inactive[t] = goodTraits.species or { name = "Common" }
    else
      active[t] = goodTraits[t] ~= nil and goodTraits[t] or 0
      inactive[t] = goodTraits[t] ~= nil and goodTraits[t] or 0
    end
  end
  return active, inactive
end

-- Builds a mock "stack" (what getStackInSlot/getStackInInternalSlot would
-- return) wrapping an individual, matching beeManager.lua's established
-- .individual.active/.inactive convention.
local function mockBeeStack(active, inactive, isAnalyzed)
  if isAnalyzed == nil then isAnalyzed = true end
  return { name = "forestry:bee", individual = { active = active, inactive = inactive, isAnalyzed = isAnalyzed } }
end

-- Same, but with a real Forestry princess item name -- M.runQualitySite's
-- findPrincessCandidate matches on item name (case-insensitive
-- "princess"/"queen"), so a generic "forestry:bee" stack (mockBeeStack)
-- deliberately does NOT qualify as a seedable princess.
local function mockPrincessStack(active, inactive, isAnalyzed)
  if isAnalyzed == nil then isAnalyzed = true end
  return { name = "Forestry:beePrincessGE", individual = { active = active, inactive = inactive, isAnalyzed = isAnalyzed } }
end

-- Same, but with a real Forestry drone item name -- groupBySpecies (used
-- by mutation pairing) now requires an actual drone-type item for the
-- drone role, same as findPrincessCandidate requires an actual princess.
local function mockDroneStack(active, inactive, isAnalyzed)
  if isAnalyzed == nil then isAnalyzed = true end
  return { name = "Forestry:beeDroneGE", individual = { active = active, inactive = inactive, isAnalyzed = isAnalyzed } }
end

local mockComponent = {}
mockComponent.isAvailable = function(name) return name == "robot" end

mockComponent.robot = {
  select = function(slot) world.selectedSlot = slot end,
  -- Splits `count` items off the currently selected slot into `toSlot` --
  -- models the real robot.transferTo(slot, [count]) used by
  -- ensureSingleItemSlot to peel exactly one drone off a stacked slot
  -- before swapDrone, instead of handing over the whole stack.
  transferTo = function(toSlot, count)
    local from = world.selectedSlot
    local stack = world.agentInventory[from]
    if not stack then return false end
    local size = stack.size or 1
    local moveCount = count or size
    if moveCount >= size then
      world.agentInventory[toSlot] = stack
      world.agentInventory[from] = nil
    else
      local newStack = {}
      for k, v in pairs(stack) do newStack[k] = v end
      newStack.size = moveCount
      stack.size = size - moveCount
      world.agentInventory[toSlot] = newStack
    end
    return true
  end,
}

mockComponent.inventory_controller = {
  -- M.harvestSite queries this to guard against slot numbers beyond a real
  -- inventory's actual size (see its header notes) -- 15 is "big enough"
  -- for this test's fixtures, same reasoning as bee_keeper_sim.lua's fake.
  getInventorySize = function(_side) return 15 end,
  getStackInInternalSlot = function(slot)
    return world.agentInventory[slot]
  end,
  getStackInSlot = function(side, slot)
    return apiary(side)[slot]
  end,
  -- Lands in the CURRENTLY SELECTED slot, same as dropIntoSlot/swapQueen/
  -- swapDrone below -- NOT an auto-picked empty slot. This is what caught
  -- M.harvestSite forgetting to select() before calling this on real
  -- hardware: harvesting silently produced nothing. If the destination is
  -- already occupied, this models a real inventory's merge (increments
  -- size) rather than refusing -- production code only ever selects an
  -- occupied slot via findStackingSlot, which already verified it's a
  -- genuine match.
  suckFromSlot = function(side, slot, count)
    local stack = apiary(side)[slot]
    if not stack then return 0 end
    local existing = world.agentInventory[world.selectedSlot]
    if existing then
      existing.size = (existing.size or 1) + 1
    else
      world.agentInventory[world.selectedSlot] = stack
    end
    apiary(side)[slot] = nil
    return 1
  end,
  dropIntoSlot = function(side, slot)
    local stack = world.agentInventory[world.selectedSlot]
    if not stack then return false end
    local existing = apiary(side)[slot]
    if existing then
      existing.size = (existing.size or 1) + 1
    else
      apiary(side)[slot] = stack
    end
    world.agentInventory[world.selectedSlot] = nil
    return true
  end,
}

mockComponent.beekeeper = {
  canWork = function(side) return apiary(side)._working or false end,
  getBeeProgress = function(side) return apiary(side)._progress or 0 end,
  swapQueen = function(side)
    local a = apiary(side)
    local newQueen = world.agentInventory[world.selectedSlot]
    local oldQueen = a[1]
    a[1] = newQueen
    world.agentInventory[world.selectedSlot] = oldQueen
    return true
  end,
  swapDrone = function(side)
    local a = apiary(side)
    local newDrone = world.agentInventory[world.selectedSlot]
    local oldDrone = a[2]
    a[2] = newDrone
    world.agentInventory[world.selectedSlot] = oldDrone
    return true
  end,
  analyze = function(honeySlot)
    world.analyzeCalls = world.analyzeCalls + 1
    world.lastHoneySlotUsed = honeySlot
    local stack = world.agentInventory[world.selectedSlot]
    if stack and stack.individual then stack.individual.isAnalyzed = true end
    return true
  end,
}

mockComponent.bee_housing = {
  getBeeParents = function(species) return world._mutationRecipes and world._mutationRecipes[species] or {} end,
}

package.loaded["component"] = mockComponent

-- The "robot" LIBRARY, not component.robot -- inventorySize() (own
-- inventory total slot count) lives here, confirmed on real hardware to
-- require this split the same way movement did (see bee_keeper_nav.lua).
package.loaded["robot"] = {
  inventorySize = function() return world.robotInventorySize or 15 end,
}

-- ============================================================
-- Load the real module under test against these fakes
-- ============================================================

local M = require("bee_keeper_manager")
local Cfg = require("bee_trait_config")

local failures = 0
local function check(name, cond, detail)
  if cond then
    print("OK   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- ============================================================
-- Test: traitListFor
-- ============================================================

do
  local qualityOnly = M.traitListFor("traitmax")
  local hasSpecies = false
  for _, t in ipairs(qualityOnly) do if t == "species" then hasSpecies = true end end
  check("traitListFor(traitmax) excludes species", not hasSpecies)

  local withSpecies = M.traitListFor("species")
  hasSpecies = false
  for _, t in ipairs(withSpecies) do if t == "species" then hasSpecies = true end end
  check("traitListFor(species) includes species", hasSpecies)
end

-- ============================================================
-- Test: readIndividual handles both shapes + rejects unanalyzed/nil
-- ============================================================

do
  local wrapped = mockBeeStack({ fertility = 4 }, { fertility = 4 }, true)
  check("readIndividual unwraps .individual", M.readIndividual(wrapped) ~= nil)

  local flat = { active = { fertility = 4 }, inactive = { fertility = 4 }, isAnalyzed = true }
  check("readIndividual accepts flat (bee_housing) shape", M.readIndividual(flat) ~= nil)

  local unanalyzed = mockBeeStack({ fertility = 4 }, { fertility = 4 }, false)
  check("readIndividual rejects unanalyzed", M.readIndividual(unanalyzed) == nil)

  check("readIndividual rejects nil", M.readIndividual(nil) == nil)
end

-- ============================================================
-- Test: runQualitySite picks the correct best drone and actually swaps it
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  -- Princess: good at everything except fertility.
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1 -- below the atLeast-4 target -> "bad"

  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  -- Working slot 5: a weak drone (nothing good).
  local weakActive, weakInactive = makeAlleles(traitList, {})
  world.agentInventory[5] = mockBeeStack(weakActive, weakInactive, true)

  -- Working slot 6: carries good fertility -- should be picked.
  local strongTraits = {}
  strongTraits.fertility = Cfg.targets.fertility.target
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[6] = mockBeeStack(strongActive, strongInactive, true)

  local config = { workingSlots = { 5, 6 }, minCopies = 2 }
  local site = { name = "test-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite reports a load", status:match("^loaded drone") ~= nil, status)
  check("runQualitySite selected slot 6 (fertility carrier)", world.selectedSlot == 6, "selected=" .. tostring(world.selectedSlot))
  check("runQualitySite actually swapped the drone into the apiary", apiary(DOWN)[2] ~= nil and apiary(DOWN)[2].individual.active.fertility == Cfg.targets.fertility.target)
  check("runQualitySite pulled the weak drone's slot back out (still slot 5 in inventory, untouched)", world.agentInventory[5] ~= nil)
end

-- ============================================================
-- Test: loading a drone that's part of a stacked cargo slot (size > 1,
-- possible since harvestSite/findStackingSlot now merge matching
-- drones together) only ever hands ONE drone to the apiary -- not the
-- whole stack. swapDrone swaps the entire selected slot verbatim, so the
-- stack must be split first.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1
  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  local strongTraits = { fertility = Cfg.targets.fertility.target }
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  -- Slot 6 holds THREE genetically identical drones stacked together.
  -- Slot 5 is empty -- the only place a single drone can be split into.
  local stackedDrone = mockBeeStack(strongActive, strongInactive, true)
  stackedDrone.size = 3
  world.agentInventory[6] = stackedDrone

  local config = { workingSlots = { 5, 6 }, minCopies = 2 }
  local site = { name = "stack-split-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite reports a load", status:match("^loaded drone") ~= nil, status)
  check("only ONE drone was handed to the apiary, not the whole stack of 3",
    apiary(DOWN)[2] ~= nil and (apiary(DOWN)[2].size or 1) == 1,
    "apiary drone size=" .. tostring(apiary(DOWN)[2] and apiary(DOWN)[2].size))
  check("the remaining 2 drones are still in cargo (slot 6, size reduced)",
    world.agentInventory[6] ~= nil and world.agentInventory[6].size == 2,
    "slot6 size=" .. tostring(world.agentInventory[6] and world.agentInventory[6].size))
  check("the split-off single drone's slot (5) is empty again after being swapped in",
    world.agentInventory[5] == nil)
end

-- ============================================================
-- Test: a princess sitting in cargo must never be treated as a
-- discardable drone candidate -- the real-hardware bug where a harvested
-- princess got flown to storage instead of staying available to re-seed
-- her own apiary (gatherCandidateDrones didn't distinguish item types).
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1

  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  local strongTraits = {}
  strongTraits.fertility = Cfg.targets.fertility.target
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[6] = mockBeeStack(strongActive, strongInactive, true) -- the drone that'll be picked

  -- A harvested princess sitting in cargo, deliberately with NOTHING
  -- valuable in her genotype -- if she were ever scored as an ordinary
  -- drone candidate, she'd have no reason to be banked (no good allele to
  -- protect via minCopies) and would be a clear-cut discard. Distinguishable
  -- from a real drone only by item name. lifespan is explicitly overridden
  -- (not left at makeAlleles' default 0) since lifespan is an "atMost 10"
  -- trait -- 0 would otherwise coincidentally satisfy it and make her
  -- bankable, masking exactly the bug this test exists to catch.
  local weakActive, weakInactive = makeAlleles(traitList, { lifespan = 999 })
  world.agentInventory[7] = mockPrincessStack(weakActive, weakInactive, true)

  local config = { workingSlots = { 6, 7 }, minCopies = 2, storagePos = { x = 0, z = 0 }, storageSlotCount = 10 }
  local site = { name = "test-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite still loads the real drone", status:match("^loaded drone") ~= nil, status)
  check("princess was never treated as a discard candidate (still in her own cargo slot)",
    world.agentInventory[7] ~= nil and world.agentInventory[7].name == "Forestry:beePrincessGE")

  world.dronePos = { x = 0, z = 0 } -- peek at storage regardless of where the code left the drone
  check("princess never got flown to storage", apiary(DOWN)[1] == nil and apiary(DOWN)[2] == nil)
end

-- ============================================================
-- Test: runQualitySite seeds a princess from cargo when the apiary's
-- queen slot is empty -- this is the real-hardware bug where a spent
-- queen is fully consumed by Forestry (not replaced in slot 1), leaving
-- traitmax/species sites permanently idle since only the mutation flow
-- used to ever call swapQueen.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }
  -- Apiary queen slot (1) deliberately left empty -- nothing assigned.
  -- Cargo has ONLY the princess -- no drone candidate at all -- so this
  -- specifically tests the "seeded but nothing left to load yet" partial
  -- state, distinct from the fuller test below.

  local traitList = M.traitListFor("traitmax")
  local pActive, pInactive = makeAlleles(traitList, {})
  world.agentInventory[5] = mockPrincessStack(pActive, pInactive, true)

  local config = { workingSlots = { 5 }, minCopies = 2 }
  local site = { name = "empty-queen-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite seeds a princess instead of reporting no_princess_at_site",
    status:match("^seeded princess") ~= nil, status)
  check("runQualitySite selected the actual princess item to seed her",
    world.selectedSlot == 5, "selected=" .. tostring(world.selectedSlot))
  check("runQualitySite's swapQueen actually placed her in the apiary's queen slot",
    apiary(DOWN)[1] ~= nil and apiary(DOWN)[1].name == "Forestry:beePrincessGE")
  check("with no drone candidates in cargo, it stops there for now",
    status:find("no drone", 1, true) ~= nil, status)
end

-- ============================================================
-- Test: when a drone candidate IS available in cargo, runQualitySite
-- seeds the princess AND loads a drone in the SAME visit, instead of
-- leaving the apiary half set up until whenever it's revisited again.
-- This is the actual real-hardware bug: the robot was visibly
-- "abandoning" an apiary mid-setup to wander off elsewhere.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  local pActive, pInactive = makeAlleles(traitList, {})
  world.agentInventory[4] = mockBeeStack(pActive, pInactive, true) -- drone candidate
  world.agentInventory[5] = mockPrincessStack(pActive, pInactive, true)

  local config = { workingSlots = { 4, 5 }, minCopies = 2 }
  local site = { name = "empty-queen-site-2", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite seeds the princess AND loads a drone in one visit",
    status:match("^seeded princess %+ loaded drone") ~= nil, status)
  check("the apiary's princess slot actually has her", apiary(DOWN)[1] ~= nil)
  check("the apiary's drone slot actually has a drone too", apiary(DOWN)[2] ~= nil)
end

-- ============================================================
-- Test: when cargo holds MULTIPLE princesses, findPrincessCandidate must
-- pick the best-scoring one to seed, not merely whichever sits in the
-- lowest-numbered cargo slot. Without this, an apiary visited first
-- (nearest-neighbor travel order) could get stuck with a genuinely weak
-- princess purely by scan-order luck, while a much better one sat
-- unseeded in a higher slot -- exactly what real-hardware observation
-- flagged: a good princess and a good drone ended up together at one
-- apiary while a weak princess sat at another, with no actual quality
-- reasoning behind which apiary got which.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")

  -- Weak princess deliberately sits in the LOWEST slot number -- old
  -- scan-order behavior would grab her first regardless of quality.
  local weakActive, weakInactive = makeAlleles(traitList, {})
  world.agentInventory[3] = mockPrincessStack(weakActive, weakInactive, true)

  -- Strong (fully purebred-good) princess sits in a HIGHER slot number.
  local goodTraits = {}
  for _, t in ipairs(traitList) do goodTraits[t] = Cfg.targets[t].target end
  local strongActive, strongInactive = makeAlleles(traitList, goodTraits)
  world.agentInventory[9] = mockPrincessStack(strongActive, strongInactive, true)

  local config = { workingSlots = { 3, 9 }, minCopies = 2 }
  local site = { name = "multi-princess-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite seeded a princess", status:match("^seeded princess") ~= nil, status)
  check("the STRONG princess (slot 9) was selected, not the weak one in the lower slot",
    world.selectedSlot == 9, "selected=" .. tostring(world.selectedSlot))
  check("the weak princess was left behind in cargo, untouched",
    world.agentInventory[3] ~= nil and world.agentInventory[3].name == "Forestry:beePrincessGE")
  check("progress recorded for the site reflects the strong princess (fully purebred)",
    site.progress == 1.0, "progress=" .. tostring(site.progress))
end

-- ============================================================
-- Test: when a queen's FINAL work tick completes breeding (getBeeProgress
-- consumes her, same as real Forestry/the local simulator), runQualitySite
-- must fall through into seed+evaluate+load in this SAME visit instead of
-- returning "working (100%)" and leaving the apiary idle for a whole
-- extra cycle before ever re-seeding -- exactly what real-hardware/sim
-- observation flagged: the robot harvested, then left without
-- re-breeding, even with a candidate princess+drone sitting right there
-- in cargo.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  local pActive, pInactive = makeAlleles(traitList, {})
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true) -- old queen, about to be consumed
  apiary(DOWN)._working = true
  apiary(DOWN)._progress = 100

  world.agentInventory[4] = mockBeeStack(pActive, pInactive, true) -- drone candidate
  world.agentInventory[5] = mockPrincessStack(pActive, pInactive, true) -- next princess, ready and waiting

  -- getBeeProgress's real effect (see bee_keeper_sim.lua's version):
  -- consuming the queen on her final tick -- the mock component's
  -- default getBeeProgress is just a static read with no side effects,
  -- so this test overrides it to actually model that consumption.
  local origGetBeeProgress = mockComponent.beekeeper.getBeeProgress
  mockComponent.beekeeper.getBeeProgress = function(side)
    apiary(side)[1] = nil
    return 100
  end

  local config = { workingSlots = { 4, 5 }, minCopies = 2 }
  local site = { name = "just-finished-breeding-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  mockComponent.beekeeper.getBeeProgress = origGetBeeProgress

  check("runQualitySite re-seeds in the SAME visit breeding completes, not just 'working (100%)'",
    status:match("^seeded princess") ~= nil, status)
  check("the apiary's princess slot has a fresh queen, not left empty", apiary(DOWN)[1] ~= nil)
  check("the apiary's drone slot got loaded too", apiary(DOWN)[2] ~= nil)
end

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }
  -- No princess anywhere -- apiary empty AND cargo has none.
  world.agentInventory[4] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)

  local config = { workingSlots = { 4 }, minCopies = 2 }
  local site = { name = "truly-empty-site", x = 5, z = 9, mode = "traitmax" }

  local status = M.runQualitySite(config, site)
  check("runQualitySite reports distinctly when no princess exists anywhere",
    status == "no_princess_at_site_or_in_cargo", status)
end

-- ============================================================
-- Test: mutation mode matches held species against recipes and swaps in
-- the correct pair
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 20, z = 3 }
  world._mutationRecipes = {
    ["NewSpecies"] = {
      { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
      { allele1 = { name = "Common" }, allele2 = { name = "Cultivated" }, chance = 8 },
    },
  }

  local traitList = M.traitListFor("mutation")
  local forestActive, forestInactive = makeAlleles(traitList, { species = { name = "Forest" } })
  local meadowsActive, meadowsInactive = makeAlleles(traitList, { species = { name = "Meadows" } })

  -- Only Forest x Meadows is satisfiable (no Common/Cultivated held) --
  -- should be the one picked even though it's not literally the only
  -- recipe. One princess, one drone -- a real mutation needs exactly one
  -- of each (Forestry doesn't care which named species is which side).
  world.agentInventory[3] = mockPrincessStack(forestActive, forestInactive, true)
  world.agentInventory[4] = mockDroneStack(meadowsActive, meadowsInactive, true)

  local config = { workingSlots = { 3, 4 } }
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports an attempt", status:match("^attempting mutation") ~= nil, status)
  check("runMutationSite loaded a queen", apiary(DOWN)[1] ~= nil)
  check("runMutationSite loaded a drone", apiary(DOWN)[2] ~= nil)

  local queenSpecies = Cfg.speciesKey(apiary(DOWN)[1].individual.active.species)
  local droneSpecies = Cfg.speciesKey(apiary(DOWN)[2].individual.active.species)
  check("runMutationSite used the satisfiable Forest/Meadows pair",
    (queenSpecies == "Forest" and droneSpecies == "Meadows") or (queenSpecies == "Meadows" and droneSpecies == "Forest"),
    "queen=" .. tostring(queenSpecies) .. " drone=" .. tostring(droneSpecies))
end

-- ============================================================
-- Test: mutation mode must NOT attempt a pairing when cargo has the
-- right SPECIES but the wrong ITEM TYPES -- two drones, no princess at
-- all. groupBySpecies used to lump princess/drone items together by
-- species alone, so "the best-scoring Forest bee" could actually be a
-- drone, picked for the princess role and handed to swapQueen (which
-- real Forestry -- and this codebase's own type-checked simulator --
-- rejects). Must report waiting, not attempt with mismatched types.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 20, z = 3 }
  world._mutationRecipes = {
    ["NewSpecies"] = {
      { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
    },
  }

  local traitList = M.traitListFor("mutation")
  local forestActive, forestInactive = makeAlleles(traitList, { species = { name = "Forest" } })
  local meadowsActive, meadowsInactive = makeAlleles(traitList, { species = { name = "Meadows" } })

  -- BOTH drones -- no princess of either species anywhere in cargo.
  world.agentInventory[3] = mockDroneStack(forestActive, forestInactive, true)
  world.agentInventory[4] = mockDroneStack(meadowsActive, meadowsInactive, true)

  local config = { workingSlots = { 3, 4 } }
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports waiting -- species match but no real princess exists",
    status:match("^waiting_on_parent_species") ~= nil, status)
  check("runMutationSite never touched the apiary's queen slot",
    apiary(DOWN)[1] == nil)
end

-- ============================================================
-- Test: mutation mode reports missing parents when nothing's satisfiable
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 20, z = 3 }
  world._mutationRecipes = {
    ["NewSpecies"] = {
      { allele1 = { name = "Forest" }, allele2 = { name = "Meadows" }, chance = 12 },
    },
  }
  local config = { workingSlots = { 3, 4 } }
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }

  local status = M.runMutationSite(config, site)
  check("runMutationSite reports waiting when parents aren't held", status:match("^waiting_on_parent_species") ~= nil, status)
end

-- ============================================================
-- Test: mutation mode detects success and hands off
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 20, z = 3 }
  local traitList = M.traitListFor("mutation")
  local activeT, inactiveT = makeAlleles(traitList, { species = { name = "NewSpecies" } })
  world.agentInventory[9] = mockBeeStack(activeT, inactiveT, true)

  local config = { workingSlots = { 9 } }
  local site = { name = "mutation-site", x = 20, z = 3, mode = "mutation", targetSpecies = "NewSpecies" }
  local status = M.runMutationSite(config, site)
  check("runMutationSite detects a targetSpecies bee already in hand", status == "mutation_succeeded:switch_site_to_species_mode", status)
end

-- ============================================================
-- Test: analyzeWorkingSlots only analyzes unanalyzed bees
-- ============================================================

do
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false) -- unanalyzed
  world.agentInventory[2] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)  -- already analyzed

  local config = { workingSlots = { 1, 2 }, honeySlot = 20 }
  local analyzed = M.analyzeWorkingSlots(config)
  check("analyzeWorkingSlots analyzes exactly the unanalyzed one", analyzed == 1, "analyzed=" .. tostring(analyzed))
  check("analyzeWorkingSlots left the already-analyzed one alone (1 total call)", world.analyzeCalls == 1)
end

-- ============================================================
-- Test: analyzeWorkingSlots finds honey dynamically wherever it actually
-- is (e.g. honeydew harvested organically into a random working slot),
-- then CONSOLIDATES it into config.honeySlot before analyzing -- real
-- hardware confirmed beekeeper.analyze() only ever actually consumes
-- honey physically sitting in config.honeySlot, regardless of what slot
-- number gets passed as its argument (it silently ignores honey sitting
-- anywhere else). Leaving it wherever it was found (the old behavior)
-- would pass an unusable slot number to analyze() and silently fail.
-- ============================================================

do
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.lastHoneySlotUsed = nil
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false) -- unanalyzed
  -- Honey is sitting in slot 15, NOT config.honeySlot (which points at an
  -- empty slot -- simulating it having been restocked/harvested
  -- somewhere else).
  world.agentInventory[15] = { name = "forestry:honey_drop", size = 64 }

  local config = { workingSlots = { 1 }, honeySlot = 20 }
  M.analyzeWorkingSlots(config)
  check("analyzeWorkingSlots consolidates honey into config.honeySlot before using it",
    world.lastHoneySlotUsed == 20, "used=" .. tostring(world.lastHoneySlotUsed))
  check("the honey physically moved to honeySlot (20)",
    world.agentInventory[20] ~= nil and world.agentInventory[20].name == "forestry:honey_drop")
  check("slot 15 is empty now that its honey was moved", world.agentInventory[15] == nil)
end

do
  -- No honey anywhere -- falls back to config.honeySlot rather than
  -- crashing or silently doing nothing useful to diagnose.
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.lastHoneySlotUsed = nil
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)

  local config = { workingSlots = { 1 }, honeySlot = 20 }
  M.analyzeWorkingSlots(config)
  check("analyzeWorkingSlots falls back to config.honeySlot when nothing matches",
    world.lastHoneySlotUsed == 20, "used=" .. tostring(world.lastHoneySlotUsed))
end

-- ============================================================
-- Test: analyzeWorkingSlots fetches more honey from storage when cargo
-- has run dry, instead of immediately falling back to config.honeySlot
-- -- an empty configured slot shouldn't mean "give up forever" if a
-- full stack is sitting right there in a chest.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.lastHoneySlotUsed = nil

  world.dronePos = { x = 0, z = 0 } -- seed honey at the storage position
  apiary(DOWN)[1] = { name = "forestry:honey_drop", size = 64 }
  world.dronePos = { x = 5, z = 5 }

  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false) -- unanalyzed
  -- honeySlot (20) is configured but genuinely empty -- nothing there.

  local config = { workingSlots = { 1, 2 }, honeySlot = 20, storagePos = { x = 0, z = 0 } }
  local analyzed = M.analyzeWorkingSlots(config)
  check("analyzeWorkingSlots restocked honey from storage and analyzed successfully",
    analyzed == 1, "analyzed=" .. tostring(analyzed))
  -- Prefers refilling the ORIGINAL honeySlot (it's empty, and it's the
  -- most natural destination) over claiming a working slot that could
  -- otherwise hold a real breeding candidate.
  check("the fetched honey landed back in honeySlot (20), not a working slot",
    world.agentInventory[20] ~= nil and world.agentInventory[20].name == "forestry:honey_drop")
  check("working slot 2 was left free, not consumed by the restock",
    world.agentInventory[2] == nil)
  check("analyzeWorkingSlots used the RESTOCKED honeySlot",
    world.lastHoneySlotUsed == 20, "used=" .. tostring(world.lastHoneySlotUsed))
end

-- ============================================================
-- Test: restockHoney must succeed even when EVERY working slot is
-- occupied (a long real run's cargo filling up with banked drones/
-- princesses) as long as config.honeySlot itself is empty -- the real-
-- hardware bug this fixes: a search limited to workingSlots (which
-- deliberately excludes honeySlot -- see M.resolveWorkingSlots) would
-- never even consider the empty honeySlot as a valid destination, so
-- restocking failed outright and analysis permanently stopped working,
-- even though the most natural destination was sitting right there,
-- empty, ready to be refilled.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.lastHoneySlotUsed = nil

  world.dronePos = { x = 0, z = 0 }
  apiary(DOWN)[1] = { name = "forestry:honey_drop", size = 64 }
  world.dronePos = { x = 5, z = 5 }

  -- EVERY working slot occupied -- no room anywhere except honeySlot.
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)
  world.agentInventory[2] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)
  -- honeySlot (20) is empty -- its honey ran out.

  local config = { workingSlots = { 1, 2 }, honeySlot = 20, storagePos = { x = 0, z = 0 } }
  local restocked = M.restockHoney(config)
  check("restockHoney succeeds using the empty honeySlot even with zero free working slots",
    restocked == true)
  check("honey landed in honeySlot", world.agentInventory[20] ~= nil)
end

do
  -- No storagePos known either -- restock isn't even attempted, falls
  -- straight through to config.honeySlot as before.
  world.apiaries = {}
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.lastHoneySlotUsed = nil
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)

  local config = { workingSlots = { 1 }, honeySlot = 20 }
  local restocked = M.restockHoney(config)
  check("restockHoney does nothing when no storage location is known", restocked == false)
end

-- ============================================================
-- Test: storage has real items but NOTHING matches "honey"/"honeydew"
-- by name -- exercises the diagnostic full-dump path (see
-- M.restockHoney's diagRestockDumped block), which exists precisely to
-- surface a real-hardware item-naming mismatch in the log instead of
-- restockHoney just silently returning false forever with no forensic
-- information. Just needs to run without erroring and report failure
-- honestly.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 0, z = 0 }
  apiary(DOWN)[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true) -- NOT honey
  world.dronePos = { x = 5, z = 5 }
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)

  local config = { workingSlots = { 1 }, honeySlot = 20, storagePos = { x = 0, z = 0 } }
  local restocked = M.restockHoney(config)
  check("restockHoney reports failure honestly when nothing in storage matches honey/honeydew",
    restocked == false)
end

-- ============================================================
-- Test: matches on stack.label ("Honey Drop") too, not just stack.name
-- -- a real-hardware pack could register the item under an internal id
-- that doesn't literally contain "honey"/"honeydew" even though its
-- display label obviously does (or vice versa). Checking only one risks
-- a silent miss.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 0, z = 0 }
  -- Deliberately obscure registered name, but a real display label.
  apiary(DOWN)[1] = { name = "gtnh:item.12345", label = "Honey Drop", size = 64 }
  world.dronePos = { x = 5, z = 5 }
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)

  local config = { workingSlots = { 1, 2 }, honeySlot = 20, storagePos = { x = 0, z = 0 } }
  local restocked = M.restockHoney(config)
  check("restockHoney matches an item by LABEL when the name is obscure",
    restocked == true)
end

-- ============================================================
-- Test: restockHoney MERGES into an existing partial honey stack (e.g.
-- honeySlot still has a few left) instead of claiming a brand new empty
-- slot -- reported as real-hardware behavior: it fetched more honey
-- while 4 were still sitting in honeySlot, splitting the stock across
-- two separate cargo slots instead of topping the existing one up.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 0, z = 0 }
  apiary(DOWN)[1] = { name = "forestry:honey_drop", size = 64 }
  world.dronePos = { x = 5, z = 5 }

  -- honeySlot (20) still has a FEW honey left, not empty -- both working
  -- slots (1, 2) are completely free.
  world.agentInventory[20] = { name = "forestry:honey_drop", size = 4 }

  local config = { workingSlots = { 1, 2 }, honeySlot = 20, storagePos = { x = 0, z = 0 } }
  local restocked = M.restockHoney(config)
  check("restockHoney succeeded", restocked == true)
  check("restockHoney merged into the existing partial stack in honeySlot, growing it",
    world.agentInventory[20] ~= nil and (world.agentInventory[20].size or 0) > 4,
    "honeySlot size=" .. tostring(world.agentInventory[20] and world.agentInventory[20].size))
  check("no new slot was claimed -- both free working slots are still empty",
    world.agentInventory[1] == nil and world.agentInventory[2] == nil)
end

-- ============================================================
-- Test: resolveWorkingSlots auto-derives from the robot's real inventory
-- size (mocked at 15 -- see getInventorySize above) when
-- config.workingSlots isn't explicitly set, instead of a fixed hardcoded
-- list that wastes any extra Inventory Upgrade slots the robot has.
-- ============================================================

do
  local config = { honeySlot = 1 }
  local slots = M.resolveWorkingSlots(config)
  check("resolveWorkingSlots uses every slot up to the real inventory size (15)",
    #slots == 14, "count=" .. #slots) -- 15 total minus honeySlot
  local hasHoney = false
  for _, s in ipairs(slots) do if s == 1 then hasHoney = true end end
  check("resolveWorkingSlots excludes honeySlot", not hasHoney)
end

do
  local explicit = { 5, 6, 7 }
  local config = { honeySlot = 1, workingSlots = explicit }
  check("resolveWorkingSlots leaves an explicit list untouched",
    M.resolveWorkingSlots(config) == explicit)
end

-- ============================================================
-- Test: harvestSite pulls product slots into empty working slots
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }
  apiary(DOWN)[7] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)
  apiary(DOWN)[8] = mockBeeStack({ fertility = 3 }, { fertility = 3 }, true)

  local config = { workingSlots = { 1, 2, 3 }, productSlots = { 7, 8 } }
  local site = { name = "harvest-site", x = 5, z = 9, mode = "traitmax" }
  local harvested = M.harvestSite(config, site)
  check("harvestSite pulls both waiting products", harvested == 2, "harvested=" .. tostring(harvested))
  check("harvestSite clears the apiary's product slots", apiary(DOWN)[7] == nil and apiary(DOWN)[8] == nil)
end

-- ============================================================
-- Test: without an explicit config.productSlots, harvestSite auto-derives
-- "every slot from 3 to the apiary's real size" -- this is exactly what
-- real hardware needed (product actually sits in slots 3-6 on a real
-- apiary, not 7-15, which was the old hardcoded guess).
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }
  apiary(DOWN)[3] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)
  apiary(DOWN)[5] = mockBeeStack({ fertility = 3 }, { fertility = 3 }, true)

  local config = { workingSlots = { 1, 2, 3 } } -- no productSlots override
  local site = { name = "harvest-site-auto", x = 5, z = 9, mode = "traitmax" }
  local harvested = M.harvestSite(config, site)
  check("harvestSite auto-derives product slots starting at 3, not 7",
    harvested == 2, "harvested=" .. tostring(harvested))
  check("harvestSite (auto-derived) clears the apiary's product slots",
    apiary(DOWN)[3] == nil and apiary(DOWN)[5] == nil)
end

-- ============================================================
-- Test: harvestSite merges a harvested item into an existing matching
-- cargo stack instead of always taking a fresh empty slot -- otherwise
-- identical drones/combs pile up across separate slots one at a time.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local matchingActive, matchingInactive = { fertility = 2 }, { fertility = 2 }
  apiary(DOWN)[3] = mockBeeStack(matchingActive, matchingInactive, true)

  -- Slot 5 already holds a genetically IDENTICAL bee (not yet full) --
  -- should be the merge target. Slot 6 is empty and should be left alone.
  world.agentInventory[5] = mockBeeStack(matchingActive, matchingInactive, true)

  local config = { workingSlots = { 5, 6 } }
  local site = { name = "harvest-stack-site", x = 5, z = 9, mode = "traitmax" }
  local harvested = M.harvestSite(config, site)

  check("harvestSite reports the harvest", harvested == 1, "harvested=" .. tostring(harvested))
  check("harvestSite merged into the existing matching stack (slot 5), not a fresh slot",
    world.selectedSlot == 5, "selected=" .. tostring(world.selectedSlot))
  check("harvestSite left the empty slot 6 untouched", world.agentInventory[6] == nil)
end

-- ============================================================
-- Test: a product slot holding SEVERAL genetically identical drones
-- (they stack, same as cargo) must be pulled in ONE visit, not one unit
-- at a time -- a hardcoded suckFromSlot(..., 1) left the rest sitting
-- there indefinitely, since a fresh visit re-peeks and re-requests just
-- 1 again every time. This test's mock suckFromSlot doesn't cap by
-- count itself (see its header notes), so it can't distinguish old vs
-- new behavior by outcome alone -- it records exactly what count
-- harvestSite actually requested instead.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local active, inactive = { fertility = 2 }, { fertility = 2 }
  local stackedProduct = mockBeeStack(active, inactive, true)
  stackedProduct.size = 3
  apiary(DOWN)[7] = stackedProduct

  local config = { workingSlots = { 5, 6 }, productSlots = { 7 } }
  local site = { name = "harvest-stacked-product-site", x = 5, z = 9, mode = "traitmax" }

  local requestedCount = nil
  local origSuckFromSlot = mockComponent.inventory_controller.suckFromSlot
  mockComponent.inventory_controller.suckFromSlot = function(side, slot, count)
    requestedCount = count
    return origSuckFromSlot(side, slot, count)
  end

  M.harvestSite(config, site)
  mockComponent.inventory_controller.suckFromSlot = origSuckFromSlot

  check("harvestSite requests the WHOLE stack (3), not a hardcoded 1",
    requestedCount == 3, "requested=" .. tostring(requestedCount))
end

-- ============================================================
-- Test: dumpToStorage flies to storagePos and drops discarded drones
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }
  -- Deliberately DIFFERENT genotypes -- two identical ones would now
  -- (correctly) merge into one slot instead of spreading out; see the
  -- dedicated stacking test below for that behavior specifically.
  world.agentInventory[10] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)
  world.agentInventory[11] = mockBeeStack({ fertility = 2 }, { fertility = 2 }, true)

  local config = { storagePos = { x = 0, z = 0 }, storageSlotCount = 10 }
  local discardEntries = {
    { drone = { id = "a", _slot = 10 } },
    { drone = { id = "b", _slot = 11 } },
    { drone = { id = "keep-me", _slot = 12 } }, -- should be skipped (it's the kept one)
  }

  local dropped = M.dumpToStorage(config, discardEntries, "keep-me")
  check("dumpToStorage drops exactly the two non-kept drones", dropped == 2, "dropped=" .. tostring(dropped))
  check("dumpToStorage flew to storagePos", world.dronePos.x == 0 and world.dronePos.z == 0)
  check("dumpToStorage actually placed items in the storage inventory", apiary(DOWN)[1] ~= nil and apiary(DOWN)[2] ~= nil)
end

-- ============================================================
-- Test: dumpToTrash flies to trashPos and drops discarded drones there
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }
  world.agentInventory[10] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)

  local config = { trashPos = { x = -3, z = -3 }, trashSlotCount = 1 }
  local discardEntries = { { drone = { id = "a", _slot = 10 } } }

  local dropped = M.dumpToTrash(config, discardEntries, "keep-me")
  check("dumpToTrash drops the discarded drone", dropped == 1, "dropped=" .. tostring(dropped))
  check("dumpToTrash flew to trashPos", world.dronePos.x == -3 and world.dronePos.z == -3)
  check("dumpToTrash actually placed the item at the trash position", apiary(DOWN)[1] ~= nil)
end

-- ============================================================
-- Test: dumpToStorage merges a discarded drone into an existing matching
-- storage stack instead of always taking a fresh empty slot -- otherwise
-- repeated discards of genetically identical drones (common -- many weak
-- default-quality drones look alike) pile up across separate slots one
-- at a time instead of stacking.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}

  local matchingActive, matchingInactive = { fertility = 1 }, { fertility = 1 }
  -- Storage slot 1 already holds a genetically identical drone -- seeded
  -- while dronePos IS the storage position, since apiary() keys off the
  -- CURRENT drone position, not wherever it'll be by the time the code
  -- under test actually flies there.
  world.dronePos = { x = 0, z = 0 }
  apiary(DOWN)[1] = mockBeeStack(matchingActive, matchingInactive, true)

  world.dronePos = { x = 99, z = 99 }
  world.agentInventory[10] = mockBeeStack(matchingActive, matchingInactive, true)

  local config = { storagePos = { x = 0, z = 0 }, storageSlotCount = 10 }
  local discardEntries = { { drone = { id = "a", _slot = 10 } } }

  local dropped = M.dumpToStorage(config, discardEntries, "keep-me")
  check("dumpToStorage drops the discarded drone", dropped == 1, "dropped=" .. tostring(dropped))
  check("dumpToStorage merged into the existing matching stack, not slot 2",
    apiary(DOWN)[1].size == 2, "size=" .. tostring(apiary(DOWN)[1] and apiary(DOWN)[1].size))
  check("dumpToStorage left slot 2 untouched", apiary(DOWN)[2] == nil)
end

-- ============================================================
-- Test: runQualitySite prefers trash over storage for discards when both
-- are known -- a breeding program generates a steady stream of unwanted
-- drones that would otherwise slowly fill up a finite storage chest.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1
  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  local strongTraits = { fertility = Cfg.targets.fertility.target }
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[6] = mockBeeStack(strongActive, strongInactive, true) -- picked

  -- A genuinely worthless drone (lifespan overridden the same way as the
  -- princess test above, so it's not coincidentally bankable) -- should
  -- get discarded to whichever destination is preferred.
  local weakActive, weakInactive = makeAlleles(traitList, { lifespan = 999 })
  world.agentInventory[7] = mockBeeStack(weakActive, weakInactive, true)

  local config = {
    workingSlots = { 6, 7 }, minCopies = 2,
    storagePos = { x = 0, z = 0 }, storageSlotCount = 10,
    trashPos = { x = -10, z = -10 }, trashSlotCount = 1,
  }
  local site = { name = "test-site", x = 5, z = 9, mode = "traitmax" }

  M.runQualitySite(config, site)

  world.dronePos = { x = -10, z = -10 }
  check("discard landed at trashPos, not storagePos", apiary(DOWN)[1] ~= nil, "trash slot 1 empty")

  world.dronePos = { x = 0, z = 0 }
  check("storagePos was never touched when trashPos is also known", apiary(DOWN)[1] == nil)
end

-- ============================================================
-- Test: runQualitySite must NOT actually discard a redundant drone when
-- cargo has plenty of free space -- shouldBank's "redundant, no unique
-- value" verdict is about genetic value, not about whether there's room
-- to spare. Reported as real-hardware behavior: it was trashing bees
-- even with space available. Same setup as the trash-vs-storage test
-- above, but with several extra free working slots.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 5, z = 9 }

  local traitList = M.traitListFor("traitmax")
  local goodExceptFertility = {}
  for _, t in ipairs(traitList) do goodExceptFertility[t] = Cfg.targets[t].target end
  goodExceptFertility.fertility = 1
  local pActive, pInactive = makeAlleles(traitList, goodExceptFertility)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  local strongTraits = { fertility = Cfg.targets.fertility.target }
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[6] = mockBeeStack(strongActive, strongInactive, true) -- picked

  local weakActive, weakInactive = makeAlleles(traitList, { lifespan = 999 })
  world.agentInventory[7] = mockBeeStack(weakActive, weakInactive, true) -- would be discarded

  local config = {
    -- Plenty of extra free slots (8-11) beyond just the winner/weak pair.
    workingSlots = { 6, 7, 8, 9, 10, 11 }, minCopies = 2,
    storagePos = { x = 0, z = 0 }, storageSlotCount = 10,
    trashPos = { x = -10, z = -10 }, trashSlotCount = 1,
  }
  local site = { name = "test-site", x = 5, z = 9, mode = "traitmax" }

  M.runQualitySite(config, site)

  check("the redundant drone was left in cargo, not flown to trash",
    world.agentInventory[7] ~= nil and world.agentInventory[7].name == "forestry:bee")

  world.dronePos = { x = -10, z = -10 }
  check("trash was never visited when cargo had plenty of free space", apiary(DOWN)[1] == nil)
end

-- ============================================================
-- Test: restockFromStorage pulls analyzed bees back into free working
-- slots -- without this, storage is a one-way trip nothing ever gets
-- read back from, even though the bees are still physically sitting
-- right there.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }

  world.dronePos = { x = 0, z = 0 } -- seed storage contents at the storage position
  apiary(DOWN)[1] = mockBeeStack({ fertility = 4 }, { fertility = 4 }, true)
  apiary(DOWN)[2] = { name = "forestry:honey_drop", size = 64 } -- non-bee item, should be skipped
  world.dronePos = { x = 99, z = 99 }

  world.agentInventory[10] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true) -- occupies slot 10

  local config = {
    workingSlots = { 10, 11, 12 }, -- 11,12 free
    storagePos = { x = 0, z = 0 },
    storageSlotCount = 10,
  }

  local restocked = M.restockFromStorage(config)
  check("restockFromStorage pulls exactly the one analyzed bee", restocked == 1, "restocked=" .. tostring(restocked))
  check("restockFromStorage flew to storagePos", world.dronePos.x == 0 and world.dronePos.z == 0)

  local foundInCargo = world.agentInventory[11] ~= nil or world.agentInventory[12] ~= nil
  check("the restocked bee landed in a free working slot", foundInCargo)
  check("the non-bee item was left behind in storage",
    apiary(DOWN)[2] ~= nil and apiary(DOWN)[2].name == "forestry:honey_drop")
end

-- ============================================================
-- Test: restockFromStorage MERGES into an existing matching cargo stack
-- instead of always claiming a fresh empty slot -- reported as real
-- behavior: bees weren't auto-stacking in cargo when pulled back from
-- storage, always spreading across separate slots one at a time even
-- when an identical bee was already sitting there.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }

  local matchingActive, matchingInactive = { fertility = 3 }, { fertility = 3 }
  world.dronePos = { x = 0, z = 0 }
  apiary(DOWN)[1] = mockBeeStack(matchingActive, matchingInactive, true)
  world.dronePos = { x = 99, z = 99 }

  -- Cargo slot 11 already holds a genetically IDENTICAL bee -- should be
  -- the merge target. Slot 12 is empty and should be left untouched.
  world.agentInventory[11] = mockBeeStack(matchingActive, matchingInactive, true)

  local config = {
    workingSlots = { 11, 12 },
    storagePos = { x = 0, z = 0 },
    storageSlotCount = 10,
  }

  local restocked = M.restockFromStorage(config)
  check("restockFromStorage restocked the matching bee", restocked == 1, "restocked=" .. tostring(restocked))
  check("restockFromStorage merged into the existing matching stack (slot 11), growing it",
    world.agentInventory[11] ~= nil and (world.agentInventory[11].size or 1) > 1,
    "slot 11 size=" .. tostring(world.agentInventory[11] and world.agentInventory[11].size))
  check("restockFromStorage left the empty slot 12 untouched", world.agentInventory[12] == nil)
end

-- ============================================================
-- Test: restockFromStorage requests the WHOLE stacked quantity, not a
-- hardcoded 1 -- a storage slot holding several identical stacked bees
-- (they stack, same as cargo) should give them all up in one visit.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }

  local active, inactive = { fertility = 2 }, { fertility = 2 }
  local stackedBee = mockBeeStack(active, inactive, true)
  stackedBee.size = 5
  world.dronePos = { x = 0, z = 0 }
  apiary(DOWN)[1] = stackedBee
  world.dronePos = { x = 99, z = 99 }

  local config = { workingSlots = { 11, 12 }, storagePos = { x = 0, z = 0 }, storageSlotCount = 10 }

  local requestedCount = nil
  local origSuckFromSlot = mockComponent.inventory_controller.suckFromSlot
  mockComponent.inventory_controller.suckFromSlot = function(side, slot, count)
    requestedCount = count
    return origSuckFromSlot(side, slot, count)
  end

  M.restockFromStorage(config)
  mockComponent.inventory_controller.suckFromSlot = origSuckFromSlot

  check("restockFromStorage requests the WHOLE stack (5), not a hardcoded 1",
    requestedCount == 5, "requested=" .. tostring(requestedCount))
end

do
  -- No free working slots -- should not even attempt the trip.
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 99, z = 99 }
  world.agentInventory[10] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, true)

  local config = { workingSlots = { 10 }, storagePos = { x = 0, z = 0 } }
  local restocked = M.restockFromStorage(config)
  check("restockFromStorage does nothing when cargo has no free slots", restocked == 0)
  check("restockFromStorage never flew anywhere when there was nothing to restock",
    world.dronePos.x == 99 and world.dronePos.z == 99)
end

-- ============================================================
-- Test: runCycle triggers a restock trip when a site's decision comes up
-- with no usable candidates at all, so the NEXT cycle actually sees
-- whatever storage had to offer.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 0, z = 0 } -- seed storage first
  apiary(DOWN)[1] = mockBeeStack({ fertility = 4 }, { fertility = 4 }, true)

  world.dronePos = { x = 5, z = 5 }
  -- Site's apiary has a princess already, but cargo has ZERO drone
  -- candidates at all -- should trigger a restock.
  local traitList = M.traitListFor("traitmax")
  local pActive, pInactive = makeAlleles(traitList, {})
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)

  local config = {
    workingSlots = { 10, 11 }, -- both free
    minCopies = 2,
    storagePos = { x = 0, z = 0 },
    storageSlotCount = 10,
    sites = { { name = "site1", x = 5, z = 5, mode = "traitmax" } },
  }

  M.runCycle(config)
  local foundInCargo = world.agentInventory[10] ~= nil or world.agentInventory[11] ~= nil
  check("runCycle restocked from storage after a site found no candidates", foundInCargo)
end

-- ============================================================
-- Test: runCycle restocks honey PROACTIVELY, before any site is even
-- visited, when the tracked config.honeyCount is low -- rather than
-- only reacting after a site's own analysis attempt discovers cargo is
-- empty. Reported on real hardware: honey restocked successfully once,
-- then silently stopped restocking on later runs -- a tracked counter,
-- checked up front every cycle, doesn't depend on a real-hardware scan
-- correctly re-detecting "empty" the same way twice.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.gotoLog = {}
  world.dronePos = { x = 0, z = 0 } -- seed honey at the storage position
  apiary(DOWN)[1] = { name = "forestry:honey_drop", size = 64 }
  world.dronePos = { x = 5, z = 5 }

  local config = {
    workingSlots = { 10, 11 },
    honeySlot = 1,
    honeyCount = 0, -- tracked as already depleted
    storagePos = { x = 0, z = 0 },
    sites = { { name = "site1", x = 5, z = 5, mode = "traitmax" } },
  }

  M.runCycle(config)

  local firstStorageIdx, firstSiteIdx = nil, nil
  for i, pos in ipairs(world.gotoLog) do
    if pos == "0:0" and not firstStorageIdx then firstStorageIdx = i end
    if pos == "5:5" and not firstSiteIdx then firstSiteIdx = i end
  end
  check("runCycle visited storage for honey BEFORE visiting any site",
    firstStorageIdx ~= nil and firstSiteIdx ~= nil and firstStorageIdx < firstSiteIdx,
    "gotoLog=" .. table.concat(world.gotoLog, ","))
  check("config.honeyCount was true'd up to the real amount after restocking",
    config.honeyCount == 64, "honeyCount=" .. tostring(config.honeyCount))
end

do
  -- Decrements on each successful analyze -- the running estimate that
  -- drives the proactive check above.
  world.apiaries = {}
  world.agentInventory = {}
  world.analyzeCalls = 0
  world.agentInventory[1] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)
  world.agentInventory[2] = mockBeeStack({ fertility = 1 }, { fertility = 1 }, false)

  local config = { workingSlots = { 1, 2 }, honeySlot = 20, honeyCount = 5 }
  world.agentInventory[20] = { name = "forestry:honey_drop", size = 64 }

  M.analyzeWorkingSlots(config)
  check("config.honeyCount decremented once per successful analyze",
    config.honeyCount == 3, "honeyCount=" .. tostring(config.honeyCount))
end

-- ============================================================
-- Test: loadSites merges persisted (x,z) with mode/targetSpecies overrides
-- ============================================================

do
  local saved = {
    { name = "site1", x = 3, z = 4 },
    { name = "site2", x = 10, z = 12 },
  }
  local overrides = {
    site2 = { mode = "species", targetSpecies = "Sticky" },
  }

  local sites = M.loadSites(saved, overrides)
  check("loadSites keeps positions", sites[1].x == 3 and sites[1].z == 4 and sites[2].x == 10 and sites[2].z == 12)
  check("loadSites defaults unassigned sites to traitmax", sites[1].mode == "traitmax")
  check("loadSites applies overrides", sites[2].mode == "species" and sites[2].targetSpecies == "Sticky")
end

-- ============================================================
-- Test: purityOf -- fraction of loci fixed to GG (progress to purebred)
-- ============================================================

do
  local traits = { "fertility", "speed", "lifespan", "flowering" }
  local function genotype(states)
    -- states: array of "GG" | "Gb" | "bb", one per trait above
    local g = {}
    for i, trait in ipairs(traits) do
      local s = states[i]
      g[trait] = {
        active = (s == "GG" or s == "Gb") and "good" or "bad",
        inactive = (s == "GG") and "good" or "bad",
      }
    end
    return g
  end

  check("purityOf: all GG is 1.0", M.purityOf(traits, genotype({ "GG", "GG", "GG", "GG" })) == 1.0)
  check("purityOf: none GG is 0.0", M.purityOf(traits, genotype({ "bb", "bb", "bb", "bb" })) == 0.0)
  check("purityOf: half GG is 0.5", M.purityOf(traits, genotype({ "GG", "GG", "bb", "bb" })) == 0.5)
  check("purityOf: heterozygous does NOT count as fixed",
    M.purityOf(traits, genotype({ "Gb", "Gb", "Gb", "Gb" })) == 0.0)
  check("purityOf: empty trait list doesn't divide by zero", M.purityOf({}, {}) == 0)
end

-- ============================================================
-- Test: runQualitySite caches purity onto the site for the dashboard
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.dronePos = { x = 1, z = 1 }

  local traitList = M.traitListFor("traitmax")
  local allGood = {}
  for _, t in ipairs(traitList) do allGood[t] = Cfg.targets[t].target end
  local pActive, pInactive = makeAlleles(traitList, allGood)
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true)
  world.agentInventory[5] = mockBeeStack(pActive, pInactive, true)

  local site = { name = "purity-site", x = 1, z = 1, mode = "traitmax" }
  check("site has no progress before it's ever visited", site.progress == nil)

  M.runQualitySite({ workingSlots = { 5 }, minCopies = 2 }, site)
  check("runQualitySite records progress on the site", site.progress == 1.0,
    "progress=" .. tostring(site.progress))
end

-- ============================================================
-- Test: listCargo lists occupied working slots only, with raw stacks
-- (not just .individual -- the UI panel needs to show non-bee items too)
-- ============================================================

do
  world.agentInventory = {}
  world.agentInventory[2] = mockBeeStack({ fertility = 4 }, { fertility = 4 }, true)
  world.agentInventory[5] = { name = "forestry:honey_drop", size = 64 } -- non-bee item
  -- slot 3 deliberately left empty

  local config = { workingSlots = { 2, 3, 5, 9 } }
  local cargo = M.listCargo(config)
  check("listCargo returns exactly the occupied slots", #cargo == 2, "count=" .. #cargo)

  local bySlot = {}
  for _, entry in ipairs(cargo) do bySlot[entry.slot] = entry.stack end
  check("listCargo includes the bee stack", bySlot[2] ~= nil and bySlot[2].individual ~= nil)
  check("listCargo includes non-bee items too", bySlot[5] ~= nil and bySlot[5].name == "forestry:honey_drop")
  check("listCargo skips empty slots", bySlot[3] == nil and bySlot[9] == nil)
end

-- ============================================================
-- Test: runCycle fully resolves each site (harvest + decide) before
-- moving to the next, instead of two separate sweeps (harvest every
-- site, THEN decide at every site). The old two-sweep structure meant an
-- apiary that still needed a drone loaded got left behind while every
-- OTHER site was harvested first -- this is what "leaves the apiary to
-- go to another apiary despite the current one not having a
-- princess/drone" on real hardware actually was.
-- ============================================================

do
  world.apiaries = {}
  world.agentInventory = {}
  world.gotoLog = {}

  local traitList = M.traitListFor("traitmax")
  local pActive, pInactive = makeAlleles(traitList, {})

  world.dronePos = { x = 1, z = 1 }
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true) -- site1's princess already present

  world.dronePos = { x = 9, z = 9 }
  apiary(DOWN)[1] = mockBeeStack(pActive, pInactive, true) -- site2's princess already present

  world.dronePos = { x = 0, z = 0 }

  local strongTraits = { fertility = Cfg.targets.fertility.target }
  local strongActive, strongInactive = makeAlleles(traitList, strongTraits)
  world.agentInventory[10] = mockBeeStack(strongActive, strongInactive, true)
  world.agentInventory[11] = mockBeeStack(strongActive, strongInactive, true)

  local config = {
    workingSlots = { 10, 11 },
    minCopies = 2,
    sites = {
      { name = "site1", x = 1, z = 1, mode = "traitmax" },
      { name = "site2", x = 9, z = 9, mode = "traitmax" },
    },
  }

  M.runCycle(config)

  local firstSite2Idx, lastSite1Idx = nil, nil
  for i, pos in ipairs(world.gotoLog) do
    if pos == "9:9" and not firstSite2Idx then firstSite2Idx = i end
    if pos == "1:1" then lastSite1Idx = i end
  end
  check("site1 is fully handled (harvest+decide) before site2 is ever visited",
    firstSite2Idx ~= nil and lastSite1Idx ~= nil and lastSite1Idx < firstSite2Idx,
    "gotoLog=" .. table.concat(world.gotoLog, ","))
end

print("")
if failures == 0 then
  print("ALL TESTS PASSED")
else
  print(failures .. " TEST(S) FAILED")
  os.exit(1)
end
